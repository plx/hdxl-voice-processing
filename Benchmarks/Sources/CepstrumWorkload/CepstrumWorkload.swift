import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum CepstralOperation: String, Codable, Sendable, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}
public enum CepstralWorkloadKind: String, Codable, Sendable {
    case frame = "FrameChecksum"
    case conversion = "InputConversionChecksum"
    case interval = "IntervalChecksum"
    case preview = "PreviewChecksum"
    case stageExport = "FrameStageExport"
    case matrixExport = "BoundedMatrixExport"
}

public struct CepstralCase: Codable, Sendable {
    public let name: String
    public let kind: CepstralWorkloadKind
    public let configuration: CepstrogramConfiguration
    public let profileIdentities: [ProfileIdentity]
    public let inputSampleCount: Int
    public let inputChunkSamples: Int
    public let matrixMaximumFrames: Int
    public let matrixMaximumScalars: Int
    public var inputDurationSeconds: Double {
        Double(inputSampleCount) / Double(configuration.conditioning.sourceSampleRate)
    }
    public var expectsPreparedHeapAllocation: Bool { kind == .stageExport || kind == .matrixExport }

    private init(
        kind: CepstralWorkloadKind, precision: AnalysisPrecision, rate: Int,
        count: Int, hopMilliseconds: Int = 2, preview: Bool = false
    ) throws {
        self.kind = kind
        self.configuration = try CepstrogramConfiguration(
            sourceSampleRate: rate,
            inputPrecision: precision, hopSeconds: Double(hopMilliseconds) / 1000,
            declaredInputBandwidthHz: Double(rate) / 2,
            conditioningMethod: preview
                ? .streamingPreview(lobes: 16, cutoffFraction: 0.9)
                : .praat7WholeInterval(interpolationDepth: 50))
        self.profileIdentities =
            try kind == .conversion
            ? []
            : [
                kind == .frame || kind == .stageExport
                    ? configuration.frame.identity() : configuration.identity()
            ]
        self.inputSampleCount = count
        self.inputChunkSamples = 256
        self.matrixMaximumFrames = kind == .matrixExport ? 500 : 0
        self.matrixMaximumScalars = kind == .matrixExport ? 500 * configuration.frame.binCount : 0
        self.name =
            "\(kind.rawValue).\(precision.rawValue).\(rate)Hz.\(count)samples.\(preview ? "Preview" : "Reference").\(hopMilliseconds)ms"
    }
    public static func matrix() throws -> [Self] {
        var cases: [Self] = []
        for precision in [AnalysisPrecision.float32, .float64] {
            cases.append(try Self(kind: .frame, precision: precision, rate: 10_000, count: 1000))
            cases.append(
                try Self(kind: .stageExport, precision: precision, rate: 10_000, count: 1000))
            for (rate, count) in [(10_000, 1000), (48_000, 48_000)] {
                cases.append(
                    try Self(kind: .conversion, precision: precision, rate: rate, count: count))
            }
            for rate in [16_000, 48_000] {
                for duration in [1, 60] {
                    for hop in [2, 5, 10] {
                        cases.append(
                            try Self(
                                kind: hop == 2 ? .interval : .preview,
                                precision: precision, rate: rate, count: rate * duration,
                                hopMilliseconds: hop, preview: hop != 2))
                    }
                }
            }
            for hop in [2, 5, 10] {
                cases.append(
                    try Self(
                        kind: .matrixExport, precision: precision, rate: 48_000,
                        count: 48_000, hopMilliseconds: hop, preview: hop != 2))
            }
        }
        return cases
    }
    public func makeWorkload() throws -> any CepstralBatch {
        if configuration.inputPrecision == .float32 { return try CepstralWorkload<Float>(self) }
        return try CepstralWorkload<Double>(self)
    }
}

public struct CepstralEvidence: Codable, Sendable {
    public let name: String
    public let workload: CepstralCase
    public let inputDurationSeconds: Double
    public let inputSHA256: String
    public let preparedBufferBytes: Int
    public let preparedInputBytes: Int
    public let emittedFrameCount: UInt64
    public let completeFrameCount: UInt64
    public let unavailableFrameCount: UInt64
    public let retainedFrameCount: Int
    public let exportedScalarCount: Int
    public let checksum: Double
}

public protocol CepstralBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> CepstralEvidence
}

private final class CepstralPrepared<S: BinaryFloatingPoint & Sendable> {
    let kernel: PreparedPowerCepstrum?
    let interval: PreparedIntervalCepstrogram<S>?
    let preview: PreparedPreviewCepstrogram<S>?
    let conversion: UnsafeMutableBufferPointer<Double>
    var scalarWorkspaceBytes: Int {
        (kernel?.scalarWorkspaceBytes ?? 0) + (interval?.scalarWorkspaceBytes ?? 0)
            + (preview?.scalarWorkspaceBytes ?? 0) + conversion.count * MemoryLayout<Double>.stride
    }
    init(_ item: CepstralCase, epoch: StreamEpoch) throws {
        switch item.kind {
        case .frame, .stageExport:
            kernel = try PreparedPowerCepstrum(item.configuration.frame)
            interval = nil
            preview = nil
        case .conversion:
            kernel = nil
            interval = nil
            preview = nil
        case .interval, .preview, .matrixExport:
            kernel = nil
            if item.configuration.previewHopLength == nil {
                interval = try PreparedIntervalCepstrogram(
                    configuration: item.configuration,
                    source: SourceInterval(
                        epoch: epoch, startSample: 0, sampleCount: Int64(item.inputSampleCount),
                        sampleRate: Double(item.configuration.conditioning.sourceSampleRate)))
                preview = nil
            } else {
                preview = try PreparedPreviewCepstrogram(
                    configuration: item.configuration, epoch: epoch)
                interval = nil
            }
        }
        let converts = item.kind == .frame || item.kind == .conversion || item.kind == .stageExport
        conversion = .allocate(
            capacity: converts && S.self == Float.self ? item.inputSampleCount : 0)
        conversion.initialize(repeating: 0)
    }
    deinit {
        conversion.deinitialize()
        conversion.deallocate()
    }
    func withDoubleInput<T>(
        _ input: UnsafeBufferPointer<S>, body: (UnsafeBufferPointer<Double>) throws -> T
    ) rethrows -> T {
        if S.self == Double.self {
            return try input.withMemoryRebound(to: Double.self, body)
        }
        precondition(conversion.count == input.count)
        for i in input.indices { conversion[i] = Double(input[i]) }
        return try body(UnsafeBufferPointer(conversion))
    }
}

private final class CepstralWorkload<S: BinaryFloatingPoint & Sendable>: CepstralBatch {
    let item: CepstralCase
    let prepared: CepstralPrepared<S>
    let input: [S]
    let stream = UUID(uuidString: "00000000-0000-0000-0000-000000000133")!
    let stageSelection = Set(CepstralStage.allCases)
    let stagePolicy: IntermediateOutputPolicy
    let kernelContext: CepstralFrameContext
    var sequence: UInt64 = 0
    var emitted: UInt64 = 0, complete: UInt64 = 0, unavailable: UInt64 = 0
    var exportedScalars = 0, retainedFrames = 0
    var checksum = 0.0

    init(_ item: CepstralCase) throws {
        self.item = item
        let epoch = StreamEpoch(streamID: stream)
        prepared = try CepstralPrepared(item, epoch: epoch)
        stagePolicy = try IntermediateOutputPolicy(
            maximumScalarCount: item.configuration.frame.transformLength + 6
                * item.configuration.frame.binCount)
        let support = try SourceInterval(
            epoch: epoch, startSample: 0,
            sampleCount: Int64(item.configuration.frame.frameLength),
            sampleRate: Double(item.configuration.frame.sampleRate))
        kernelContext = try CepstralFrameContext(
            origin: SourceInterval(
                epoch: epoch, startSample: 0,
                sampleCount: 0, sampleRate: support.sampleRate),
            timing: AnalysisTiming(
                source: support,
                includedSampleCount: support.sampleCount), frameIndex: 0,
            firstAnalysisSampleIndex: 0,
            suppliedAnalysisSampleCount: item.configuration.frame.frameLength,
            centerSecondsFromOrigin: support.durationSeconds / 2)
        var state: UInt32 = 33
        input = (0..<item.inputSampleCount).map { i in
            state = 1_664_525 &* state &+ 1_013_904_223
            let noise = (Double(state) - 2_147_483_648) / 42_949_672_960
            let phase =
                2 * Double.pi * 125 * Double(i)
                / Double(item.configuration.conditioning.sourceSampleRate)
            return S(0.2 * sin(phase) + 0.1 * sin(2 * phase + 0.13) + noise)
        }
    }
    @inline(never) func prepare() throws -> AnyObject {
        try CepstralPrepared<S>(item, epoch: StreamEpoch(streamID: stream))
    }
    @inline(never) func run() throws -> Double { try execute(chunk: item.inputChunkSamples) }

    private func execute(chunk: Int) throws -> Double {
        emitted = 0
        complete = 0
        unavailable = 0
        exportedScalars = 0
        retainedFrames = 0
        checksum = 0
        switch item.kind {
        case .frame, .stageExport, .conversion:
            try input.withUnsafeBufferPointer { samples in
                try prepared.withDoubleInput(samples) { converted in
                    if item.kind == .conversion {
                        // Both precisions include the same full-output checksum. Double is
                        // a no-copy baseline; Float additionally widens every input sample.
                        for i in converted.indices { checksum += converted[i] * Double(i % 17 + 1) }
                    } else {
                        try prepared.kernel!.analyze(converted, context: kernelContext) { output in
                            consume(output)
                            if item.kind == .stageExport {
                                let exported = try! output.export(
                                    stages: stageSelection, policy: stagePolicy)
                                for stage in exported {
                                    for value in stage.snapshot?.values ?? [] {
                                        checksum += value * 1e-12
                                        exportedScalars += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .interval, .preview, .matrixExport:
            let previous = StreamEpoch(streamID: stream, sequence: sequence)
            sequence += 1
            let epoch = StreamEpoch(streamID: stream, sequence: sequence)
            let source = try SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: Int64(input.count),
                sampleRate: Double(item.configuration.conditioning.sourceSampleRate))
            let collector =
                item.kind == .matrixExport
                ? try BoundedCepstrogram(
                    configuration: item.configuration,
                    maximumFrames: item.matrixMaximumFrames,
                    maximumScalarCount: item.matrixMaximumScalars) : nil
            if let interval = prepared.interval { try interval.reset(source: source) }
            if let preview = prepared.preview {
                try preview.reset(
                    for: SourceDiscontinuity(
                        previousEpoch: previous, nextEpoch: epoch, reason: .explicitReset))
            }
            try input.withUnsafeBufferPointer { samples in
                for start in stride(from: 0, to: samples.count, by: chunk) {
                    let count = min(chunk, samples.count - start)
                    let segment = try SourceInterval(
                        epoch: epoch, startSample: Int64(start), sampleCount: Int64(count),
                        sampleRate: source.sampleRate)
                    let buffer = UnsafeBufferPointer(rebasing: samples[start..<start + count])
                    if let interval = prepared.interval {
                        try interval.append(buffer, interval: segment)
                    }
                    if let preview = prepared.preview {
                        try preview.process(buffer, interval: segment) {
                            consume($0, collector: collector)
                        }
                    }
                }
            }
            if let interval = prepared.interval {
                try interval.finish { consume($0, collector: collector) }
            }
            if let preview = prepared.preview {
                try preview.finish { consume($0, collector: collector) }
            }
            if let collector {
                retainedFrames = collector.frames.count
                exportedScalars = collector.scalarCount
                // Read retained storage too; the benchmark includes materialized owned data.
                for frame in collector.frames { checksum += (frame.values.first ?? 0) * 1e-12 }
            }
        }
        return checksum
    }
    private func consume(
        _ output: BorrowedPowerCepstrum<Double>, collector: BoundedCepstrogram? = nil
    ) {
        if let collector { try! collector.append(output) }
        emitted += 1
        if output.context.suppliedAnalysisSampleCount == item.configuration.frame.frameLength {
            complete += 1
        }
        if output.unavailability != nil {
            unavailable += 1
            return
        }
        let values = output.stage(.powerCepstrum).values
        for k in values.indices { checksum += values[k] / Double(k + 1) * 1e-10 }
    }
    func verify() throws -> CepstralEvidence {
        let result = try run()
        let counts = [
            emitted, complete, unavailable, UInt64(retainedFrames), UInt64(exportedScalars),
        ]
        let second = try execute(chunk: 63)
        precondition(
            result == second
                && counts == [
                    emitted, complete, unavailable, UInt64(retainedFrames), UInt64(exportedScalars),
                ])
        precondition(result.isFinite)
        switch item.kind {
        case .conversion: precondition(emitted == 0 && exportedScalars == 0)
        case .frame, .stageExport:
            precondition(emitted == 1 && complete == 1 && unavailable == 0)
            precondition(
                exportedScalars == (item.kind == .stageExport ? stagePolicy.maximumScalarCount : 0))
        case .interval, .preview, .matrixExport:
            let expected: UInt64
            let partial: UInt64
            if let interval = prepared.interval {
                expected = UInt64(interval.layout.frameCount)
                partial = 0
            } else {
                let target = Int(
                    Double(item.inputSampleCount) * Double(item.configuration.frame.sampleRate)
                        / Double(item.configuration.conditioning.sourceSampleRate))
                expected = UInt64(
                    (target - item.configuration.frame.frameLength) / item.configuration
                        .previewHopLength! + 1)
                partial = 1
            }
            precondition(
                complete == expected && emitted == expected + partial && unavailable == partial)
            precondition(retainedFrames == (item.kind == .matrixExport ? Int(emitted) : 0))
            precondition(
                exportedScalars
                    == (item.kind == .matrixExport
                        ? Int(expected) * item.configuration.frame.binCount : 0))
        }
        let inputHash = input.withUnsafeBytes {
            SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined()
        }
        return CepstralEvidence(
            name: item.name, workload: item, inputDurationSeconds: item.inputDurationSeconds,
            inputSHA256: inputHash, preparedBufferBytes: prepared.scalarWorkspaceBytes,
            preparedInputBytes: input.count * MemoryLayout<S>.stride, emittedFrameCount: emitted,
            completeFrameCount: complete, unavailableFrameCount: unavailable,
            retainedFrameCount: retainedFrames,
            exportedScalarCount: exportedScalars, checksum: checksum)
    }
}
