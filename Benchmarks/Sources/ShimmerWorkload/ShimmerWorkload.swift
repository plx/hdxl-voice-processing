import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum ShimmerOperation: String, CaseIterable {
    case prepare = "Prepare"
    case combined = "Combined"
    case separate = "Separate"
    case queryOnly = "QueryOnly"
    case pulseOnly = "PulseOnly"
    case pcmCombined = "PCMCombined"
    case statisticsOnly = "StatisticsOnly"
}

public struct ShimmerCase: Sendable, Encodable {
    public enum Kind: String, Sendable, Encodable { case amplitudes, rolling, pcm }
    public let kind: Kind
    public let durationMilliseconds: Int
    public let frequencyHz: Int
    public let denseRejections: Bool
    public let precision: AnalysisPrecision
    public let sampleRate = 16000
    public var shard: String { kind == .pcm ? "pcm" : "duration\(durationMilliseconds)" }
    public var name: String {
        "\(kind.rawValue).\(durationMilliseconds)ms.\(frequencyHz)hz.\(denseRejections ? "dense" : "accepted").\(precision.rawValue)"
    }
    public var operations: [ShimmerOperation] {
        switch kind {
        case .amplitudes: [.prepare, .combined, .separate]
        case .rolling: [.prepare, .combined, .separate, .queryOnly]
        case .pcm: [.prepare, .pulseOnly, .pcmCombined, .statisticsOnly]
        }
    }
    public static func matrix() -> [Self] {
        var rows: [Self] = []
        for precision in [AnalysisPrecision.float32, .float64] {
            for hz in [80, 600] {
                for milliseconds in [250, 1000, 3000, 10000] {
                    for dense in [false, true] {
                        for kind in [Kind.amplitudes, .rolling] {
                            rows.append(
                                Self(
                                    kind: kind, durationMilliseconds: milliseconds,
                                    frequencyHz: hz, denseRejections: dense, precision: precision))
                        }
                    }
                }
                rows.append(
                    Self(
                        kind: .pcm, durationMilliseconds: 500, frequencyHz: hz,
                        denseRejections: false, precision: precision))
            }
        }
        return rows
    }
    public func makeWorkload() throws -> any ShimmerBatch {
        if kind != .pcm { return try ShimmerAmplitudeWorkload(self) }
        if precision == .float32 { return try ShimmerPCMWorkload<Float>(self) }
        return try ShimmerPCMWorkload<Double>(self)
    }
}

public protocol ShimmerBatch: AnyObject {
    func prepare() throws -> AnyObject
    /// Reset/seeding and input construction are outside the measured operation.
    func prepareRun(_ operation: ShimmerOperation) throws
    func run(_ operation: ShimmerOperation) throws -> Double
    func verify() throws -> ShimmerEvidence
}

public struct ShimmerEvidence: Encodable {
    public let name: String
    public let workload: ShimmerCase
    public let configuration: ShimmerConfiguration
    public let profileIdentity: ProfileIdentity
    public let operations: [String]
    public let inputAmplitudeCount: Int
    public let measuredAmplitudeUpdates: Int
    public let windowSampleCount: Int?
    public let frameSampleCount: Int
    public let hopDefinition: String
    public let preparedCombinedBufferBytes: Int
    public let preparedSeparateBufferBytes: Int
    public let preparedInputBytes: Int
    public let amplitudeInputSHA256: String
    public let result: ShimmerAnalysisResult
    public let checksums: [String: Double]
    public let evaluatedAmplitudes: UInt64?
    public let observedAppendCount: UInt64?
    public let observedQueryCount: UInt64?
    public let pcm: ShimmerPCMEvidence?
}

enum ShimmerWorkloadError: Error { case invalidInput, mismatch, unsupportedOperation }

func shimmerSHA(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Independent of Swift struct padding or JSON floating-point formatting.
func shimmerAmplitudeHash(_ amplitudes: [ShimmerAmplitudeInput]) -> String {
    var data = Data()
    for amplitude in amplitudes {
        for bits in [
            amplitude.timeSeconds.bitPattern, (amplitude.amplitude ?? 0).bitPattern,
            amplitude.sequenceIndex, amplitude.runID,
        ] {
            var little = bits.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        var flags = amplitude.rejections.rawValue.littleEndian
        withUnsafeBytes(of: &flags) { data.append(contentsOf: $0) }
        data.append(amplitude.amplitude == nil ? 0 : 1)
    }
    return shimmerSHA(data)
}

@inline(never) func shimmerChecksum(_ result: ShimmerAnalysisResult) -> Double {
    let c = result.coverage
    return Double(
        c.selectedAmplitudeCount + c.acceptedAmplitudeCount + c.normalizationAmplitudeCount
            + c.acceptedPairCount + c.acceptedAPQ3NeighborhoodCount
            + c.acceptedAPQ5NeighborhoodCount
            + c.acceptedAPQ11NeighborhoodCount) + c.acceptedPairDurationSeconds
        + (result.local.value ?? 0) + (result.db.value ?? 0) + (result.apq3.value ?? 0)
        + (result.apq5.value ?? 0) + (result.apq11.value ?? 0) + (result.dda.value ?? 0)
}

final class ShimmerAmplitudeWorkload: ShimmerBatch {
    let item: ShimmerCase
    let configuration: ShimmerConfiguration
    let origin: SourceInterval
    let amplitudes: [ShimmerAmplitudeInput]
    let dependencies: [SourceInterval]
    let timings: [AnalysisTiming]
    let batchTiming: AnalysisTiming
    let windowAmplitudes: Int
    let capacity: Int
    let variants = ShimmerVariant.allCases
    let batch: PreparedShimmer?
    let singles: [PreparedShimmer]
    let rolling: PreparedRollingShimmer?
    let rollingSingles: [PreparedRollingShimmer]
    var last: ShimmerAnalysisResult?
    var lastSeparate: [ShimmerAnalysisResult?] = Array(repeating: nil, count: 6)

    init(_ item: ShimmerCase) throws {
        self.item = item
        let isRolling = item.kind == .rolling
        let windowSamples = item.durationMilliseconds * item.sampleRate / 1000
        let profile = try ShimmerConfiguration(
            sampleRate: item.sampleRate, inputPrecision: item.precision,
            applicability: isRolling ? .exploratoryRolling : .sustainedPhonation,
            rollingWindowSampleCount: isRolling ? windowSamples : nil)
        configuration = profile
        let inputOrigin = try SourceInterval(
            epoch: StreamEpoch(
                streamID:
                    UUID(uuidString: "00000000-0000-0000-0000-000000000051")!),
            startSample: 0, sampleCount: 0, sampleRate: Double(item.sampleRate))
        origin = inputOrigin
        windowAmplitudes = item.durationMilliseconds * item.frequencyHz / 1000
        let recordCapacity = windowAmplitudes + 2
        capacity = recordCapacity
        let count = windowAmplitudes + (isRolling ? min(64, windowAmplitudes) : 0)
        // Original alternating +/-10% amplitudes. Dense cases combine source
        // exclusions with isolated 4x outliers that reject numerical edges.
        amplitudes = try (0..<count).map { i in
            let rejected = item.denseRejections && i % 17 >= 10
            let value = item.denseRejections && i % 17 == 7 ? 4.0 : (i % 2 == 0 ? 0.9 : 1.1)
            return try ShimmerAmplitudeInput(
                timeSeconds: Double(i + 1) / Double(item.frequencyHz), amplitude: value,
                sequenceIndex: UInt64(i),
                rejections: rejected ? (i % 2 == 0 ? .excluded : .unreliable) : [])
        }
        // Supplied amplitudes declare a one-sample padded support envelope.
        // This is not a waveform tracking or extraction delay.
        dependencies = try amplitudes.map {
            let start = max(0, Int64(floor($0.timeSeconds * Double(item.sampleRate))) - 1)
            let end = Int64(ceil($0.timeSeconds * Double(item.sampleRate))) + 1
            return try SourceInterval(
                epoch: inputOrigin.epoch, startSample: start,
                sampleCount: end - start, sampleRate: inputOrigin.sampleRate)
        }
        timings = try dependencies.map {
            let source = try SourceInterval(
                epoch: inputOrigin.epoch, startSample: 0,
                sampleCount: $0.endSample, sampleRate: inputOrigin.sampleRate)
            return try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        }
        batchTiming = try AnalysisTiming(
            source: SourceInterval(
                epoch: origin.epoch,
                startSample: 0, sampleCount: Int64(windowSamples), sampleRate: origin.sampleRate),
            includedSampleCount: Int64(windowSamples))
        if isRolling {
            batch = nil
            singles = []
            rolling = try PreparedRollingShimmer(
                configuration: profile, origin: inputOrigin,
                maximumAmplitudeCount: recordCapacity)
            rollingSingles = try variants.map {
                try PreparedRollingShimmer(
                    configuration: profile, origin: inputOrigin,
                    maximumAmplitudeCount: recordCapacity, variant: $0)
            }
        } else {
            batch = try PreparedShimmer(
                configuration: profile, maximumAmplitudeCount: recordCapacity)
            singles = try variants.map { _ in
                try PreparedShimmer(configuration: profile, maximumAmplitudeCount: recordCapacity)
            }
            rolling = nil
            rollingSingles = []
        }
    }

    @inline(never) func prepare() throws -> AnyObject {
        if item.kind == .rolling {
            return try PreparedRollingShimmer(
                configuration: configuration, origin: origin,
                maximumAmplitudeCount: capacity)
        }
        return try PreparedShimmer(configuration: configuration, maximumAmplitudeCount: capacity)
    }

    func prepareRun(_ operation: ShimmerOperation) throws {
        guard item.operations.contains(operation) else {
            throw ShimmerWorkloadError.unsupportedOperation
        }
        last = nil
        if let rolling {
            if operation == .separate {
                for worker in rollingSingles {
                    try worker.reset()
                    for i in 0..<windowAmplitudes {
                        try worker.append(amplitudes[i], dependency: dependencies[i])
                    }
                }
            } else if operation == .combined || operation == .queryOnly {
                try rolling.reset()
                let count = operation == .queryOnly ? amplitudes.count : windowAmplitudes
                for i in 0..<count {
                    try rolling.append(amplitudes[i], dependency: dependencies[i])
                }
            }
        }
    }

    @inline(never) func run(_ operation: ShimmerOperation) throws -> Double {
        var checksum = 0.0
        if let batch {
            if operation == .combined {
                let result = try amplitudes.withUnsafeBufferPointer {
                    try batch.analyze($0, dependencyTiming: batchTiming)
                }
                last = result
                return shimmerChecksum(result)
            }
            guard operation == .separate else { throw ShimmerWorkloadError.unsupportedOperation }
            for i in variants.indices {
                let result = try amplitudes.withUnsafeBufferPointer {
                    try singles[i].analyze(
                        variants[i], amplitudes: $0, dependencyTiming: batchTiming)
                }
                lastSeparate[i] = result
                checksum += shimmerChecksum(result)
            }
        } else if let rolling {
            if operation == .queryOnly {
                let result = try rolling.result(
                    atSourceSample: dependencies.last!.endSample,
                    dependencyTiming: timings.last!)
                last = result
                return shimmerChecksum(result)
            }
            guard operation == .combined || operation == .separate else {
                throw ShimmerWorkloadError.unsupportedOperation
            }
            for i in windowAmplitudes..<amplitudes.count {
                if operation == .combined {
                    try rolling.append(amplitudes[i], dependency: dependencies[i])
                    let result = try rolling.result(
                        atSourceSample: dependencies[i].endSample,
                        dependencyTiming: timings[i])
                    last = result
                    checksum += shimmerChecksum(result)
                } else {
                    for v in variants.indices {
                        let worker = rollingSingles[v]
                        try worker.append(amplitudes[i], dependency: dependencies[i])
                        let result = try worker.result(
                            atSourceSample: dependencies[i].endSample,
                            dependencyTiming: timings[i])
                        lastSeparate[v] = result
                        checksum += shimmerChecksum(result)
                    }
                }
            }
        }
        return checksum
    }

    func verify() throws -> ShimmerEvidence {
        try prepareRun(.combined)
        let first = try run(.combined)
        guard let result = last else { throw ShimmerWorkloadError.mismatch }
        let evaluated = rolling?.executionStatistics.evaluatedAmplitudeCount
        let appendCount = rolling?.executionStatistics.appendedAmplitudeCount
        let queryCount = rolling?.executionStatistics.analyzedQueryCount
        try prepareRun(.combined)
        guard try run(.combined) == first, last == result else {
            throw ShimmerWorkloadError.mismatch
        }
        try prepareRun(.separate)
        let separate = try run(.separate)
        for i in variants.indices {
            guard let r = lastSeparate[i], r.estimate(variants[i]) == result.estimate(variants[i]),
                r.coverage == result.coverage
            else { throw ShimmerWorkloadError.mismatch }
        }
        var checksums = [
            ShimmerOperation.combined.rawValue: first, ShimmerOperation.separate.rawValue: separate,
        ]
        if item.kind == .rolling {
            try prepareRun(.queryOnly)
            checksums[ShimmerOperation.queryOnly.rawValue] = try run(.queryOnly)
            guard last == result else { throw ShimmerWorkloadError.mismatch }
        }
        guard checksums.values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw ShimmerWorkloadError.mismatch
        }
        let combinedBytes =
            batch?.executionStatistics.preparedBufferBytes
            ?? rolling!.executionStatistics.preparedBufferBytes
        let separateBytes =
            singles.reduce(0) { $0 + $1.executionStatistics.preparedBufferBytes }
            + rollingSingles.reduce(0) { $0 + $1.executionStatistics.preparedBufferBytes }
        return try ShimmerEvidence(
            name: item.name, workload: item, configuration: configuration,
            profileIdentity: configuration.identity(), operations: item.operations.map(\.rawValue),
            inputAmplitudeCount: amplitudes.count,
            measuredAmplitudeUpdates: item.kind == .rolling
                ? amplitudes.count - windowAmplitudes : 0,
            windowSampleCount: configuration.rollingWindowSampleCount,
            frameSampleCount: item.durationMilliseconds * item.sampleRate / 1000,
            hopDefinition: item.kind == .rolling
                ? "oneAmplitudeVariableSourceHop" : "wholeDeclaredInterval",
            preparedCombinedBufferBytes: combinedBytes, preparedSeparateBufferBytes: separateBytes,
            preparedInputBytes: amplitudes.count * MemoryLayout<ShimmerAmplitudeInput>.stride
                + dependencies.count * MemoryLayout<SourceInterval>.stride
                + timings.count * MemoryLayout<AnalysisTiming>.stride,
            amplitudeInputSHA256: shimmerAmplitudeHash(amplitudes), result: result,
            checksums: checksums, evaluatedAmplitudes: evaluated,
            observedAppendCount: appendCount, observedQueryCount: queryCount, pcm: nil)
    }
}
