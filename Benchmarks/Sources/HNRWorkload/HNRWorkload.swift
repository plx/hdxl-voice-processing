import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum HNROperation: String, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}
public enum HNRWorkloadKind: String, Codable, Sendable {
    case harmonic = "Harmonic"
    case lowFloor = "LowFloor"
    case amplitudeContrast = "AmplitudeContrast"
    case silence = "Silence"
    case noise = "Noise"
    case export = "OwnedDiagnostics"
}

public struct HNRCase: Encodable, Sendable {
    public let name: String
    public let kind: HNRWorkloadKind
    public let configuration: HNRConfiguration
    public let inputSampleCount: Int
    public let chunkSamples = 256
    public var shard: String {
        switch kind {
        case .harmonic: "\(configuration.method.rawValue)\(configuration.sampleRate)"
        case .lowFloor, .amplitudeContrast, .silence, .noise: "stress"
        case .export: "export"
        }
    }
    private init(
        _ kind: HNRWorkloadKind = .harmonic, method: HNRMethod, rate: Int = 48000,
        precision: AnalysisPrecision = .float64, periods: Double = 4.5, floor: Int = 75,
        hopMS: Int = 10, normalization: HNRNormalizationDefinition = .causalWindow
    ) throws {
        self.kind = kind
        let c = try HNRConfiguration(
            method: method, sampleRate: rate, inputPrecision: precision,
            pitchFloorHz: Double(floor), periodsPerWindow: periods,
            hopSeconds: Double(hopMS) / 1000,
            silenceThreshold: kind == .amplitudeContrast ? 0 : 0.1,
            normalization: normalization)
        configuration = c
        inputSampleCount =
            [.lowFloor, .amplitudeContrast].contains(kind)
            ? c.causalWindowSampleCount + 3 * (rate * hopMS / 1000)
            : [.silence, .noise].contains(kind) ? rate * 5 : rate * 2 / 5
        name =
            "\(kind.rawValue).\(method.rawValue).\(precision.rawValue).\(rate)Hz"
            + ".p\(periods).f\(floor).h\(hopMS).\(normalization == .wholeInterval ? "whole" : "causal")"
    }
    public static func matrix() throws -> [Self] {
        var result: [Self] = []
        for method in HNRMethod.allCases {
            for rate in [16000, 44100, 48000] {
                for periods in [4.5, 6.0] {
                    for floor in [60, 75] {
                        for hop in [5, 10] {
                            for precision in [AnalysisPrecision.float32, .float64] {
                                for normalization in [
                                    HNRNormalizationDefinition.wholeInterval, .causalWindow,
                                ] {
                                    result.append(
                                        try Self(
                                            method: method, rate: rate,
                                            precision: precision, periods: periods, floor: floor,
                                            hopMS: hop, normalization: normalization))
                                }
                            }
                        }
                    }
                }
            }
            for precision in [AnalysisPrecision.float32, .float64] {
                result.append(
                    try Self(
                        .lowFloor, method: method, precision: precision,
                        periods: 6, floor: 20, hopMS: 5))
                for normalization in [HNRNormalizationDefinition.wholeInterval, .causalWindow] {
                    result.append(
                        try Self(
                            .export, method: method, precision: precision,
                            normalization: normalization))
                }
            }
            for kind in [HNRWorkloadKind.silence, .noise] {
                result.append(try Self(kind, method: method, periods: 6, floor: 60, hopMS: 5))
            }
        }
        for precision in [AnalysisPrecision.float32, .float64] {
            result.append(
                try Self(
                    .amplitudeContrast, method: .forwardCrossCorrelation,
                    precision: precision))
        }
        return result
    }
    public func makeWorkload() throws -> any HNRBatch {
        if configuration.inputPrecision == .float32 { return try HNRWorkload<Float>(self) }
        return try HNRWorkload<Double>(self)
    }
}

public struct HNREvidence: Encodable {
    public let name: String
    public let workload: HNRCase
    public let profileIdentity: ProfileIdentity
    public let inputSHA256: String
    public let inputDurationSeconds: Double
    public let preparedInputBytes, preparedBufferBytes, candidateRecordStride, transformLength: Int
    public let windowSamples, maximumCandidateLag, maximumCorrelationLag,
        normalizationWindowSamples: Int
    public let nominalSupportSeconds, hopSamples: Double
    public let emittedFrames, completeFrames, partialFrames, availableFrames, finiteFrames: Int
    public let reportingLimitFrames, numericalZeroNoiseFrames, unavailableFrames: Int
    public let exportedCandidates, exportedScalars, exportedJSONBytes: Int
    public let maximumDependencyDelaySeconds, checksum: Double
    public let exportedByteChecksum: UInt64
}
public protocol HNRBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> HNREvidence
}
private struct Counts: Equatable {
    var emitted = 0, complete = 0, partial = 0, available = 0, finite = 0
    var limits = 0, unity = 0, unavailable = 0
    var candidates = 0, scalars = 0, bytes = 0
    var delay = 0.0
}
private final class HNRWorkload<S: BinaryFloatingPoint & Sendable>: HNRBatch {
    let item: HNRCase
    let pcm: [S]
    let whole: PreparedIntervalHNR<S>?
    let stream: PreparedHNRStream<S>?
    let encoder: JSONEncoder
    let transformLength: Int
    var counts = Counts()
    var checksum = 0.0
    var byteChecksum: UInt64 = 0
    private static var epoch: StreamEpoch {
        StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000039")!)
    }
    private static func timing(_ item: HNRCase) throws -> AnalysisTiming {
        let count = item.configuration.normalization == .wholeInterval ? item.inputSampleCount : 0
        return try AnalysisTiming(
            source: SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: Int64(count),
                sampleRate: Double(item.configuration.sampleRate)),
            includedSampleCount: Int64(count))
    }
    init(_ item: HNRCase) throws {
        self.item = item
        let c = item.configuration
        let timing = try Self.timing(item)
        whole =
            c.normalization == .wholeInterval
            ? try PreparedIntervalHNR(configuration: c, timing: timing) : nil
        stream =
            c.normalization == .causalWindow
            ? try PreparedHNRStream(configuration: c, origin: timing) : nil
        // This independent frame worker is destroyed before any measurement. It
        // exposes the actual transform size without retaining a duplicate workspace.
        transformLength = try PreparedHNR<S>(c).executionStatistics.transformLength
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var state: UInt32 = 39
        let hz = item.kind == .lowFloor ? c.pitchFloorHz : 120
        pcm = (0..<item.inputSampleCount).map { i in
            state = 1_664_525 &* state &+ 1_013_904_223
            let noise = (Double(state) - 2_147_483_648) / 4_294_967_296
            if item.kind == .silence { return S.zero }
            if item.kind == .noise { return S(noise) }
            let phase = 2 * Double.pi * hz * Double(i) / Double(c.sampleRate)
            if item.kind == .amplitudeContrast {
                if i == c.causalWindowSampleCount - 3 { return 1 }
                return S(1e-20 * sin(phase))
            }
            return S(0.4 * sin(phase) + 0.08 * sin(2 * phase) + 0.015 * noise)
        }
    }
    @inline(never) func prepare() throws -> AnyObject {
        let timing = try Self.timing(item)
        if item.configuration.normalization == .wholeInterval {
            return try PreparedIntervalHNR<S>(configuration: item.configuration, timing: timing)
        }
        return try PreparedHNRStream<S>(configuration: item.configuration, origin: timing)
    }
    @inline(never) func run() throws -> Double { try execute(chunk: item.chunkSamples) }
    private func execute(chunk: Int) throws -> Double {
        counts = Counts()
        checksum = 0
        byteChecksum = 0
        if let whole { try whole.reset(timing: whole.timing) }
        if let stream {
            try stream.reset(
                for: SourceDiscontinuity(
                    previousEpoch: stream.epoch, nextEpoch: stream.epoch.successor(),
                    reason: .explicitReset))
        }
        try pcm.withUnsafeBufferPointer { buffer in
            for start in stride(from: 0, to: buffer.count, by: chunk) {
                let end = min(buffer.count, start + chunk)
                let source = try SourceInterval(
                    epoch: stream?.epoch ?? whole!.source.epoch, startSample: Int64(start),
                    sampleCount: Int64(end - start),
                    sampleRate: Double(item.configuration.sampleRate))
                let part = UnsafeBufferPointer(rebasing: buffer[start..<end])
                if let whole { try whole.append(part, interval: source) }
                if let stream { try stream.process(part, interval: source) { consume($0.frame) } }
            }
        }
        if let whole { try whole.finish(emit: consume) }
        if let stream { try stream.finish { consume($0.frame) } }
        return checksum + Double(byteChecksum)
    }
    private func consume(_ output: BorrowedHNRAnalysisOutput) {
        counts.emitted += 1
        counts.delay = max(counts.delay, output.result.dependencyTiming.effectiveDelaySeconds)
        switch output {
        case .unavailable(let raw):
            counts.partial += 1
            counts.unavailable += 1
            checksum += Double(raw.timing.source.sampleCount)
        case .frame(let output):
            counts.complete += 1
            let raw = output.result
            checksum += Double(raw.frameTiming.source.sampleCount + Int64(output.candidates.count))
            if let observation = raw.selectedObservation {
                counts.available += 1
                counts.finite += observation.finiteDecibels == nil ? 0 : 1
                counts.limits += observation.status == .finite ? 0 : 1
                counts.unity += observation.status == .numericalZeroNoise ? 1 : 0
                checksum += observation.periodicity + observation.referenceReportingDecibels
            } else {
                counts.unavailable += 1
            }
            if item.kind == .export {
                let candidates = try! output.exportCandidates(
                    maximumCount: item.configuration.maximumCandidateLag)
                counts.candidates += candidates.count
                for candidate in candidates { checksum += Double(candidate.integerLag) }
                // Explicit owning copies are the export allocation boundary.
                for values in [
                    Array(output.scaledWindowedSamples), Array(output.correlation),
                    Array(output.windowCorrelation), Array(output.signalCorrelation),
                ] {
                    counts.scalars += values.count
                    for value in values { checksum += value }
                }
            }
        }
        if item.kind == .export {
            let data = try! encoder.encode(output.result.measurementResult())
            counts.bytes += data.count
            for byte in data { byteChecksum &+= UInt64(byte) }
        }
    }
    func verify() throws -> HNREvidence {
        let first = try run()
        let firstChecksum = checksum
        var previous = counts
        let second = try execute(chunk: 137)
        // Only stream epoch digits may affect serialized length/bytes across resets.
        previous.bytes = counts.bytes
        precondition(first.isFinite && second.isFinite && checksum > 0)
        precondition(firstChecksum == checksum && previous == counts)
        if item.kind != .export { precondition(first == second && byteChecksum == 0) }
        if item.kind == .amplitudeContrast {
            precondition(stream!.estimatorStatistics!.directlyRecomputedEnergyLagCount > 0)
        }
        let c = item.configuration
        let complete: Int
        if c.normalization == .wholeInterval {
            complete = try HNRIntervalLayout(configuration: c, sampleCount: pcm.count).frameCount
            precondition(counts.partial == 0)
        } else {
            var start = 0
            var count = 0
            let step = c.hopSeconds * Double(c.sampleRate)
            while start + c.causalWindowSampleCount <= pcm.count {
                count += 1
                // Matrix hops are exactly integral or half-integral in binary64.
                start = Int(floor(Double(count) * step))
            }
            complete = count
            precondition(counts.partial == (start < pcm.count ? 1 : 0))
        }
        precondition(counts.complete == complete && counts.emitted == complete + counts.partial)
        precondition(counts.available + counts.unavailable == counts.emitted)
        precondition(counts.finite + counts.unity == counts.available)
        if item.kind == .silence { precondition(counts.available == 0) }
        if [.harmonic, .export].contains(item.kind) {
            precondition(counts.available == complete)
        }
        // A noisy source exactly at the floor may move the refined peak beyond
        // the bounded search. LowFloor records its actual availability; it measures
        // worst support even when a particular frame has no eligible candidate.
        let bytes = pcm.withUnsafeBytes { Data($0) }
        return HNREvidence(
            name: item.name, workload: item, profileIdentity: try c.identity(),
            inputSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            inputDurationSeconds: Double(pcm.count) / Double(c.sampleRate),
            preparedInputBytes: bytes.count,
            preparedBufferBytes: whole?.preparedBufferBytes ?? stream!.preparedBufferBytes,
            candidateRecordStride: MemoryLayout<HNRPeakCandidate>.stride,
            transformLength: transformLength,
            windowSamples: c.windowSampleCount, maximumCandidateLag: c.maximumCandidateLag,
            maximumCorrelationLag: c.maximumCorrelationLag,
            normalizationWindowSamples: c.normalization == .wholeInterval
                ? pcm.count : c.causalWindowSampleCount,
            nominalSupportSeconds: c.nominalSupportSeconds,
            hopSamples: c.hopSeconds * Double(c.sampleRate),
            emittedFrames: counts.emitted, completeFrames: counts.complete,
            partialFrames: counts.partial,
            availableFrames: counts.available, finiteFrames: counts.finite,
            reportingLimitFrames: counts.limits, numericalZeroNoiseFrames: counts.unity,
            unavailableFrames: counts.unavailable, exportedCandidates: counts.candidates,
            exportedScalars: counts.scalars, exportedJSONBytes: counts.bytes,
            maximumDependencyDelaySeconds: counts.delay, checksum: checksum,
            exportedByteChecksum: byteChecksum)
    }
}
