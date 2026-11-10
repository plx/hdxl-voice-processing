import CryptoKit
import Foundation
import HDXLVoiceProcessing

public struct SWIPEPrimeWorkloadCounts: Equatable, Encodable {
    public var full = 0, partial = 0, voiced = 0, uncertain = 0, unvoiced = 0, unavailable = 0
    public var exportedScalarSlots = 0, exportedJSONBytes = 0
}
public struct SWIPEPrimeWorkloadProbe: Encodable {
    public let frameIndex: UInt64
    public let startSample, observedSamples: Int64
    public let frequencyHz, strength: Double?
    public let status: String
}
public struct SWIPEPrimeWorkloadEvidence: Encodable {
    public let workload: SWIPEPrimeCase
    public let algorithm: SWIPEPrimeBenchmarkAlgorithm
    public let profileIdentity: ProfileIdentity
    public let inputSHA256: String
    public let preparedInputBytes, preparedBufferBytes, supportSamples, hopSamples: Int
    public let supportSeconds, algorithmicDelaySeconds: Double
    public let windowLengths: [Int]
    public let candidateCount, erbBinCount: Int
    public let counts: SWIPEPrimeWorkloadCounts
    public let checksum: Double
    public let probes: [SWIPEPrimeWorkloadProbe]
}
public protocol SWIPEPrimeBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> SWIPEPrimeWorkloadEvidence
}

final class SWIPEPrimeWorkload<S: BinaryFloatingPoint & Sendable>: SWIPEPrimeBatch {
    let item: SWIPEPrimeCase
    let algorithm: SWIPEPrimeBenchmarkAlgorithm
    let swipe: PreparedSWIPEPrimeAnalyzer<S>?
    let yin: PreparedYINAnalyzer<S>?
    let pcm: [S]
    let support: Int
    let hop: Int
    let exportPolicy: IntermediateOutputPolicy
    let yinStages = Set(YINIntermediate.allCases)
    let kernelIndices: [Int]
    let encoder: JSONEncoder
    var counts = SWIPEPrimeWorkloadCounts()
    var checksum = 0.0
    var probes: [SWIPEPrimeWorkloadProbe] = []
    var collectProbes = false
    let probeIndices: [UInt64]

    private static var initialEpoch: StreamEpoch {
        StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000044")!)
    }
    init(_ item: SWIPEPrimeCase, algorithm: SWIPEPrimeBenchmarkAlgorithm) throws {
        self.item = item
        self.algorithm = algorithm
        let c = item.configuration
        if algorithm == .swipePrime {
            swipe = try PreparedSWIPEPrimeAnalyzer(configuration: c, epoch: Self.initialEpoch)
            yin = nil
            support = c.requiredSampleCount
            hop = c.hopLength
        } else {
            yin = try PreparedYINAnalyzer(profile: item.baseline, epoch: Self.initialEpoch)
            swipe = nil
            support = item.baseline.estimator.requiredSampleCount
            hop = item.baseline.estimator.hopLength
        }
        let last = UInt64((item.inputSampleCount - support) / hop)
        probeIndices = Array(Set([0, last / 2, last])).sorted()
        let layout = SWIPEPrimeLayout(configuration: c)
        kernelIndices = [
            0, layout.candidateFrequenciesHz.count / 2, layout.candidateFrequenciesHz.count - 1,
        ]
        exportPolicy = try IntermediateOutputPolicy(maximumScalarCount: 4_000_000)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var state: UInt32 = 44
        pcm = (0..<item.inputSampleCount).map { index in
            switch item.kind {
            case .silence: return S.zero
            case .noise:
                state = 1_664_525 &* state &+ 1_013_904_223
                return S((Double(state) - 2_147_483_648) / 4_294_967_296)
            default:
                let phase = 2 * Double.pi * 125 * Double(index) / Double(c.sampleRate)
                return S(0.4 * sin(phase) + 0.1 * sin(2 * phase + 0.13) + 0.04 * sin(3 * phase))
            }
        }
    }

    @inline(never) func prepare() throws -> AnyObject {
        switch algorithm {
        case .swipePrime:
            try PreparedSWIPEPrimeAnalyzer<S>(
                configuration: item.configuration, epoch: Self.initialEpoch)
        case .yinFFT: try PreparedYINAnalyzer<S>(profile: item.baseline, epoch: Self.initialEpoch)
        }
    }
    @inline(never) func run() throws -> Double { try execute(chunk: item.chunkSamples) }

    private func execute(chunk: Int) throws -> Double {
        let old = swipe?.epoch ?? yin!.epoch
        let boundary = try SourceDiscontinuity(
            previousEpoch: old, nextEpoch: old.successor(), reason: .explicitReset)
        try swipe?.reset(for: boundary)
        try yin?.reset(for: boundary)
        counts = SWIPEPrimeWorkloadCounts()
        checksum = 0
        probes.removeAll(keepingCapacity: true)
        try pcm.withUnsafeBufferPointer { input in
            for start in stride(from: 0, to: input.count, by: chunk) {
                let end = min(input.count, start + chunk)
                let source = try SourceInterval(
                    epoch: boundary.nextEpoch, startSample: Int64(start),
                    sampleCount: Int64(end - start),
                    sampleRate: Double(item.configuration.sampleRate))
                let slice = UnsafeBufferPointer(rebasing: input[start..<end])
                if let swipe {
                    try swipe.process(slice, interval: source, emit: consumeSWIPE)
                } else {
                    try yin!.process(slice, interval: source, emit: consumeYIN)
                }
            }
        }
        try swipe?.finish(emit: consumeSWIPE)
        try yin?.finish(emit: consumeYIN)
        return checksum
    }

    private func consume(
        timing: AnalysisTiming, index: UInt64, frequency: Double?, strength: Double?, status: String
    ) {
        if timing.source.sampleCount == support { counts.full += 1 } else { counts.partial += 1 }
        switch status {
        case "voiced": counts.voiced += 1
        case "uncertain": counts.uncertain += 1
        case "unvoiced": counts.unvoiced += 1
        case "unavailable": counts.unavailable += 1
        default: preconditionFailure("Unknown pitch status")
        }
        checksum += Double(timing.source.sampleCount) + (frequency ?? 0) + (strength ?? 0)
        if collectProbes && probeIndices.contains(index) {
            probes.append(
                SWIPEPrimeWorkloadProbe(
                    frameIndex: index, startSample: timing.source.startSample,
                    observedSamples: timing.source.sampleCount, frequencyHz: frequency,
                    strength: strength, status: status))
        }
    }

    private func consumeSWIPE(_ output: BorrowedSWIPEPrimeOutput) {
        let result = output.result
        consume(
            timing: result.timing, index: result.frameIndex,
            frequency: result.observation?.frequencyHz,
            strength: result.observation?.pitchStrength, status: result.status.rawValue)
        if item.kind == .export && !output.windows.isEmpty {
            let snapshot = try! output.exportIntermediates(
                policy: exportPolicy, kernelCandidateIndices: kernelIndices)
            counts.exportedScalarSlots +=
                snapshot.candidateFrequenciesHz.count + snapshot.erbFrequenciesHz.count
                + snapshot.candidateStrengths.count
                + snapshot.kernels.reduce(0) { $0 + $1.coefficients.count }
                + snapshot.windows.reduce(0) {
                    $0 + $1.magnitude.count + $1.loudness.count + $1.candidateIndices.count
                        + $1.candidateStrengths.count
                }
            for value in snapshot.candidateStrengths { checksum += value ?? 0 }
            let data = try! encoder.encode(snapshot)
            counts.exportedJSONBytes += data.count
        }
    }
    private func consumeYIN(_ output: BorrowedYINAnalysisOutput) {
        let result = output.raw.result
        consume(
            timing: result.timing, index: result.frameIndex,
            frequency: result.observation?.frequencyHz,
            strength: result.observation?.periodicity, status: result.status.rawValue)
        if item.kind == .export && result.timing.source.sampleCount == support {
            let snapshots = try! output.raw.export(stages: yinStages, policy: exportPolicy)
            for snapshot in snapshots {
                counts.exportedScalarSlots += snapshot.values.count
                for value in snapshot.values { checksum += value }
            }
            let data = try! encoder.encode(result.measurementResult())
            counts.exportedJSONBytes += data.count
        }
    }

    func verify() throws -> SWIPEPrimeWorkloadEvidence {
        let bytes = swipe?.preparedBufferBytes ?? yin!.preparedBufferBytes
        let first = try run()
        var firstCounts = counts
        let second = try execute(chunk: 137)
        // Epoch identifiers grow across runs; owned JSON byte length may change.
        firstCounts.exportedJSONBytes = counts.exportedJSONBytes
        precondition(first == second && first.isFinite && first > 0 && counts == firstCounts)
        collectProbes = true
        probes.reserveCapacity(probeIndices.count)
        let third = try execute(chunk: pcm.count)
        collectProbes = false
        precondition(third == first && probes.count == probeIndices.count)
        precondition(bytes == (swipe?.preparedBufferBytes ?? yin!.preparedBufferBytes))
        let full = (pcm.count - support) / hop + 1
        precondition(counts.full == full && counts.partial == (full * hop < pcm.count ? 1 : 0))
        precondition(
            counts.voiced + counts.uncertain + counts.unvoiced + counts.unavailable == counts.full
                + counts.partial)
        if item.kind == .silence { precondition(counts.unvoiced == full) }
        if item.kind == .harmonic || item.kind == .export { precondition(counts.voiced == full) }
        if item.kind != .export {
            precondition(counts.exportedScalarSlots == 0 && counts.exportedJSONBytes == 0)
        }
        let input = pcm.withUnsafeBytes { Data($0) }
        let hash = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        let layout = SWIPEPrimeLayout(configuration: item.configuration)
        return SWIPEPrimeWorkloadEvidence(
            workload: item, algorithm: algorithm,
            profileIdentity: swipe?.identity ?? yin!.identity, inputSHA256: hash,
            preparedInputBytes: input.count, preparedBufferBytes: bytes, supportSamples: support,
            hopSamples: hop,
            supportSeconds: Double(support) / Double(item.configuration.sampleRate),
            algorithmicDelaySeconds: Double(support) / Double(item.configuration.sampleRate) / 2,
            windowLengths: algorithm == .swipePrime ? layout.windowLengths : [],
            candidateCount: swipe?.estimatorStatistics?.candidateCount ?? 0,
            erbBinCount: swipe?.estimatorStatistics?.erbBinCount ?? 0,
            counts: counts, checksum: checksum, probes: probes)
    }
}
