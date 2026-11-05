import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum YINOperation: String, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}
public enum YINWorkloadKind: String, Codable, Sendable {
    case harmonic = "Harmonic"
    case lowFloor = "LowFloor"
    case maximumSupport = "MaximumSupport"
    case silence = "Silence"
    case noise = "Noise"
    case export = "OwnedDiagnostics"
}

public struct YINCase: Encodable, Sendable {
    public let name: String
    public let kind: YINWorkloadKind
    public let profile: YINProfile
    public let requestedHopMilliseconds: Int
    public let inputSampleCount: Int
    public let chunkSamples = 256
    public var inputDurationSeconds: Double {
        Double(inputSampleCount) / Double(profile.estimator.sampleRate)
    }
    public var shard: String {
        switch kind {
        case .harmonic:
            profile.estimator.inputPrecision == .float32
                ? "float32" : "rate\(profile.estimator.sampleRate)"
        case .lowFloor, .maximumSupport: "support"
        case .silence, .noise: "long-\(profile.estimator.differenceBackend.rawValue)"
        case .export: "export"
        }
    }
    private init(
        _ kind: YINWorkloadKind = .harmonic, rate: Int = 48000,
        precision: AnalysisPrecision = .float64, floor: Int = 50, ceiling: Int = 700,
        hopMS: Int = 10, backend: YINDifferenceBackend = .fft, tracking: Bool = true
    ) throws {
        self.kind = kind
        requestedHopMilliseconds = hopMS
        let c = try YINConfiguration(
            sampleRate: rate, inputPrecision: precision,
            pitchFloorHz: Double(floor), pitchCeilingHz: Double(ceiling),
            integrationLength: kind == .maximumSupport ? 16384 : nil,
            hopLength: (rate * hopMS + 500) / 1000, differenceBackend: backend)
        profile = YINProfile(estimator: c, tracker: tracking ? try YINTrackerConfiguration() : nil)
        inputSampleCount =
            kind == .maximumSupport
            ? c.requiredSampleCount + 3 * c.hopLength
            : rate * ([.silence, .noise].contains(kind) ? 30 : 2)
        name =
            "\(kind.rawValue).\(precision.rawValue).\(rate)Hz.n\(inputSampleCount)"
            + ".f\(floor)-\(ceiling).h\(hopMS).w\(c.integrationLength)"
            + ".\(backend.rawValue).track\(tracking ? 1 : 0)"
    }
    public static func matrix() throws -> [Self] {
        var rows: [Self] = []
        for rate in [16000, 44100, 48000] {
            for hop in [5, 10] {
                for (floor, ceiling) in [(50, 700), (25, 2000)] {
                    for backend in YINDifferenceBackend.allCases {
                        for tracking in [false, true] {
                            rows.append(
                                try Self(
                                    rate: rate, floor: floor, ceiling: ceiling,
                                    hopMS: hop, backend: backend, tracking: tracking))
                            if rate == 48000 {
                                rows.append(
                                    try Self(
                                        rate: rate, precision: .float32,
                                        floor: floor, ceiling: ceiling, hopMS: hop,
                                        backend: backend, tracking: tracking))
                            }
                        }
                    }
                }
            }
            for backend in YINDifferenceBackend.allCases {
                rows.append(
                    try Self(
                        .lowFloor, rate: rate, floor: 25, ceiling: 2000,
                        hopMS: 5, backend: backend))
            }
        }
        for backend in YINDifferenceBackend.allCases {
            rows.append(
                try Self(
                    .maximumSupport, rate: 192000, floor: 20, ceiling: 2000,
                    backend: backend))
            for kind in [YINWorkloadKind.silence, .noise] {
                for tracking in [false, true] {
                    rows.append(
                        try Self(
                            kind, floor: 25, ceiling: 2000, hopMS: 5,
                            backend: backend, tracking: tracking))
                }
            }
        }
        for precision in [AnalysisPrecision.float32, .float64] {
            rows.append(try Self(.export, precision: precision))
        }
        return rows
    }
    public func makeWorkload() throws -> any YINBatch {
        if profile.estimator.inputPrecision == .float32 { return try YINWorkload<Float>(self) }
        return try YINWorkload<Double>(self)
    }
}

public struct YINEvidence: Encodable {
    public let name: String
    public let workload: YINCase
    public let inputDurationSeconds: Double
    public let inputSHA256: String
    public let profileIdentity, estimatorIdentity: ProfileIdentity
    public let trackerIdentity: ProfileIdentity?
    public let preparedInputBytes, preparedBufferBytes, candidateRecordStride, fftLength: Int
    public let integrationLength, supportSamples, hopSamples: Int
    public let supportDurationSeconds, algorithmicDelaySeconds: Double
    public let emittedFrames, fullFrames, partialFrames, voicedFrames, uncertainFrames: Int
    public let unvoicedFrames, unavailableFrames, trackedFrames, changedSelections: Int
    public let exportedCandidates, exportedScalars, exportedJSONBytes: Int
    public let directlyRecomputedLags, scalarFallbackFrames: UInt64
    public let maximumRawDelaySeconds, maximumDependencyDelaySeconds, checksum: Double
    public let exportedByteChecksum: UInt64
}
public protocol YINBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> YINEvidence
}

private struct Counts: Equatable {
    var emitted = 0, full = 0, partial = 0, voiced = 0, uncertain = 0
    var unvoiced = 0, unavailable = 0, tracked = 0, changed = 0
    var exportedCandidates = 0, exportedScalars = 0, exportedJSONBytes = 0
    var rawDelay = 0.0, dependencyDelay = 0.0
}

private final class YINWorkload<S: BinaryFloatingPoint & Sendable>: YINBatch {
    let item: YINCase
    let worker: PreparedYINAnalyzer<S>
    let pcm: [S]
    let exportPolicy: IntermediateOutputPolicy
    let exportStages = Set(YINIntermediate.allCases)
    let encoder: JSONEncoder
    var counts = Counts()
    var checksum = 0.0
    var exportedByteChecksum: UInt64 = 0
    var recomputed: UInt64 = 0, fallbacks: UInt64 = 0

    init(_ item: YINCase) throws {
        self.item = item
        let c = item.profile.estimator
        worker = try PreparedYINAnalyzer(profile: item.profile, epoch: Self.initialEpoch)
        exportPolicy = try IntermediateOutputPolicy(
            maximumScalarCount: 2 * (c.maximumEvaluatedLag + 1))
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var state: UInt32 = 38
        let hz = [.lowFloor, .maximumSupport].contains(item.kind) ? c.pitchFloorHz : 125
        pcm = (0..<item.inputSampleCount).map { index in
            switch item.kind {
            case .silence: return S.zero
            case .noise:
                state = 1_664_525 &* state &+ 1_013_904_223
                return S((Double(state) - 2_147_483_648) / 4_294_967_296)
            default:
                let phase = 2 * Double.pi * hz * Double(index) / Double(c.sampleRate)
                if [.lowFloor, .maximumSupport].contains(item.kind) { return S(0.5 * sin(phase)) }
                return S(0.4 * sin(phase) + 0.1 * sin(2 * phase + 0.13) + 0.04 * sin(3 * phase))
            }
        }
    }
    private static var initialEpoch: StreamEpoch {
        StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000038")!)
    }
    @inline(never) func prepare() throws -> AnyObject {
        try PreparedYINAnalyzer<S>(profile: item.profile, epoch: Self.initialEpoch)
    }
    @inline(never) func run() throws -> Double { try execute(chunk: item.chunkSamples) }
    private func execute(chunk: Int) throws -> Double {
        let old = worker.epoch
        try worker.reset(
            for: SourceDiscontinuity(
                previousEpoch: old, nextEpoch: old.successor(), reason: .explicitReset))
        counts = Counts()
        checksum = 0
        exportedByteChecksum = 0
        let before = worker.estimatorStatistics!
        try pcm.withUnsafeBufferPointer { input in
            for start in stride(from: 0, to: input.count, by: chunk) {
                let end = min(input.count, start + chunk)
                let source = try SourceInterval(
                    epoch: worker.epoch, startSample: Int64(start), sampleCount: Int64(end - start),
                    sampleRate: Double(item.profile.estimator.sampleRate))
                try worker.process(
                    UnsafeBufferPointer(rebasing: input[start..<end]),
                    interval: source, emit: consume)
            }
        }
        try worker.finish(emit: consume)
        let after = worker.estimatorStatistics!
        recomputed = after.directlyRecomputedLagCount - before.directlyRecomputedLagCount
        fallbacks = after.scalarFallbackFrameCount - before.scalarFallbackFrameCount
        return checksum + Double(exportedByteChecksum)
    }
    private func consume(_ output: BorrowedYINAnalysisOutput) {
        let raw = output.raw.result
        counts.emitted += 1
        if raw.timing.source.sampleCount == Int64(raw.requiredSampleCount) {
            counts.full += 1
        } else {
            counts.partial += 1
        }
        switch raw.status {
        case .voiced: counts.voiced += 1
        case .uncertain: counts.uncertain += 1
        case .unvoiced: counts.unvoiced += 1
        case .unavailable: counts.unavailable += 1
        }
        counts.rawDelay = max(counts.rawDelay, raw.timing.effectiveDelaySeconds)
        // Consume results without copying candidate or curve arrays in prepared runs.
        checksum += Double(raw.timing.source.sampleCount + Int64(output.raw.candidates.count))
        if let selected = raw.observation {
            checksum += selected.frequencyHz + selected.periodicity
        }
        if let tracked = output.tracked {
            counts.tracked += 1
            counts.changed += tracked.changedSelection ? 1 : 0
            counts.dependencyDelay = max(
                counts.dependencyDelay, tracked.dependencyTiming.effectiveDelaySeconds)
            checksum +=
                (tracked.observation?.frequencyHz ?? 0)
                + Double(tracked.dependencyTiming.source.sampleCount)
        }
        if item.kind == .export {
            let candidates = try! output.raw.exportCandidates(
                maximumCount: item.profile.estimator.maximumCandidateCount)
            counts.exportedCandidates += candidates.count
            for candidate in candidates {
                checksum += candidate.frequencyHz + candidate.normalizedError
            }
            for snapshot in try! output.raw.export(stages: exportStages, policy: exportPolicy) {
                counts.exportedScalars += snapshot.values.count
                for value in snapshot.values { checksum += value }
            }
            // Persist both timing views. Epoch sequence is deliberately omitted from
            // checksum: it increments between repeated runs but is encoded faithfully.
            let rawData = try! encoder.encode(raw.measurementResult())
            let trackedData = try! encoder.encode(output.tracked!.measurementResult())
            counts.exportedJSONBytes += rawData.count + trackedData.count
            for byte in rawData { exportedByteChecksum &+= UInt64(byte) }
            for byte in trackedData { exportedByteChecksum &+= UInt64(byte) }
        }
    }
    func verify() throws -> YINEvidence {
        let first = try run()
        let rawChecksum = checksum
        var previous = counts
        let oldRecomputed = recomputed
        let oldFallbacks = fallbacks
        let second = try execute(chunk: 137)
        // Different epoch sequence digit lengths can change JSON size only.
        previous.exportedJSONBytes = counts.exportedJSONBytes
        precondition(first.isFinite && first > 0 && second.isFinite && second > 0)
        precondition(rawChecksum == checksum && previous == counts)
        if item.kind != .export { precondition(first == second && exportedByteChecksum == 0) }
        precondition(oldRecomputed == recomputed && oldFallbacks == fallbacks)
        let c = item.profile.estimator
        let full = (pcm.count - c.requiredSampleCount) / c.hopLength + 1
        let partial = full * c.hopLength < pcm.count ? 1 : 0
        precondition(
            counts.full == full && counts.partial == partial && counts.emitted == full + partial)
        precondition(
            counts.voiced + counts.uncertain + counts.unvoiced + counts.unavailable
                == counts.emitted)
        precondition(counts.tracked == (item.profile.tracker == nil ? 0 : counts.emitted))
        precondition(counts.rawDelay == c.algorithmicDelaySeconds)
        if item.kind == .harmonic || item.kind == .export { precondition(counts.voiced == full) }
        if item.kind == .silence { precondition(counts.unvoiced == full) }
        if item.kind == .noise { precondition(counts.voiced == 0) }
        let exporting = item.kind == .export
        precondition(
            counts.exportedScalars == (exporting ? 2 * full * (c.maximumEvaluatedLag + 1) : 0))
        precondition(exporting ? counts.exportedJSONBytes > 0 : counts.exportedJSONBytes == 0)
        let bytes = pcm.withUnsafeBytes { Data($0) }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return YINEvidence(
            name: item.name, workload: item, inputDurationSeconds: item.inputDurationSeconds,
            inputSHA256: hash, profileIdentity: try item.profile.identity(),
            estimatorIdentity: try c.identity(),
            trackerIdentity: try item.profile.tracker?.identity(), preparedInputBytes: bytes.count,
            preparedBufferBytes: worker.preparedBufferBytes,
            candidateRecordStride: MemoryLayout<YINCandidate>.stride,
            fftLength: worker.estimatorStatistics!.fftLength,
            integrationLength: c.integrationLength,
            supportSamples: c.requiredSampleCount, hopSamples: c.hopLength,
            supportDurationSeconds: c.supportDurationSeconds,
            algorithmicDelaySeconds: c.algorithmicDelaySeconds,
            emittedFrames: counts.emitted, fullFrames: counts.full, partialFrames: counts.partial,
            voicedFrames: counts.voiced, uncertainFrames: counts.uncertain,
            unvoicedFrames: counts.unvoiced,
            unavailableFrames: counts.unavailable, trackedFrames: counts.tracked,
            changedSelections: counts.changed,
            exportedCandidates: counts.exportedCandidates, exportedScalars: counts.exportedScalars,
            exportedJSONBytes: counts.exportedJSONBytes, directlyRecomputedLags: recomputed,
            scalarFallbackFrames: fallbacks,
            maximumRawDelaySeconds: counts.rawDelay,
            maximumDependencyDelaySeconds: counts.dependencyDelay,
            checksum: checksum, exportedByteChecksum: exportedByteChecksum)
    }
}
