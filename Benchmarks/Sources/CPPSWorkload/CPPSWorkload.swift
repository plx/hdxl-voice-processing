import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum CPPSOperation: String, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}
public enum CPPSWorkloadKind: String, Codable, Sendable {
    case preview = "PreviewCPPS"
    case interval = "IntervalCPPS"
    case export = "OwnedDiagnostics"
}

public struct CPPSCase: Encodable, Sendable {
    public let name: String
    public let shard: String
    public let kind: CPPSWorkloadKind
    public let profile: CPPSProfile
    public let profileIdentity: ProfileIdentity
    public let statistic: CPPSStatisticProfile
    public let statisticIdentity: ProfileIdentity
    public let inputSampleCount: Int
    public let inputChunkSamples = 256
    public let inputDurationSeconds = 6

    private init(
        kind: CPPSWorkloadKind = .preview, precision: AnalysisPrecision = .float64,
        rate: Int = 16_000, hop: Int = 10, time: Int = 10, quefrency: Int = 1,
        window: Int = 3, pretrend: Bool = false, primary: Bool = false
    ) throws {
        self.kind = kind
        profile = try CPPSProfile(
            cepstrogram: CepstrogramConfiguration(
                sourceSampleRate: rate, inputPrecision: precision,
                hopSeconds: Double(hop) / 1000, declaredInputBandwidthHz: Double(rate) / 2,
                conditioningMethod: kind == .interval
                    ? .praat7WholeInterval(interpolationDepth: 50)
                    : .streamingPreview(lobes: 16, cutoffFraction: 0.9)),
            settings: CPPSConfiguration(
                timeWindowSeconds: Double(time) / 1000,
                quefrencyWindowSeconds: Double(quefrency) / 1000,
                subtractTrendBeforeSmoothing: pretrend, prominence: .murtonRecipePraat7()))
        profileIdentity = try profile.identity()
        statistic = try CPPSStatisticProfile(
            measurement: profile, population: .allEligible, selection: MaskSelectionPolicy(),
            provenances: [], aggregation: .rollingFrameMean, rollingWindowSeconds: Double(window))
        statisticIdentity = try statistic.identity()
        inputSampleCount = 6 * rate
        name =
            "\(kind.rawValue).\(precision.rawValue).\(rate)Hz.6s.h\(hop).t\(time).q\(quefrency).w\(window).pre\(pretrend ? 1 : 0)"
        shard = primary ? "h\(hop)-w\(window)" : "variants"
    }

    public static func matrix() throws -> [Self] {
        var rows: [Self] = []
        for hop in [2, 5, 10, 30] {
            for time in [10, 20, 50] {
                for quefrency in [1, 5] {
                    for window in [1, 3, 5] {
                        rows.append(
                            try Self(
                                hop: hop, time: time, quefrency: quefrency,
                                window: window, primary: true))
                    }
                }
            }
        }
        for (precision, rate) in [
            (AnalysisPrecision.float32, 16_000), (.float32, 48_000), (.float64, 48_000),
        ] {
            for window in [1, 5] {
                rows.append(try Self(precision: precision, rate: rate, time: 20, window: window))
            }
        }
        for precision in [AnalysisPrecision.float32, .float64] {
            for rate in [16_000, 48_000] {
                rows.append(try Self(kind: .interval, precision: precision, rate: rate, hop: 2))
            }
        }
        for window in [2, 4] { rows.append(try Self(time: 20, window: window)) }
        rows.append(try Self(pretrend: true))
        rows.append(try Self(kind: .export))
        rows.append(try Self(kind: .export, pretrend: true))
        return rows
    }
    public func makeWorkload() throws -> any CPPSBatch {
        if profile.cepstrogram.inputPrecision == .float32 { return try CPPSWorkload<Float>(self) }
        return try CPPSWorkload<Double>(self)
    }
}

public struct CPPSEvidence: Encodable, Sendable {
    public let name: String
    public let workload: CPPSCase
    public let inputSHA256: String
    public let preparedInputBytes, preparedScalarBytes, smoothingScalarBytes: Int
    public let smoothingRecordBytes, rollingRecordBytes: Int
    public let smoothingFrameCapacity, rollingFrameCapacity: Int
    public let fitPointCount, slopeEvaluationsPerFit: Int
    public let smoothingLookaheadFrames: Int
    public let smoothingLookaheadSeconds: Double
    public let maximumReportedDelaySeconds: Double
    public let verificationChunkSamples: Int
    public let verificationMaximumReportedDelaySeconds: Double
    public let emittedFrameCount, availableFrameCount, unavailableFrameCount: Int
    public let rollingAvailableQueryCount, maximumContributingFrameCount, exportedScalarCount: Int
    public let checksum: Double
}
public protocol CPPSBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> CPPSEvidence
}

private final class CPPSPrepared<S: BinaryFloatingPoint & Sendable> {
    let interval: PreparedIntervalCPPS<S>?
    let preview: PreparedPreviewCPPS<S>?
    let rolling: PreparedRollingCPPS
    // Two independent source IDs let replay exercise the actual new-source reset
    // without allocating a fresh immutable mask during measured processing.
    let masks: [MaskTimeline]
    var layout: CPPSLayout { interval?.layout ?? preview!.layout }
    var scalarBytes: Int { interval?.scalarWorkspaceBytes ?? preview!.scalarWorkspaceBytes }
    var smoothingBytes: Int {
        interval?.smoothingScalarWorkspaceBytes ?? preview!.smoothingScalarWorkspaceBytes
    }
    var recordBytes: Int {
        interval?.smoothingRecordWorkspaceBytes ?? preview!.smoothingRecordWorkspaceBytes
    }
    init(_ item: CPPSCase) throws {
        let ids = ["00000000-0000-0000-0000-000000000137", "00000000-0000-0000-0000-000000010137"]
        masks = try ids.map {
            try MaskTimeline(
                MaskPlan(
                    source: SourceInterval(
                        epoch: StreamEpoch(streamID: UUID(uuidString: $0)!),
                        startSample: 0, sampleCount: Int64(item.inputSampleCount),
                        sampleRate: Double(item.profile.cepstrogram.conditioning.sourceSampleRate)),
                    provenances: [], policy: item.statistic.selection, observations: []))
        }
        let source = masks[0].plan.source
        interval =
            item.kind == .interval
            ? try PreparedIntervalCPPS(profile: item.profile, source: source) : nil
        preview =
            item.kind != .interval
            ? try PreparedPreviewCPPS(profile: item.profile, epoch: source.epoch) : nil
        rolling = try PreparedRollingCPPS(
            profile: item.statistic,
            origin: SourceInterval(
                epoch: source.epoch, startSample: 0, sampleCount: 0, sampleRate: source.sampleRate))
    }
}

private final class CPPSWorkload<S: BinaryFloatingPoint & Sendable>: CPPSBatch {
    let item: CPPSCase
    let prepared: CPPSPrepared<S>
    let pcm: [S]
    let exportStages = Set(CPPSIntermediate.allCases)
    let exportPolicy: IntermediateOutputPolicy
    var sourceIndex = 0
    var emitted = 0, available = 0, unavailable = 0, rollingAvailable = 0
    var maximumContributing = 0, exportedScalars = 0
    var maximumDelay = 0.0, checksum = 0.0
    var lastRolling: CPPSRollingResult?
    var completion: CPPSCompletion?

    init(_ item: CPPSCase) throws {
        self.item = item
        prepared = try CPPSPrepared(item)
        exportPolicy = try IntermediateOutputPolicy(
            maximumScalarCount: 7 * item.profile.cepstrogram.frame.binCount)
        var state: UInt32 = 37
        pcm = (0..<item.inputSampleCount).map { i in
            state = 1_664_525 &* state &+ 1_013_904_223
            let noise = (Double(state) - 2_147_483_648) / 42_949_672_960
            let phase =
                2 * Double.pi * 125 * Double(i)
                / Double(item.profile.cepstrogram.conditioning.sourceSampleRate)
            return S(0.2 * sin(phase) + 0.1 * sin(2 * phase + 0.13) + noise)
        }
    }
    @inline(never) func prepare() throws -> AnyObject { try CPPSPrepared<S>(item) }
    @inline(never) func run() throws -> Double { try execute(chunk: item.inputChunkSamples) }
    private func execute(chunk: Int) throws -> Double {
        emitted = 0
        available = 0
        unavailable = 0
        rollingAvailable = 0
        maximumContributing = 0
        exportedScalars = 0
        maximumDelay = 0
        checksum = 0
        lastRolling = nil
        completion = nil
        let previous = prepared.masks[sourceIndex].plan.source.epoch
        sourceIndex = 1 - sourceIndex
        let source = prepared.masks[sourceIndex].plan.source
        try prepared.interval?.reset(source: source)
        try prepared.preview?.reset(
            for: SourceDiscontinuity(
                previousEpoch: previous, nextEpoch: source.epoch, reason: .newSource))
        try prepared.rolling.reset(
            origin: SourceInterval(
                epoch: source.epoch, startSample: 0, sampleCount: 0, sampleRate: source.sampleRate))
        try pcm.withUnsafeBufferPointer { samples in
            for start in stride(from: 0, to: samples.count, by: chunk) {
                let end = min(start + chunk, samples.count)
                let segment = try SourceInterval(
                    epoch: source.epoch, startSample: Int64(start), sampleCount: Int64(end - start),
                    sampleRate: source.sampleRate)
                let buffer = UnsafeBufferPointer(rebasing: samples[start..<end])
                try prepared.interval?.append(buffer, interval: segment)
                try prepared.preview?.process(buffer, interval: segment) { consume($0) }
            }
        }
        if let interval = prepared.interval { completion = try interval.finish { consume($0) } }
        if let preview = prepared.preview { completion = try preview.finish { consume($0) } }
        return checksum
    }
    private func consume(_ output: BorrowedCPPSOutput) {
        let frame = output.result
        emitted += 1
        maximumDelay = max(maximumDelay, frame.context.timing.effectiveDelaySeconds)
        if let observation = frame.observation {
            available += 1
            checksum +=
                observation.prominenceDB + observation.peakDB * 0.1
                + observation.backgroundDB * 0.01 + observation.peakQuefrencySeconds
                + observation.slopeDBPerSecond * 0.001 + observation.interceptDB * 0.01
                + observation.residualMeanDB * 0.01 + observation.residualRMSDB * 0.01
                + observation.residualMedianDB * 0.01 + observation.residualMaximumAbsoluteDB * 0.01
        } else {
            unavailable += 1
        }
        if let raw = frame.rawCPP.observation { checksum += raw.prominenceDB * 0.1 }
        try! prepared.rolling.append(frame)
        let center = Int64(
            floor(frame.context.centerSecondsFromOrigin * frame.context.origin.sampleRate))
        let clock = max(frame.context.timing.source.endSample, center + 1)
        let rolling = try! prepared.rolling.result(
            atSourceSample: clock, mask: prepared.masks[sourceIndex])
        lastRolling = rolling
        if let mean = rolling.meanDB {
            rollingAvailable += 1
            checksum += mean * 0.01
        }
        maximumContributing = max(maximumContributing, rolling.contributingFrameCount)
        checksum += Double(rolling.observedSampleCountInWindow) * 1e-12
        if item.kind == .export {
            for snapshot in try! output.export(stages: exportStages, policy: exportPolicy) {
                for value in snapshot.values {
                    checksum += value * 1e-12
                    exportedScalars += 1
                }
            }
            checksum += try! frame.measurementResult().timing.source.durationSeconds * 1e-12
            checksum += try! rolling.measurementResult().timing.source.durationSeconds * 1e-12
        }
    }
    func verify() throws -> CPPSEvidence {
        let first = try run()
        let counts = [
            emitted, available, unavailable, rollingAvailable, maximumContributing, exportedScalars,
        ]
        let delay = maximumDelay
        let second = try execute(chunk: 63)
        guard first == second, first.isFinite, first != 0 else {
            throw WorkloadFailure.invariant("chunk checksums \(first) vs \(second)")
        }
        guard
            counts == [
                emitted, available, unavailable, rollingAvailable, maximumContributing,
                exportedScalars,
            ]
        else {
            throw WorkloadFailure.invariant(
                "chunk coverage/delay \(counts) vs \([emitted, available, unavailable, rollingAvailable, maximumContributing, exportedScalars]); \(delay) vs \(maximumDelay)"
            )
        }
        let config = item.profile.cepstrogram
        let complete: Int
        let tail: Int
        if item.kind == .interval {
            complete = try IntervalCepstrogramLayout(
                configuration: config, inputSampleCount: item.inputSampleCount
            ).frameCount
            tail = 0
        } else {
            complete = (60_000 - config.frame.frameLength) / config.previewHopLength! + 1
            tail = 1
        }
        guard emitted == complete + tail, available == complete, unavailable == tail else {
            throw WorkloadFailure.invariant(
                "frame counts \([emitted, available, unavailable]) vs \([complete + tail, complete, tail])"
            )
        }
        guard completion!.frameCount == emitted, completion!.availableFrameCount == available,
            (completion!.meanDB != nil) == (tail == 0)
        else {
            throw WorkloadFailure.invariant("completion \(String(describing: completion))")
        }
        guard rollingAvailable > 0, maximumContributing <= prepared.rolling.frameCapacity,
            (lastRolling!.meanDB != nil) == (tail == 0)
        else {
            throw WorkloadFailure.invariant(
                "rolling \(rollingAvailable), \(maximumContributing), \(String(describing: lastRolling))"
            )
        }
        guard exportedScalars == (item.kind == .export ? complete * 7 * config.frame.binCount : 0)
        else {
            throw WorkloadFailure.invariant("export count \(exportedScalars)")
        }
        let data = pcm.withUnsafeBytes { Data($0) }
        return CPPSEvidence(
            name: item.name, workload: item,
            inputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            preparedInputBytes: data.count, preparedScalarBytes: prepared.scalarBytes,
            smoothingScalarBytes: prepared.smoothingBytes,
            smoothingRecordBytes: prepared.recordBytes,
            rollingRecordBytes: prepared.rolling.recordWorkspaceBytes,
            smoothingFrameCapacity: prepared.layout.ringFrameCapacity,
            rollingFrameCapacity: prepared.rolling.frameCapacity,
            fitPointCount: prepared.layout.prominence.fitPointCount,
            slopeEvaluationsPerFit: prepared.layout.prominence.slopeEvaluationCount,
            smoothingLookaheadFrames: prepared.layout.lookaheadFrames,
            smoothingLookaheadSeconds: prepared.layout.lookaheadSeconds,
            maximumReportedDelaySeconds: delay, verificationChunkSamples: 63,
            verificationMaximumReportedDelaySeconds: maximumDelay, emittedFrameCount: emitted,
            availableFrameCount: available, unavailableFrameCount: unavailable,
            rollingAvailableQueryCount: rollingAvailable,
            maximumContributingFrameCount: maximumContributing,
            exportedScalarCount: exportedScalars, checksum: checksum)
    }
}

private enum WorkloadFailure: Error { case invariant(String) }
