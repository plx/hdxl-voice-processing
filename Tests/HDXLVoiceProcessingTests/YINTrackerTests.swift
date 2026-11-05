import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func yinHandCandidate(
    _ hz: Double, error: Double, global: Bool = true,
    local: Bool = true, inRange: Bool = true
) -> YINCandidate {
    let period = 16000 / hz
    return YINCandidate(
        integerLag: Int(period.rounded()), unboundedPeriodSamples: period, periodSamples: period,
        frequencyHz: hz, normalizedError: error, periodicity: max(0, 1 - error),
        isLocalMinimum: local, isGlobalMinimum: global, isInRange: inRange,
        isThresholdQualified: local && inRange && error < 0.1, isBoundaryCanonicalized: hz == 100)
}

private func yinHandFrame(
    _ index: UInt64, epoch: StreamEpoch, profile: ProfileIdentity,
    candidates: [YINCandidate], status: YINVoicingStatus = .voiced,
    reason: UnavailabilityReason? = nil, host: UInt64? = nil,
    completed: UInt64? = nil
) throws -> YINFrameResult {
    let start = Int64(index) * 80
    let source = try SourceInterval(
        epoch: epoch, startSample: start, sampleCount: 321, sampleRate: 16000)
    let timing = try AnalysisTiming(
        source: source, includedSampleCount: 321, sourceStartSeconds: 10 + Double(start) / 16000,
        hostStartNanoseconds: host ?? (1_000_000_000 + UInt64(start) * 62500),
        completedHostNanoseconds: completed ?? (2_000_000_000 + UInt64(start) * 62500),
        effectiveDelaySeconds: 321.0 / 32000)
    let hasSelection = status == .voiced || status == .uncertain
    return YINFrameResult(
        profile: profile, frameIndex: index, timing: timing, requiredSampleCount: 321,
        status: status,
        observation: hasSelection ? candidates[0] : nil,
        selectedCandidateIndex: hasSelection ? 0 : nil,
        unavailability: reason, normalizationPeak: 0.4, rms: 0.28)
}

private func yinTrackHand(
    _ raw: YINFrameResult, candidates: [YINCandidate], tracker: PreparedYINTracker
) throws -> YINTrackedFrameResult {
    try candidates.withUnsafeBufferPointer {
        try tracker.process(
            BorrowedYINOutput(
                result: raw, candidates: $0,
                difference: UnsafeBufferPointer(start: nil, count: 0),
                cmnd: UnsafeBufferPointer(start: nil, count: 0)))
    }
}

@Test func yinTrackerHandEnumeratedChoicesPreserveRawAndResetHistory() throws {
    let c = try YINConfiguration(sampleRate: 16000, pitchFloorHz: 100, hopLength: 80)
    let profile = YINProfile(estimator: c, tracker: try YINTrackerConfiguration())
    let tracker = try PreparedYINTracker(profile)
    let epoch = StreamEpoch(streamID: UUID())
    let low = yinHandCandidate(100, error: 0.02)
    let high = yinHandCandidate(200, error: 0.01)
    let lowAlternative = yinHandCandidate(100, error: 0.02, global: false)
    let uncertain = yinHandCandidate(200, error: 0.4, local: false)
    let rows = [[low], [high, lowAlternative], [uncertain], [high, lowAlternative]]
    var results: [YINTrackedFrameResult] = []
    for (index, candidates) in rows.enumerated() {
        let raw = try yinHandFrame(
            UInt64(index), epoch: epoch, profile: c.identity(), candidates: candidates,
            status: index == 2 ? .uncertain : .voiced)
        let result = try yinTrackHand(raw, candidates: candidates, tracker: tracker)
        #expect(result.raw == raw && result.raw.selectedCandidateIndex == 0)
        results.append(result)
    }
    #expect(results.map(\.selectedCandidateIndex) == [0, 1, 0, 0])
    #expect(results.map(\.changedSelection) == [false, true, false, false])
    #expect(results.map { $0.dependencyTiming.source.startSample } == [0, 0, 160, 240])
    #expect(results.map { $0.dependencyTiming.source.sampleCount } == [321, 401, 321, 321])
    #expect(
        results[1].raw.observation?.frequencyHz == 200 && results[1].observation?.frequencyHz == 100
    )
    #expect(results[1].dependencyTiming.sourceStartSeconds == 10)
    #expect(results[1].dependencyTiming.hostStartNanoseconds == 1_000_000_000)
    #expect(
        results[1].dependencyTiming.completedHostNanoseconds
            == results[1].raw.timing.completedHostNanoseconds)
    #expect(abs(results[1].dependencyTiming.effectiveDelaySeconds - 401.0 / 32000) < 1e-15)
    let measurement = try results[1].measurementResult()
    #expect(
        measurement.timing.source.sampleCount == 401
            && measurement.timing.includedSampleCount == 401)
    #expect(measurement.outcome.estimate?.value == 100)
    #expect(
        try JSONDecoder().decode(MeasurementResult.self, from: measurement.canonicalJSON())
            == measurement)
    #expect(try results[2].measurementResult().outcome.estimate?.warnings == [.lowConfidence])
    let unavailableCandidates = [yinHandCandidate(99.5, error: 0.02, inRange: false)]
    let unavailable = try yinHandFrame(
        4, epoch: epoch, profile: c.identity(), candidates: unavailableCandidates,
        status: .unavailable, reason: .unsupportedRange)
    let unavailableResult = try yinTrackHand(
        unavailable, candidates: unavailableCandidates, tracker: tracker)
    #expect(unavailableResult.observation == nil && unavailableResult.selectedCandidateIndex == nil)
    #expect(try unavailableResult.measurementResult().outcome == .unavailable(.unsupportedRange))
    let after = try yinHandFrame(
        5, epoch: epoch, profile: c.identity(), candidates: [high, lowAlternative])
    let fresh = try yinTrackHand(after, candidates: [high, lowAlternative], tracker: tracker)
    #expect(fresh.selectedCandidateIndex == 0 && fresh.dependencyTiming.source.startSample == 400)
}

@Test func yinTrackerRejectsSkippedFramesAndBadTimingWithoutChangingHistory() throws {
    let c = try YINConfiguration(sampleRate: 16000, pitchFloorHz: 100, hopLength: 80)
    let tracker = try PreparedYINTracker(
        YINProfile(estimator: c, tracker: YINTrackerConfiguration()))
    let epoch = StreamEpoch(streamID: UUID())
    let low = yinHandCandidate(100, error: 0.02)
    let alternatives = [
        yinHandCandidate(200, error: 0.01), yinHandCandidate(100, error: 0.02, global: false),
    ]
    let first = try yinHandFrame(0, epoch: epoch, profile: c.identity(), candidates: [low])
    _ = try yinTrackHand(first, candidates: [low], tracker: tracker)
    let skipped = try yinHandFrame(2, epoch: epoch, profile: c.identity(), candidates: alternatives)
    #expect(throws: YINError.unexpectedContext) {
        try yinTrackHand(skipped, candidates: alternatives, tracker: tracker)
    }
    let badClock = try yinHandFrame(
        1, epoch: epoch, profile: c.identity(), candidates: alternatives,
        host: 500_000_000, completed: 800_000_000)
    #expect(throws: ContractError.invalidTiming) {
        try yinTrackHand(badClock, candidates: alternatives, tracker: tracker)
    }
    let second = try yinHandFrame(1, epoch: epoch, profile: c.identity(), candidates: alternatives)
    let accepted = try yinTrackHand(second, candidates: alternatives, tracker: tracker)
    #expect(
        accepted.selectedCandidateIndex == 1 && accepted.dependencyTiming.source.startSample == 0)
    let next = try epoch.successor()
    let newSource = try yinHandFrame(
        0, epoch: next, profile: c.identity(), candidates: alternatives)
    #expect(throws: YINError.unexpectedContext) {
        try yinTrackHand(newSource, candidates: alternatives, tracker: tracker)
    }
    try tracker.reset()
    let reset = try yinTrackHand(newSource, candidates: alternatives, tracker: tracker)
    #expect(reset.selectedCandidateIndex == 0 && reset.dependencyTiming.source.epoch == next)
    #expect(throws: YINError.invalidConfiguration) {
        try PreparedYINTracker(YINProfile(estimator: c))
    }
}

@Test func yinFFTFlatDifferenceFallbackHasClosedFormOutput() throws {
    let c = try YINConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let worker = try PreparedYIN<Double>(c)
    let samples = [1.0] + [Double](repeating: 0, count: 16)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 0, sampleCount: 17, sampleRate: 4000)
    try samples.withUnsafeBufferPointer {
        try worker.analyze($0, timing: AnalysisTiming(source: source, includedSampleCount: 17)) {
            output in
            #expect(
                Array(output.values(.scaledSquaredDifference)) == [0]
                    + [Double](repeating: 1, count: 9))
            #expect(
                Array(output.values(.cumulativeMeanNormalizedDifference))
                    == [Double](repeating: 1, count: 10))
            #expect(output.candidates.count == 1 && output.candidates[0].integerLag == 4)
            #expect(
                output.result.status == .uncertain && output.result.observation?.periodicity == 0)
        }
    }
    #expect(worker.executionStatistics.scalarFallbackFrameCount == 1)
}
