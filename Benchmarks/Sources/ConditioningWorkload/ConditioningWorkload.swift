import Foundation
import HDXLVoiceProcessing

public enum ConditioningOperation: String, Codable, Sendable, CaseIterable {
    case prepare = "Prepare"
    case condition = "Condition"
    case conditionFFT = "ConditionFFT"
}
public struct ConditioningCase: Codable, Sendable {
    public let name: String
    public let configuration: ConditioningConfiguration
    public let profileIdentity: ProfileIdentity
    public let inputDurationSeconds: Int
    public let inputChunkSamples: Int
    public let outputBlockCapacity: Int
    public let frameSamples: Int
    public let hopSamples: Int
    public let fftLength: Int
    public let intervalsPerIteration: Int
    public var inputSampleCount: Int { inputDurationSeconds * configuration.sourceSampleRate }
    private init(
        source: Int, target: Int, precision: AnalysisPrecision, preview: Bool, chunk: Int,
        duration: Int
    ) throws {
        configuration = try ConditioningConfiguration(
            sourceSampleRate: source, targetSampleRate: target,
            precision: precision,
            method: preview
                ? .streamingPreview(lobes: 32, cutoffFraction: 0.9)
                : .praat7WholeInterval(interpolationDepth: 50), preEmphasisFromHz: 50,
            declaredInputBandwidthHz: Double(source) / 2,
            requiredInputBandwidthHz: Double(min(source, target)) / 2)
        profileIdentity = try configuration.identity()
        inputDurationSeconds = duration
        inputChunkSamples = chunk
        outputBlockCapacity = 256
        frameSamples = 1024
        hopSamples = 256
        fftLength = 1024
        intervalsPerIteration = 1
        name =
            "\(preview ? "Preview" : "Praat7").\(precision.rawValue).\(source)-\(target)Hz.\(duration)s.C\(chunk)"
    }
    public static func matrix() throws -> [Self] {
        var result: [Self] = []
        for precision in [AnalysisPrecision.float32, .float64] {
            for source in [16_000, 44_100, 48_000] {
                for preview in [false, true] {
                    for target in [10_000, 11_000, 16_000] {
                        for chunk in [64, 256, 1024] {
                            result.append(
                                try Self(
                                    source: source, target: target, precision: precision,
                                    preview: preview, chunk: chunk, duration: 1))
                        }
                    }
                    result.append(
                        try Self(
                            source: source, target: 10_000, precision: precision,
                            preview: preview, chunk: 1024, duration: 60))
                }
            }
        }
        return result
    }
    public func makeWorkload() throws -> any ConditioningBatch {
        if configuration.precision == .float32 { return try ConditioningWorkload<Float>(self) }
        return try ConditioningWorkload<Double>(self)
    }
}
public struct ConditioningEvidence: Codable, Sendable {
    public let name: String
    public let workload: ConditioningCase
    public let conditionerScalarWorkspaceBytes: Int
    public let pipelineScalarWorkspaceBytes: Int
    public let preparedInputBytes: Int
    public let outputSampleCount: Int64
    public let outputEnergy: Double
    public let pipelineSpectralEnergy: Double
    public let pipelineFrameCount: Int
    public let filterDelaySeconds: Double
}
public protocol ConditioningBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run(_ operation: ConditioningOperation) throws -> Double
    func verify() throws -> ConditioningEvidence
}

private final class ConditioningWorkload<S: BinaryFloatingPoint & Sendable>: ConditioningBatch {
    let item: ConditioningCase
    let source: SourceInterval
    let input: [S]
    let whole: PreparedIntervalConditioner<S>?
    let preview: PreparedPreviewConditioner<S>?
    let previewLayout: PreviewConditioningLayout?
    let framer: PCMFramer<S>
    let framing: FramingConfiguration
    let fft: PreparedFourierTransform<S>
    let bins: UnsafeMutableBufferPointer<FourierBin<S>>
    // This benchmark target-domain epoch is distinct from the original source epoch.
    let targetStream = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
    var sequence: UInt64 = 0
    var outputCount: Int64 = 0
    var energy = 0.0, spectralEnergy = 0.0, directFrameEnergy = 0.0
    var frames = 0
    var verifyFrames = false
    init(_ item: ConditioningCase) throws {
        self.item = item
        source = try SourceInterval(
            epoch: StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!),
            startSample: 0, sampleCount: Int64(item.inputSampleCount),
            sampleRate: Double(item.configuration.sourceSampleRate))
        var state: UInt32 = 31
        input = (0..<item.inputSampleCount).map { _ in
            state = 1_664_525 &* state &+ 1_013_904_223
            return S((Double(state) - 2_147_483_648) / 4_294_967_296)
        }
        if case .streamingPreview = item.configuration.method {
            let layout = try PreviewConditioningLayout(
                configuration: item.configuration, outputBlockCapacity: item.outputBlockCapacity)
            previewLayout = layout
            preview = try PreparedPreviewConditioner(layout: layout, epoch: source.epoch)
            whole = nil
        } else {
            previewLayout = nil
            preview = nil
            whole = try PreparedIntervalConditioner(
                configuration: item.configuration, source: source)
        }
        framing = try FramingConfiguration(
            window: WindowSpecification(
                definition: .rectangular,
                sampleCount: item.frameSamples,
                sampleRate: Double(item.configuration.targetSampleRate),
                precision: item.configuration.precision),
            hopLength: item.hopSamples, partialWindowPolicy: .discard)
        framer = try PCMFramer(configuration: framing, epoch: StreamEpoch(streamID: targetStream))
        fft = try PreparedFourierTransform(
            FourierConfiguration(
                length: item.fftLength,
                sampleRate: Double(item.configuration.targetSampleRate),
                precision: item.configuration.precision))
        bins = .allocate(capacity: item.fftLength / 2 + 1)
        bins.initialize(repeating: FourierBin(real: 0))
    }
    deinit {
        bins.deinitialize()
        bins.deallocate()
    }
    @inline(never) func prepare() throws -> AnyObject {
        if let previewLayout {
            return try PreparedPreviewConditioner<S>(layout: previewLayout, epoch: source.epoch)
        }
        return try PreparedIntervalConditioner<S>(configuration: item.configuration, source: source)
    }
    @inline(never) func run(_ operation: ConditioningOperation) throws -> Double {
        precondition(operation != .prepare)
        let pipeline = operation == .conditionFFT
        outputCount = 0
        energy = 0
        spectralEnergy = 0
        directFrameEnergy = 0
        frames = 0
        if let whole { try whole.reset(source: source) }
        if let preview { try preview.reset(epoch: source.epoch) }
        if pipeline {
            let previous = StreamEpoch(streamID: targetStream, sequence: sequence)
            sequence += 1
            try framer.reset(
                for: SourceDiscontinuity(
                    previousEpoch: previous,
                    nextEpoch: StreamEpoch(streamID: targetStream, sequence: sequence),
                    reason: .explicitReset))
        }
        try input.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(item.inputChunkSamples, buffer.count - offset)
                let part = UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)])
                let interval = try SourceInterval(
                    epoch: source.epoch, startSample: Int64(offset),
                    sampleCount: Int64(count), sampleRate: source.sampleRate)
                if let whole {
                    try whole.append(part, interval: interval)
                } else {
                    try preview!.process(part, interval: interval) { output, _ in
                        consume(output, pipeline: pipeline)
                    }
                }
                offset += count
            }
        }
        if let whole {
            try whole.finish { output, _ in consume(output, pipeline: pipeline) }
        } else {
            try preview!.finish { output, _ in consume(output, pipeline: pipeline) }
        }
        if pipeline {
            try framer.finish { _, _ in preconditionFailure("Discarded partial window emitted") }
        }
        return pipeline ? spectralEnergy : energy
    }
    private func consume(_ output: UnsafeBufferPointer<S>, pipeline: Bool) {
        if pipeline {
            let interval = try! SourceInterval(
                epoch: StreamEpoch(streamID: targetStream, sequence: sequence),
                startSample: outputCount, sampleCount: Int64(output.count),
                sampleRate: Double(item.configuration.targetSampleRate))
            try! framer.process(output, interval: interval) { frame, _ in
                try! fft.forwardReal(frame, into: bins)
                var squared = 0.0
                for k in bins.indices {
                    let r = Double(bins[k].real)
                    let i = Double(bins[k].imaginary)
                    squared += (k == 0 || k == bins.count - 1 ? 1 : 2) * (r * r + i * i)
                }
                spectralEnergy += squared / Double(item.fftLength)
                frames += 1
                if verifyFrames {
                    directFrameEnergy += frame.reduce(0) { $0 + Double($1) * Double($1) }
                }
            }
        } else {
            for value in output { energy += Double(value) * Double(value) }
        }
        outputCount += Int64(output.count)
    }
    func verify() throws -> ConditioningEvidence {
        let expectedCount = Int64(item.inputDurationSeconds * item.configuration.targetSampleRate)
        let energy = try run(.condition)
        precondition(outputCount == expectedCount && energy.isFinite && energy > 0)
        verifyFrames = true
        let spectral = try run(.conditionFFT)
        verifyFrames = false
        let expectedFrames = (Int(expectedCount) - item.frameSamples) / item.hopSamples + 1
        precondition(outputCount == expectedCount && frames == expectedFrames)
        let tolerance = item.configuration.precision == .float32 ? 2e-6 : 2e-12
        precondition(abs(spectral - directFrameEnergy) <= tolerance * max(1, directFrameEnergy))
        let bytes = whole?.scalarWorkspaceBytes ?? preview!.scalarWorkspaceBytes
        return ConditioningEvidence(
            name: item.name, workload: item, conditionerScalarWorkspaceBytes: bytes,
            pipelineScalarWorkspaceBytes: bytes + fft.scalarWorkspaceBytes
                + bins.count * MemoryLayout<FourierBin<S>>.stride + 3 * item.frameSamples
                * MemoryLayout<S>.stride,
            preparedInputBytes: input.count * MemoryLayout<S>.stride,
            outputSampleCount: expectedCount,
            outputEnergy: energy, pipelineSpectralEnergy: spectral, pipelineFrameCount: frames,
            filterDelaySeconds: whole?.layout.effectiveDelaySeconds
                ?? previewLayout!.maximumFilterLookaheadSeconds)
    }
}
