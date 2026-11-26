import Foundation
import HDXLVoiceProcessing

public enum CPPSPhase: String, CaseIterable {
    case coldSetup, firstOutput, warmHop, warmPowerCepstrogram, warmFromPower, warmAggregation

    public var measurementBoundary: String {
        switch self {
        case .coldSetup:
            "Construct and retain the preview CPPS worker and observe its scalar workspace size."
        case .firstOutput:
            "Process the shortest source prefix that emits a valid CPPS frame on a prepared worker."
        case .warmHop:
            "Feed one PCM hop to the warmed CPPS worker and consume its next public result."
        case .warmPowerCepstrogram:
            "Feed one PCM hop to the warmed cepstrogram and read its next power row."
        case .warmFromPower:
            "Append one precomputed power row to the warmed CPPS smoother and consume the result."
        case .warmAggregation:
            "Append one CPPS frame and query the mean of the warmed rolling history."
        }
    }
}

public struct CPPSPhaseEvidence: Encodable {
    public let phase: String
    public let sourceSamplesBeforeTimer, sourceSamplesInsideTimer, inputPowerRowsInsideTimer: Int
    public let measuredOutputs: SuiteLane
    public let preparedScalarBytes, preparedRecordBytes: Int?
    public let inputFramesBeforeAggregation: Int
}

private struct PowerRow {
    let context: CepstralFrameContext
    let profile: ProfileIdentity
    let bins: [Double]
}

/// Each governed phase emits one scalar. Keep the timed observation in fixed storage, then
/// construct the public status and fingerprint report after stopping the measurement.
private struct PhaseObservation {
    var count = 0
    var value: Double?
    var index: Int64 = 0
    var reason: UnavailabilityReason?

    mutating func record(_ value: Double?, at index: Int64, reason: UnavailabilityReason? = nil) {
        count += 1
        self.value = value
        self.index = index
        self.reason = reason
    }

    mutating func record(_ frame: CPPSFrameResult) {
        record(
            frame.observation?.prominenceDB, at: Int64(frame.context.frameIndex),
            reason: frame.unavailability)
    }
}

/// Every phase uses the same half-second governed PCM and the same numerical settings. The
/// warm split is chosen by observing actual complete outputs from the public preview worker.
public final class CPPSPhaseTrial {
    public static let fixtureName = "filtered-harmonics"
    public let phase: CPPSPhase
    public let item: SuiteFixture
    public let recipe: SuiteRecipe
    private let pcm: [Double]
    private let source, origin: SourceInterval
    private let hop: Int
    private let profile: CPPSProfile
    private let mask: MaskTimeline
    private var frames: [CPPSFrameResult] = []
    private var powers: [PowerRow] = []
    private var firstEnd = 0
    private var warmEnd = 0
    private var warmFrame = 0
    private var warmRow = 0
    private var expected = SuiteLane()
    private var observation = PhaseObservation()
    private var expectedBytes = 0
    private var preview: PreparedPreviewCPPS<Double>?
    private var cepstrogram: PreparedPreviewCepstrogram<Double>?
    private var smoother: PreparedCPPS?
    private var rolling: PreparedRollingCPPS?

    public init(item: SuiteFixture, directory: URL, phase: CPPSPhase) throws {
        guard item.name == Self.fixtureName,
            let input = try item.loadInput(in: directory, composition: .cpps)
                as? TypedSuiteInput<Double>
        else { throw SuiteError.invalidInput("CPPS phase fixture") }
        self.item = item
        self.phase = phase
        pcm = input.samples
        recipe = input.recipe
        profile = input.recipe.schedule.cpps!
        hop = item.sampleRate / 100
        let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000055")!)
        source = try .init(
            epoch: epoch, startSample: 0, sampleCount: Int64(pcm.count),
            sampleRate: Double(item.sampleRate))
        origin = try .init(
            epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: Double(item.sampleRate))
        mask = try MaskTimeline(
            MaskPlan(
                source: source, provenances: [], policy: recipe.rollingCPPS.selection,
                observations: []))
        try calibrate()
    }

    private func interval(_ range: Range<Int>) throws -> SourceInterval {
        try .init(
            epoch: origin.epoch, startSample: Int64(range.lowerBound),
            sampleCount: Int64(range.count), sampleRate: source.sampleRate)
    }
    private func note(_ frame: CPPSFrameResult, in lane: inout SuiteLane) {
        lane.record(
            frame.observation?.prominenceDB, at: Int64(frame.context.frameIndex),
            reason: frame.unavailability)
    }

    private func calibrate() throws {
        let direct = try PreparedPreviewCPPS<Double>(profile: profile, epoch: origin.epoch)
        let upstream = try PreparedPreviewCepstrogram<Double>(
            configuration: profile.cepstrogram, epoch: origin.epoch)
        expectedBytes = direct.scalarWorkspaceBytes
        // Locate the first available frame at a single-sample boundary independently of the warm hop grid.
        let firstWorker = try PreparedPreviewCPPS<Double>(profile: profile, epoch: origin.epoch)
        var prefix = SuiteLane()
        for start in pcm.indices {
            try withPCM(start..<(start + 1)) { buffer, span in
                _ = try firstWorker.process(buffer, interval: span) { note($0.result, in: &prefix) }
            }
            if prefix.available > 0 {
                firstEnd = start + 1
                break
            }
        }
        try pcm.withUnsafeBufferPointer { input in
            for start in stride(from: 0, through: pcm.count - hop, by: hop) {
                let end = start + hop
                let part = UnsafeBufferPointer(rebasing: input[start..<end])
                let span = try interval(start..<end)
                let priorFrames = frames.count
                let priorPowers = powers.count
                _ = try upstream.process(part, interval: span) { row in
                    powers.append(
                        PowerRow(
                            context: row.context, profile: row.profile,
                            bins: Array(row.stage(.powerCepstrum).values)))
                }
                _ = try direct.process(part, interval: span) { frames.append($0.result) }
                if firstEnd > 0, end >= firstEnd + 4 * hop,
                    frames.count == priorFrames + 1, powers.count == priorPowers + 1,
                    frames.last?.observation != nil, !(powers.last?.bins.isEmpty ?? true)
                {
                    warmEnd = end
                    warmFrame = priorFrames
                    warmRow = priorPowers
                    break
                }
            }
        }
        guard warmEnd > firstEnd, firstEnd > 0, prefix.available > 0 else {
            throw SuiteError.mismatch("No valid cold and warm output for phase fixture")
        }
        switch phase {
        case .coldSetup: expected.record(Double(expectedBytes), at: 0)
        case .firstOutput: expected = prefix
        case .warmHop, .warmFromPower: note(frames[warmFrame], in: &expected)
        case .warmPowerCepstrogram:
            expected.record(
                powers[warmRow].bins.first, at: Int64(powers[warmRow].context.frameIndex))
        case .warmAggregation:
            let values = frames[...warmFrame].compactMap { $0.observation?.prominenceDB }
            expected.record(values.reduce(0, +) / Double(values.count), at: Int64(warmFrame))
        }
    }

    public func prepareIteration() throws {
        observation = PhaseObservation()
        preview = nil
        switch phase {
        case .coldSetup: break
        case .firstOutput, .warmHop:
            let worker = try PreparedPreviewCPPS<Double>(profile: profile, epoch: origin.epoch)
            preview = worker
            if phase == .warmHop {
                try withPCM(0..<(warmEnd - hop)) {
                    _ = try worker.process($0, interval: $1) { _ in }
                }
            }
        case .warmPowerCepstrogram:
            let worker = try PreparedPreviewCepstrogram<Double>(
                configuration: profile.cepstrogram, epoch: origin.epoch)
            cepstrogram = worker
            try withPCM(0..<(warmEnd - hop)) { _ = try worker.process($0, interval: $1) { _ in } }
        case .warmFromPower:
            let worker = try PreparedCPPS(profile: profile, origin: origin)
            smoother = worker
            for i in 0..<warmRow { try appendPower(i, worker: worker) { _ in } }
        case .warmAggregation:
            let worker = try PreparedRollingCPPS(profile: recipe.rollingCPPS, origin: origin)
            rolling = worker
            for i in 0..<warmFrame { _ = try aggregate(i, worker: worker) }
        }
    }

    private func withPCM(
        _ range: Range<Int>,
        _ work: (UnsafeBufferPointer<Double>, SourceInterval) throws -> Void
    ) throws {
        let span = try interval(range)
        try pcm.withUnsafeBufferPointer { try work(UnsafeBufferPointer(rebasing: $0[range]), span) }
    }
    private func appendPower(_ i: Int, worker: PreparedCPPS, emit: (BorrowedCPPSOutput) -> Void)
        throws
    {
        let row = powers[i]
        try row.bins.withUnsafeBufferPointer {
            try worker.appendPowerCepstrum(
                $0, context: row.context, sourceProfile: row.profile, emit: emit)
        }
    }
    private func aggregate(_ i: Int, worker: PreparedRollingCPPS) throws -> Double? {
        let frame = frames[i]
        try worker.append(frame)
        let clock = max(
            frame.context.timing.source.endSample,
            Int64(floor(frame.context.centerSecondsFromOrigin * source.sampleRate)) + 1)
        return try worker.result(atSourceSample: clock, mask: mask).meanDB
    }

    @inline(never) public func measure() throws -> UInt64 {
        switch phase {
        case .coldSetup:
            preview = try PreparedPreviewCPPS<Double>(profile: profile, epoch: origin.epoch)
            observation.record(Double(preview!.scalarWorkspaceBytes), at: 0)
        case .firstOutput, .warmHop:
            let range = phase == .firstOutput ? 0..<firstEnd : (warmEnd - hop)..<warmEnd
            try withPCM(range) { buffer, span in
                _ = try preview!.process(buffer, interval: span) { observation.record($0.result) }
            }
        case .warmPowerCepstrogram:
            try withPCM((warmEnd - hop)..<warmEnd) { buffer, span in
                _ = try cepstrogram!.process(buffer, interval: span) {
                    observation.record(
                        $0.stage(.powerCepstrum).values.first, at: Int64($0.context.frameIndex))
                }
            }
        case .warmFromPower:
            try appendPower(warmRow, worker: smoother!) { observation.record($0.result) }
        case .warmAggregation:
            let mean = try aggregate(warmFrame, worker: rolling!)
            observation.record(mean, at: Int64(warmFrame))
        }
        return observation.value?.bitPattern ?? UInt64.max
    }

    public func check() throws -> CPPSPhaseEvidence {
        guard observation.count == 1 else {
            throw SuiteError.mismatch("Expected one phase observation")
        }
        var observed = SuiteLane()
        observed.record(observation.value, at: observation.index, reason: observation.reason)
        if phase == .warmAggregation {
            guard observed.available == 1, observed.unavailable == 0,
                abs(observed.sum - expected.sum) <= 1e-12
            else { throw SuiteError.mismatch(phase.rawValue) }
        } else if observed != expected {
            throw SuiteError.mismatch(phase.rawValue)
        }
        let prefix = phase == .warmHop || phase == .warmPowerCepstrogram ? warmEnd - hop : 0
        let length = phase == .firstOutput ? firstEnd : (prefix > 0 ? hop : 0)
        return CPPSPhaseEvidence(
            phase: phase.rawValue, sourceSamplesBeforeTimer: prefix,
            sourceSamplesInsideTimer: length,
            inputPowerRowsInsideTimer: phase == .warmFromPower ? 1 : 0,
            measuredOutputs: observed,
            preparedScalarBytes: preview?.scalarWorkspaceBytes ?? cepstrogram?.scalarWorkspaceBytes
                ?? smoother?.scalarWorkspaceBytes,
            preparedRecordBytes: preview?.smoothingRecordWorkspaceBytes ?? smoother?
                .recordWorkspaceBytes ?? rolling?.recordWorkspaceBytes,
            inputFramesBeforeAggregation: phase == .warmAggregation ? warmFrame : 0)
    }
}
