import Foundation
import HDXLVoiceProcessing

public enum LevelOperation: String, Codable, Sendable, CaseIterable {
    case prepare = "Prepare"
    case analyze = "Analyze"
}
public enum LevelSignal: String, Codable, Sendable { case noise, silence, denormal }

public struct LevelCase: Codable, Sendable {
    public let name: String
    public let configurations: [LevelConfiguration]
    public let profileIdentities: [ProfileIdentity]
    public let signal: LevelSignal
    public let inputDurationSeconds: Int
    public let inputChunkSamples: Int
    public let instances: Int

    private init(
        rates: [Int], milliseconds: [Int], precision: AnalysisPrecision,
        method: LevelAccumulation, weighted: Bool, signal: LevelSignal
    ) throws {
        configurations = try zip(rates, milliseconds).map { rate, duration in
            try LevelConfiguration(
                sampleRate: rate, inputPrecision: precision,
                windowLength: rate * duration / 1000, hopLength: rate / 100,
                accumulation: method,
                weighting: weighted ? .bs1770Revision5(warmupSampleCount: rate / 10) : .none,
                partialWindowPolicy: .discard)
        }
        profileIdentities = try configurations.map { try $0.identity() }
        self.signal = signal
        inputDurationSeconds = 1
        inputChunkSamples = 256
        instances = rates.count
        let geometry = zip(rates, milliseconds).map { "\($0)Hz-\($1)ms" }.joined(separator: "+")
        name =
            "\(precision.rawValue).\(method.rawValue).\(weighted ? "K" : "Raw").\(signal.rawValue).\(geometry)"
    }
    public static func matrix() throws -> [Self] {
        var cases: [Self] = []
        for precision in [AnalysisPrecision.float32, .float64] {
            for method in [LevelAccumulation.direct, .compensatedSliding] {
                for rate in [16_000, 44_100, 48_000] {
                    for duration in [10, 50, 400] {
                        for weighted in [false, true] {
                            cases.append(
                                try Self(
                                    rates: [rate], milliseconds: [duration], precision: precision,
                                    method: method, weighted: weighted, signal: .noise))
                        }
                    }
                    for signal in [LevelSignal.silence, .denormal] {
                        cases.append(
                            try Self(
                                rates: [rate], milliseconds: [400], precision: precision,
                                method: method, weighted: true, signal: signal))
                    }
                }
                cases.append(
                    try Self(
                        rates: [16_000, 44_100, 48_000], milliseconds: [10, 50, 400],
                        precision: precision,
                        method: method, weighted: true, signal: .noise))
            }
        }
        return cases
    }
    public func makeWorkload() throws -> any LevelBatch {
        if configurations[0].inputPrecision == .float32 { return try LevelWorkload<Float>(self) }
        return try LevelWorkload<Double>(self)
    }
}

public struct LevelEvidence: Codable, Sendable {
    public let name: String
    public let workload: LevelCase
    public let preparedBufferBytes: Int
    public let preparedInputBytes: Int
    public let frameCount: Int
    public let warmupWindowCount: Int
    public let weightedAvailableWindowCount: Int
    public let weightedRangeLimitedWindowCount: Int
    public let subnormalInputWindowCount: Int
    public let checksum: Double
}

public protocol LevelBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> LevelEvidence
}

private final class LevelPreparedGroup<S: BinaryFloatingPoint & Sendable> {
    let workers: [PreparedLevelAnalyzer<S>]
    init(_ item: LevelCase, epoch: StreamEpoch) throws {
        workers = try item.configurations.map {
            try PreparedLevelAnalyzer(configuration: $0, epoch: epoch)
        }
    }
}

private final class LevelWorkload<S: BinaryFloatingPoint & Sendable>: LevelBatch {
    let item: LevelCase
    let prepared: LevelPreparedGroup<S>
    let inputs: [[S]]
    let stream = UUID(uuidString: "00000000-0000-0000-0000-000000000132")!
    var sequence: UInt64 = 0
    var frames = 0, warming = 0, weightedAvailable = 0, limited = 0, subnormal = 0
    var checksum = 0.0

    init(_ item: LevelCase) throws {
        self.item = item
        prepared = try LevelPreparedGroup(item, epoch: StreamEpoch(streamID: stream))
        inputs = item.configurations.map { config in
            var state: UInt32 = 32
            return (0..<(config.sampleRate * item.inputDurationSeconds)).map { _ in
                state = 1_664_525 &* state &+ 1_013_904_223
                switch item.signal {
                case .noise: return S((Double(state) - 2_147_483_648) / 4_294_967_296)
                case .silence: return S.zero
                case .denormal: return S.leastNormalMagnitude / 64 * S(Int(state % 31) - 15)
                }
            }
        }
    }
    @inline(never) func prepare() throws -> AnyObject {
        try LevelPreparedGroup<S>(item, epoch: StreamEpoch(streamID: stream))
    }
    @inline(never) func run() throws -> Double { try execute(chunk: item.inputChunkSamples) }

    private func execute(chunk: Int) throws -> Double {
        let previous = StreamEpoch(streamID: stream, sequence: sequence)
        sequence += 1
        let epoch = StreamEpoch(streamID: stream, sequence: sequence)
        frames = 0
        warming = 0
        weightedAvailable = 0
        limited = 0
        subnormal = 0
        checksum = 0
        for index in prepared.workers.indices {
            let worker = prepared.workers[index]
            let config = item.configurations[index]
            try worker.reset(
                for: SourceDiscontinuity(
                    previousEpoch: previous, nextEpoch: epoch, reason: .explicitReset))
            try inputs[index].withUnsafeBufferPointer { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = min(chunk, buffer.count - offset)
                    try worker.process(
                        UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                        interval: SourceInterval(
                            epoch: epoch, startSample: Int64(offset),
                            sampleCount: Int64(count), sampleRate: Double(config.sampleRate))
                    ) {
                        consume($0)
                    }
                    offset += count
                }
            }
            try worker.finish { _ in
                preconditionFailure("Discard policy emitted partial level window")
            }
        }
        return checksum
    }
    private func consume(_ result: LevelWindowResult) {
        frames += 1
        let energy = result.unweighted.energy!
        checksum += energy.normalizedMeanSquare
        if result.input.subnormalSampleCount > 0 { subnormal += 1 }
        if result.weighted != nil && result.warmupSamplesRemainingAtWindowStart > 0 {
            warming += 1
        } else if let energy = result.weighted?.energy {
            weightedAvailable += 1
            checksum += 3 * energy.normalizedMeanSquare
        } else if result.weighted == .unavailable(.unsupportedRange) {
            limited += 1
        }
    }
    func verify() throws -> LevelEvidence {
        let checksum = try run()
        let counts = [frames, warming, weightedAvailable, limited, subnormal]
        let splitChecksum = try execute(chunk: 63)
        precondition(splitChecksum == checksum)
        precondition(counts == [frames, warming, weightedAvailable, limited, subnormal])
        var expectedFrames = 0
        var expectedWarmup = 0
        var expectedWeighted = 0
        for config in item.configurations {
            let n = (config.sampleRate - config.windowLength) / config.hopLength + 1
            expectedFrames += n
            if config.kWeighting != nil {
                expectedWarmup += min(n, 10)
                expectedWeighted += max(0, n - 10)
            }
        }
        precondition(frames == expectedFrames && warming == expectedWarmup)
        let expectedLimited =
            item.signal == .denormal && S.self == Double.self ? expectedWeighted : 0
        precondition(
            limited == expectedLimited && weightedAvailable == expectedWeighted - expectedLimited)
        precondition(subnormal == (item.signal == .denormal ? expectedFrames : 0))
        precondition(checksum.isFinite && (item.signal == .silence ? checksum == 0 : checksum > 0))
        return LevelEvidence(
            name: item.name, workload: item,
            preparedBufferBytes: prepared.workers.reduce(0) {
                $0 + $1.executionStatistics.preparedBufferBytes
            },
            preparedInputBytes: inputs.reduce(0) { $0 + $1.count * MemoryLayout<S>.stride },
            frameCount: frames, warmupWindowCount: warming,
            weightedAvailableWindowCount: weightedAvailable,
            weightedRangeLimitedWindowCount: limited,
            subnormalInputWindowCount: subnormal, checksum: checksum)
    }
}
