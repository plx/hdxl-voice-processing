import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum CPPOperation: String, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}
public enum CPPWorkloadKind: String, Codable, Sendable {
    case isolated = "FitSearch"
    case interval = "IntervalCPP"
    case preview = "PreviewCPP"
    case conversion = "InputConversionChecksum"
    case export = "OwnedDiagnostics"
}

public struct CPPCase: Codable, Sendable {
    public let name: String
    public let kind: CPPWorkloadKind
    public let configuration: CepstrogramConfiguration
    public let profile: CPPProfile
    public let profileIdentity: ProfileIdentity
    public let inputSampleCount: Int
    public let inputChunkSamples: Int
    public let densePeaks: Bool
    public var inputDurationSeconds: Double {
        kind == .isolated || kind == .export
            ? 0
            : Double(inputSampleCount) / Double(configuration.conditioning.sourceSampleRate)
    }
    public var isLongPipeline: Bool { inputDurationSeconds == 60 }
    public var shard: String {
        kind == .interval || kind == .preview
            ? "\(configuration.inputPrecision.rawValue)-\(configuration.conditioning.sourceSampleRate)"
            : "kernels"
    }

    private init(
        kind: CPPWorkloadKind, precision: AnalysisPrecision = .float64,
        rate: Int = 10_000, count: Int = 0, hop: Int = 2, dense: Bool = false,
        method: CPPFitMethod = .praat7002Robust,
        interpolation: CPPPeakInterpolation = .parabolic
    ) throws {
        self.kind = kind
        let isolated = kind == .isolated || kind == .export
        let preview = kind == .preview
        configuration = try CepstrogramConfiguration(
            sourceSampleRate: rate, analysisSampleRate: isolated ? rate : 10_000,
            inputPrecision: precision, hopSeconds: Double(hop) / 1000,
            declaredInputBandwidthHz: Double(rate) / 2,
            conditioningMethod: preview
                ? .streamingPreview(lobes: 16, cutoffFraction: 0.9)
                : .praat7WholeInterval(interpolationDepth: 50))
        let settings = try CPPConfiguration(
            pitchCeilingHz: 330, interpolation: interpolation,
            fitEndSeconds: 0, fitMethod: method)
        profile =
            isolated
            ? CPPProfile(frame: configuration.frame, settings: settings)
            : CPPProfile(cepstrogram: configuration, settings: settings)
        profileIdentity = try profile.identity()
        inputSampleCount = isolated ? configuration.frame.binCount : count
        inputChunkSamples = 256
        densePeaks = dense
        name =
            isolated
            ? "\(kind.rawValue).\(configuration.frame.binCount)bins.\(dense ? "Dense" : "Sparse").\(method.rawValue).\(interpolation.rawValue)"
            : "\(kind.rawValue).\(precision.rawValue).\(rate)Hz.\(count)samples.\(hop)ms"
    }
    public static func matrix() throws -> [Self] {
        var rows: [Self] = []
        for rate in [5000, 10_000, 20_000] {
            for dense in [false, true] {
                for method in CPPFitMethod.allCases {
                    for interpolation in CPPPeakInterpolation.allCases {
                        rows.append(
                            try Self(
                                kind: .isolated, rate: rate, dense: dense,
                                method: method, interpolation: interpolation))
                    }
                }
            }
        }
        for precision in [AnalysisPrecision.float32, .float64] {
            for (rate, count) in [(10_000, 1000), (48_000, 48_000)] {
                rows.append(
                    try Self(kind: .conversion, precision: precision, rate: rate, count: count))
            }
            for rate in [16_000, 48_000] {
                for duration in [1, 60] {
                    for hop in [2, 5, 10] {
                        rows.append(
                            try Self(
                                kind: hop == 2 ? .interval : .preview,
                                precision: precision, rate: rate, count: rate * duration, hop: hop))
                    }
                }
            }
        }
        rows.append(try Self(kind: .export))
        return rows
    }
    public func makeWorkload() throws -> any CPPBatch {
        if configuration.inputPrecision == .float32 { return try CPPWorkload<Float>(self) }
        return try CPPWorkload<Double>(self)
    }
}

public struct CPPEvidence: Codable, Sendable {
    public let name: String
    public let workload: CPPCase
    public let inputDurationSeconds: Double
    public let inputSHA256: String
    public let preparedInputBytes, preparedBufferBytes, cppBufferBytes: Int
    public let fitPointCount, slopeEvaluationCount: Int
    public let emittedFrameCount, availableFrameCount, unavailableFrameCount: UInt64
    public let exportedScalarCount: Int
    public let checksum: Double
}
public protocol CPPBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> CPPEvidence
}

private final class CPPPrepared<S: BinaryFloatingPoint & Sendable> {
    let cpp: PreparedCPP?
    let interval: PreparedIntervalCepstrogram<S>?
    let preview: PreparedPreviewCepstrogram<S>?
    let conversion: UnsafeMutableBufferPointer<Double>
    var scalarWorkspaceBytes: Int {
        (cpp?.scalarWorkspaceBytes ?? 0) + (interval?.scalarWorkspaceBytes ?? 0)
            + (preview?.scalarWorkspaceBytes ?? 0) + conversion.count * 8
    }
    init(_ item: CPPCase, epoch: StreamEpoch) throws {
        cpp = item.kind == .conversion ? nil : try PreparedCPP(item.profile)
        interval =
            item.kind == .interval
            ? try PreparedIntervalCepstrogram(
                configuration: item.configuration,
                source: SourceInterval(
                    epoch: epoch, startSample: 0,
                    sampleCount: Int64(item.inputSampleCount),
                    sampleRate: Double(item.configuration.conditioning.sourceSampleRate))) : nil
        preview =
            item.kind == .preview
            ? try PreparedPreviewCepstrogram(
                configuration: item.configuration, epoch: epoch) : nil
        conversion = .allocate(
            capacity: item.kind == .conversion && S.self == Float.self
                ? item.inputSampleCount : 0)
        conversion.initialize(repeating: 0)
    }
    deinit {
        conversion.deinitialize()
        conversion.deallocate()
    }
}

private final class CPPWorkload<S: BinaryFloatingPoint & Sendable>: CPPBatch {
    let item: CPPCase
    let prepared: CPPPrepared<S>
    let pcm: [S]
    let power: [Double]
    let stream = UUID(uuidString: "00000000-0000-0000-0000-000000000135")!
    let context: CepstralFrameContext
    let exportStages = Set(CPPIntermediate.allCases)
    let exportPolicy: IntermediateOutputPolicy
    var sequence: UInt64 = 0
    var emitted: UInt64 = 0, available: UInt64 = 0, unavailable: UInt64 = 0
    var exportedScalars = 0
    var checksum = 0.0

    init(_ item: CPPCase) throws {
        self.item = item
        let epoch = StreamEpoch(streamID: stream)
        prepared = try CPPPrepared(item, epoch: epoch)
        exportPolicy = try IntermediateOutputPolicy(
            maximumScalarCount: 3 * item.profile.frame.binCount)
        let support = try SourceInterval(
            epoch: epoch, startSample: 0,
            sampleCount: Int64(item.profile.frame.frameLength),
            sampleRate: Double(item.profile.frame.sampleRate))
        context = try CepstralFrameContext(
            origin: SourceInterval(
                epoch: epoch, startSample: 0,
                sampleCount: 0, sampleRate: support.sampleRate),
            timing: AnalysisTiming(source: support, includedSampleCount: support.sampleCount),
            frameIndex: 0, firstAnalysisSampleIndex: 0,
            suppliedAnalysisSampleCount: item.profile.frame.frameLength,
            centerSecondsFromOrigin: support.durationSeconds / 2)
        if item.kind == .isolated || item.kind == .export {
            pcm = []
            power = (0..<item.inputSampleCount).map { i in
                let q = Double(i) * item.profile.frame.quefrencyStepSeconds
                let peak = 18 * exp(-pow((q - 0.008) / 0.0003, 2))
                let ripple =
                    item.densePeaks ? 4 * sin(Double(i) * 1.7) + 2 * cos(Double(i) * 0.31) : 0
                return pow(10, (24 - 250 * q + peak + ripple) / 10)
            }
        } else {
            power = []
            var state: UInt32 = 33
            pcm = (0..<item.inputSampleCount).map { i in
                state = 1_664_525 &* state &+ 1_013_904_223
                let noise = (Double(state) - 2_147_483_648) / 42_949_672_960
                let phase =
                    2 * Double.pi * 125 * Double(i)
                    / Double(item.configuration.conditioning.sourceSampleRate)
                return S(0.2 * sin(phase) + 0.1 * sin(2 * phase + 0.13) + noise)
            }
        }
    }
    @inline(never) func prepare() throws -> AnyObject {
        try CPPPrepared<S>(item, epoch: StreamEpoch(streamID: stream))
    }
    @inline(never) func run() throws -> Double { try execute(chunk: item.inputChunkSamples) }
    private func execute(chunk: Int) throws -> Double {
        emitted = 0
        available = 0
        unavailable = 0
        exportedScalars = 0
        checksum = 0
        switch item.kind {
        case .isolated, .export:
            try power.withUnsafeBufferPointer {
                try prepared.cpp!.analyzePowerCepstrum($0, context: context) { consume($0) }
            }
        case .conversion:
            pcm.withUnsafeBufferPointer { input in
                if S.self == Double.self {
                    input.withMemoryRebound(to: Double.self) { converted in
                        for i in converted.indices { checksum += converted[i] * Double(i % 17 + 1) }
                    }
                } else {
                    for i in input.indices { prepared.conversion[i] = Double(input[i]) }
                    for i in prepared.conversion.indices {
                        checksum += prepared.conversion[i] * Double(i % 17 + 1)
                    }
                }
            }
        case .interval, .preview:
            let previous = StreamEpoch(streamID: stream, sequence: sequence)
            sequence += 1
            let epoch = StreamEpoch(streamID: stream, sequence: sequence)
            let source = try SourceInterval(
                epoch: epoch, startSample: 0,
                sampleCount: Int64(pcm.count),
                sampleRate: Double(item.configuration.conditioning.sourceSampleRate))
            try prepared.interval?.reset(source: source)
            try prepared.preview?.reset(
                for: SourceDiscontinuity(
                    previousEpoch: previous,
                    nextEpoch: epoch, reason: .explicitReset))
            try pcm.withUnsafeBufferPointer { samples in
                for start in stride(from: 0, to: samples.count, by: chunk) {
                    let end = min(start + chunk, samples.count)
                    let segment = try SourceInterval(
                        epoch: epoch, startSample: Int64(start),
                        sampleCount: Int64(end - start), sampleRate: source.sampleRate)
                    let buffer = UnsafeBufferPointer(rebasing: samples[start..<end])
                    try prepared.interval?.append(buffer, interval: segment)
                    try prepared.preview?.process(buffer, interval: segment) { consumeFrame($0) }
                }
            }
            try prepared.interval?.finish { consumeFrame($0) }
            try prepared.preview?.finish { consumeFrame($0) }
        }
        return checksum
    }
    private func consumeFrame(_ frame: BorrowedPowerCepstrum<Double>) {
        try! prepared.cpp!.analyze(frame) { consume($0) }
    }
    private func consume(_ output: BorrowedCPPOutput) {
        emitted += 1
        if let observation = output.result.observation {
            available += 1
            // Read all owned scalar diagnostics, without materializing an array.
            checksum +=
                observation.prominenceDB + observation.peakDB * 0.1
                + observation.backgroundDB * 0.01 + observation.peakQuefrencySeconds
                + observation.slopeDBPerSecond * 0.001 + observation.interceptDB * 0.01
                + observation.residualMeanDB * 0.01 + observation.residualRMSDB * 0.01
                + observation.residualMedianDB * 0.01 + observation.residualMaximumAbsoluteDB * 0.01
        } else {
            unavailable += 1
        }
        if item.kind == .export {
            let snapshots = try! output.export(stages: exportStages, policy: exportPolicy)
            for snapshot in snapshots {
                for value in snapshot.values {
                    checksum += value * 1e-12
                    exportedScalars += 1
                }
            }
            // Shared result construction is an explicitly owned export too.
            let measurement = try! output.result.measurementResult()
            checksum += measurement.timing.source.durationSeconds * 1e-12
        }
    }
    func verify() throws -> CPPEvidence {
        let first = try run()
        let counts = [emitted, available, unavailable, UInt64(exportedScalars)]
        let second = try execute(chunk: 63)
        precondition(first == second && first.isFinite && first != 0)
        precondition(counts == [emitted, available, unavailable, UInt64(exportedScalars)])
        let expected: UInt64
        let tail: UInt64
        if let interval = prepared.interval {
            expected = UInt64(interval.layout.frameCount)
            tail = 0
        } else if prepared.preview != nil {
            let outputs =
                item.inputSampleCount * 10_000 / item.configuration.conditioning.sourceSampleRate
            expected = UInt64(
                (outputs - item.profile.frame.frameLength) / item.configuration.previewHopLength!
                    + 1)
            tail = 1
        } else {
            expected = item.kind == .conversion ? 0 : 1
            tail = 0
        }
        precondition(emitted == expected + tail && available == expected && unavailable == tail)
        precondition(
            exportedScalars == (item.kind == .export ? exportPolicy.maximumScalarCount : 0))
        let data =
            power.isEmpty ? pcm.withUnsafeBytes { Data($0) } : power.withUnsafeBytes { Data($0) }
        return CPPEvidence(
            name: item.name, workload: item, inputDurationSeconds: item.inputDurationSeconds,
            inputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            preparedInputBytes: data.count, preparedBufferBytes: prepared.scalarWorkspaceBytes,
            cppBufferBytes: prepared.cpp?.scalarWorkspaceBytes ?? 0,
            fitPointCount: prepared.cpp?.layout.fitPointCount ?? 0,
            slopeEvaluationCount: prepared.cpp?.layout.slopeEvaluationCount ?? 0,
            emittedFrameCount: emitted, availableFrameCount: available,
            unavailableFrameCount: unavailable,
            exportedScalarCount: exportedScalars, checksum: checksum)
    }
}
