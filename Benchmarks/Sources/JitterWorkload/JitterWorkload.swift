import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum JitterOperation: String, CaseIterable {
    case prepare = "Prepare"
    case combined = "Combined"
    case separate = "Separate"
    case queryOnly = "QueryOnly"
    case pulseOnly = "PulseOnly"
    case pcmCombined = "PCMCombined"
    case statisticsOnly = "StatisticsOnly"
}

public struct JitterCase: Sendable, Encodable {
    public enum Kind: String, Sendable, Encodable { case periods, rolling, pcm }
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
    public var operations: [JitterOperation] {
        switch kind {
        case .periods: [.prepare, .combined, .separate]
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
                        for kind in [Kind.periods, .rolling] {
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
    public func makeWorkload() throws -> any JitterBatch {
        if kind != .pcm { return try JitterPeriodWorkload(self) }
        if precision == .float32 { return try JitterPCMWorkload<Float>(self) }
        return try JitterPCMWorkload<Double>(self)
    }
}

public protocol JitterBatch: AnyObject {
    func prepare() throws -> AnyObject
    /// Reset/seeding and input construction are outside the measured operation.
    func prepareRun(_ operation: JitterOperation) throws
    func run(_ operation: JitterOperation) throws -> Double
    func verify() throws -> JitterEvidence
}

public struct JitterEvidence: Encodable {
    public let name: String
    public let workload: JitterCase
    public let configuration: JitterConfiguration
    public let profileIdentity: ProfileIdentity
    public let operations: [String]
    public let inputPeriodCount: Int
    public let measuredPeriodUpdates: Int
    public let windowSampleCount: Int?
    public let frameSampleCount: Int
    public let hopDefinition: String
    public let preparedCombinedBufferBytes: Int
    public let preparedSeparateBufferBytes: Int
    public let preparedInputBytes: Int
    public let periodInputSHA256: String
    public let result: JitterAnalysisResult
    public let checksums: [String: Double]
    public let sumTreeNodeUpdates: UInt64?
    public let observedAppendCount: UInt64?
    public let observedQueryCount: UInt64?
    public let pcm: JitterPCMEvidence?
}

enum JitterWorkloadError: Error { case invalidInput, mismatch, unsupportedOperation }

func jitterSHA(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Independent of Swift struct padding or JSON floating-point formatting.
func jitterPeriodHash(_ periods: [JitterPeriodInput]) -> String {
    var data = Data()
    for period in periods {
        for bits in [period.startSeconds.bitPattern, period.endSeconds.bitPattern, period.runID] {
            var little = bits.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(period.rejections.rawValue)
    }
    return jitterSHA(data)
}

@inline(never) func jitterChecksum(_ result: JitterAnalysisResult) -> Double {
    let c = result.coverage
    return Double(
        c.selectedPeriodCount + c.acceptedPeriodCount + c.meanPeriodCount
            + c.acceptedPairCount + c.acceptedRAPNeighborhoodCount + c.acceptedPPQ5NeighborhoodCount
    )
        + c.acceptedPeriodDurationSeconds + (result.local.value ?? 0) + (result.absolute.value ?? 0)
        + (result.rap.value ?? 0) + (result.ppq5.value ?? 0) + (result.ddp.value ?? 0)
}

final class JitterPeriodWorkload: JitterBatch {
    let item: JitterCase
    let configuration: JitterConfiguration
    let origin: SourceInterval
    let periods: [JitterPeriodInput]
    let dependencies: [SourceInterval]
    let timings: [AnalysisTiming]
    let batchTiming: AnalysisTiming
    let windowPeriods: Int
    let capacity: Int
    let variants = JitterVariant.allCases
    let batch: PreparedJitter?
    let singles: [PreparedJitter]
    let rolling: PreparedRollingJitter?
    let rollingSingles: [PreparedRollingJitter]
    var last: JitterAnalysisResult?
    var lastSeparate: [JitterAnalysisResult?] = Array(repeating: nil, count: 5)

    init(_ item: JitterCase) throws {
        self.item = item
        let isRolling = item.kind == .rolling
        let windowSamples = item.durationMilliseconds * item.sampleRate / 1000
        let profile = try JitterConfiguration(
            sampleRate: item.sampleRate, inputPrecision: item.precision,
            applicability: isRolling ? .exploratoryRolling : .sustainedPhonation,
            rollingWindowSampleCount: isRolling ? windowSamples : nil)
        configuration = profile
        let inputOrigin = try SourceInterval(
            epoch: StreamEpoch(
                streamID:
                    UUID(uuidString: "00000000-0000-0000-0000-000000000050")!),
            startSample: 0, sampleCount: 0, sampleRate: Double(item.sampleRate))
        origin = inputOrigin
        windowPeriods = item.durationMilliseconds * item.frequencyHz / 1000
        let recordCapacity = windowPeriods + 2
        capacity = recordCapacity
        let count = windowPeriods * (isRolling ? 2 : 1)
        // Original alternating +/-1% period perturbation. Endpoints, not
        // repeatedly accumulated durations, define the reproducible input.
        func point(_ i: Int) -> Double {
            Double(i) / Double(item.frequencyHz)
                + (i % 2 == 1 ? 0.01 / Double(item.frequencyHz) : 0)
        }
        periods = try (0..<count).map { i in
            let rejected = item.denseRejections && i % 11 >= 6
            return try JitterPeriodInput(
                startSeconds: point(i), endSeconds: point(i + 1),
                rejections: rejected ? (i % 2 == 0 ? .excluded : .unreliable) : [])
        }
        // Direct supplied observations use a one-sample conservative envelope
        // around their fractional endpoints. This is not a pulse-tracking delay.
        dependencies = try periods.map {
            let start = max(0, Int64(floor($0.startSeconds * Double(item.sampleRate))) - 1)
            let end = Int64(ceil($0.endSeconds * Double(item.sampleRate))) + 1
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
            rolling = try PreparedRollingJitter(
                configuration: profile, origin: inputOrigin,
                maximumPeriodCount: recordCapacity)
            rollingSingles = try variants.map {
                try PreparedRollingJitter(
                    configuration: profile, origin: inputOrigin,
                    maximumPeriodCount: recordCapacity, variant: $0)
            }
        } else {
            batch = try PreparedJitter(configuration: profile, maximumPeriodCount: recordCapacity)
            singles = try variants.map { _ in
                try PreparedJitter(configuration: profile, maximumPeriodCount: recordCapacity)
            }
            rolling = nil
            rollingSingles = []
        }
    }

    @inline(never) func prepare() throws -> AnyObject {
        if item.kind == .rolling {
            return try PreparedRollingJitter(
                configuration: configuration, origin: origin,
                maximumPeriodCount: capacity)
        }
        return try PreparedJitter(configuration: configuration, maximumPeriodCount: capacity)
    }

    func prepareRun(_ operation: JitterOperation) throws {
        guard item.operations.contains(operation) else {
            throw JitterWorkloadError.unsupportedOperation
        }
        last = nil
        if let rolling {
            if operation == .separate {
                for worker in rollingSingles {
                    try worker.reset()
                    for i in 0..<windowPeriods {
                        try worker.append(periods[i], dependency: dependencies[i])
                    }
                }
            } else if operation == .combined || operation == .queryOnly {
                try rolling.reset()
                let count = operation == .queryOnly ? periods.count : windowPeriods
                for i in 0..<count { try rolling.append(periods[i], dependency: dependencies[i]) }
            }
        }
    }

    @inline(never) func run(_ operation: JitterOperation) throws -> Double {
        var checksum = 0.0
        if let batch {
            if operation == .combined {
                let result = try periods.withUnsafeBufferPointer {
                    try batch.analyze($0, dependencyTiming: batchTiming)
                }
                last = result
                return jitterChecksum(result)
            }
            guard operation == .separate else { throw JitterWorkloadError.unsupportedOperation }
            for i in variants.indices {
                let result = try periods.withUnsafeBufferPointer {
                    try singles[i].analyze(variants[i], periods: $0, dependencyTiming: batchTiming)
                }
                lastSeparate[i] = result
                checksum += jitterChecksum(result)
            }
        } else if let rolling {
            if operation == .queryOnly {
                let result = try rolling.result(
                    atSourceSample: dependencies.last!.endSample,
                    dependencyTiming: timings.last!)
                last = result
                return jitterChecksum(result)
            }
            guard operation == .combined || operation == .separate else {
                throw JitterWorkloadError.unsupportedOperation
            }
            for i in windowPeriods..<periods.count {
                if operation == .combined {
                    try rolling.append(periods[i], dependency: dependencies[i])
                    let result = try rolling.result(
                        atSourceSample: dependencies[i].endSample,
                        dependencyTiming: timings[i])
                    last = result
                    checksum += jitterChecksum(result)
                } else {
                    for v in variants.indices {
                        let worker = rollingSingles[v]
                        try worker.append(periods[i], dependency: dependencies[i])
                        let result = try worker.result(
                            atSourceSample: dependencies[i].endSample,
                            dependencyTiming: timings[i])
                        lastSeparate[v] = result
                        checksum += jitterChecksum(result)
                    }
                }
            }
        }
        return checksum
    }

    func verify() throws -> JitterEvidence {
        try prepareRun(.combined)
        let first = try run(.combined)
        guard let result = last else { throw JitterWorkloadError.mismatch }
        let treeUpdates = rolling?.executionStatistics.sumTreeNodeUpdateCount
        let appendCount = rolling?.executionStatistics.appendedPeriodCount
        let queryCount = rolling?.executionStatistics.analyzedQueryCount
        try prepareRun(.combined)
        guard try run(.combined) == first, last == result else {
            throw JitterWorkloadError.mismatch
        }
        try prepareRun(.separate)
        let separate = try run(.separate)
        for i in variants.indices {
            guard let r = lastSeparate[i], r.estimate(variants[i]) == result.estimate(variants[i]),
                r.coverage == result.coverage
            else { throw JitterWorkloadError.mismatch }
        }
        var checksums = [
            JitterOperation.combined.rawValue: first, JitterOperation.separate.rawValue: separate,
        ]
        if item.kind == .rolling {
            try prepareRun(.queryOnly)
            checksums[JitterOperation.queryOnly.rawValue] = try run(.queryOnly)
            guard last == result else { throw JitterWorkloadError.mismatch }
        }
        guard checksums.values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw JitterWorkloadError.mismatch
        }
        let combinedBytes =
            batch?.executionStatistics.preparedBufferBytes
            ?? rolling!.executionStatistics.preparedBufferBytes
        let separateBytes =
            singles.reduce(0) { $0 + $1.executionStatistics.preparedBufferBytes }
            + rollingSingles.reduce(0) { $0 + $1.executionStatistics.preparedBufferBytes }
        return try JitterEvidence(
            name: item.name, workload: item, configuration: configuration,
            profileIdentity: configuration.identity(), operations: item.operations.map(\.rawValue),
            inputPeriodCount: periods.count,
            measuredPeriodUpdates: item.kind == .rolling ? windowPeriods : 0,
            windowSampleCount: configuration.rollingWindowSampleCount,
            frameSampleCount: item.durationMilliseconds * item.sampleRate / 1000,
            hopDefinition: item.kind == .rolling
                ? "oneCompletePeriodVariableSourceHop" : "wholeDeclaredInterval",
            preparedCombinedBufferBytes: combinedBytes, preparedSeparateBufferBytes: separateBytes,
            preparedInputBytes: periods.count * MemoryLayout<JitterPeriodInput>.stride
                + dependencies.count * MemoryLayout<SourceInterval>.stride
                + timings.count * MemoryLayout<AnalysisTiming>.stride,
            periodInputSHA256: jitterPeriodHash(periods), result: result,
            checksums: checksums, sumTreeNodeUpdates: treeUpdates,
            observedAppendCount: appendCount, observedQueryCount: queryCount, pcm: nil)
    }
}
