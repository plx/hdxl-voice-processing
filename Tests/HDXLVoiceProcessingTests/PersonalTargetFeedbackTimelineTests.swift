import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func feedbackTimelineUsesInclusiveBoundsPersistenceHysteresisAndCooldown() throws {
    let clock = FeedbackTestClock()
    let configuration = try PersonalTargetFeedbackConfiguration(warmupSeconds: 0.5)
    let policy = try PersonalTargetFeedback(
        target: feedbackTestTarget(), configuration: configuration, clock: clock.now)
    let values = [10.0, 10, 10.5, 9.5, 9.49, 9, 10, 10, 10, 10]
    let states: [PersonalTargetFeedbackState] = [
        .uncertain, .onTarget, .onTarget, .onTarget, .onTarget, .departedTarget,
        .approachingTarget, .approachingTarget, .approachingTarget, .onTarget,
    ]
    var snapshots: [PersonalTargetFeedbackSnapshot] = []
    for (index, value) in values.enumerated() {
        let result = try feedbackTestUpdate(
            policy, clock, feedbackTestEvidence(index: index, value: value))
        #expect(result.state == states[index])
        #expect(result.responsibleFeature == .cpps)
        snapshots.append(result)
    }
    #expect(snapshots[0].reasons == [.warmingUp])
    #expect(snapshots[1].progress.entrySeconds == 0.5)
    #expect(snapshots[2].reasons == [.hysteresisHeld])
    #expect(snapshots[3].proximity == .withinExitMargin)
    #expect(Set(snapshots[4].reasons) == [.exitPersistence, .cooldown])
    #expect(snapshots[4].proximity == .outsideTarget)
    #expect(snapshots[5].reasons == [.targetDrift])
    #expect(snapshots[7].reasons == [.cooldown])
    #expect(snapshots[9].coverage.sourceSamples == 40_000)
    #expect(snapshots[9].coverage.matchingSummarySamples == 24_000)
    #expect(snapshots[9].coverage.qualifiedFraction == 1)
}

@Test func feedbackDuplicatesAndPollsNeverAccrueOrRefreshEvidence() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(target: feedbackTestTarget(), clock: clock.now)
    let first = try feedbackTestEvidence(index: 0)
    let initial = try feedbackTestUpdate(policy, clock, first)
    #expect(initial.state == .approachingTarget)
    clock.set(2_000_000_000)
    for _ in 0..<10 {
        #expect(try policy.update(first).progress == initial.progress)
        #expect(policy.poll().progress == initial.progress)
    }
    #expect(policy.latest.statistics.acceptedIntervals == 1)
    #expect(policy.latest.statistics.duplicateInputs == 10)
    #expect(policy.latest.evidenceAgeNanoseconds == 750_000_000)
    clock.set(3_250_000_000)
    #expect(policy.poll().reasons == [.stale])
    let relabeledClock = try feedbackTestEvidence(index: 0, end: 3_250_000_000)
    #expect(try policy.update(relabeledClock).inputDisposition == .duplicate)
    #expect(policy.latest.reasons == [.stale])
    #expect(policy.latest.progress.qualifiedSeconds == 0)
    #expect(policy.latest.evidence?.sourceEndHostNanoseconds == 1_250_000_000)
}

@Test func feedbackRejectsReversedOverlappingAndFutureEvidence() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(
        target: feedbackTestTarget(), configuration: feedbackTestConfiguration(), clock: clock.now)
    let first = try feedbackTestEvidence(index: 0)
    let second = try feedbackTestEvidence(index: 1)
    _ = try feedbackTestUpdate(policy, clock, first)
    _ = try feedbackTestUpdate(policy, clock, second)
    clock.set(1_750_000_000)
    let alteredOld = try feedbackTestEvidence(index: 0, value: 4, end: 1_750_000_000)
    #expect(try policy.update(alteredOld).inputDisposition == .outOfOrder)
    #expect(policy.latest.state == .onTarget)
    #expect(policy.latest.evidence == second.interval)
    #expect(policy.latest.coverage.sourceSamples == 8000)
    let overlap = try feedbackTestEvidence(index: 2, start: 6000, end: 1_750_000_000)
    #expect(try policy.update(overlap).inputDisposition == .outOfOrder)
    let future = try feedbackTestEvidence(index: 2, end: 2_000_000_000)
    #expect(try policy.update(future).reasons == [.invalidClock])
    #expect(policy.latest.statistics.acceptedIntervals == 2)
    clock.set(1_500_000_000)
    #expect(policy.poll().reasons == [.invalidClock])
    #expect(policy.latest.statistics.invalidClocks == 2)
}

@Test func feedbackDistinguishesDroppedAudioFromUnobservedInput() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(
        target: feedbackTestTarget(), configuration: feedbackTestConfiguration(), clock: clock.now)
    let first = try feedbackTestEvidence(index: 0)
    _ = try feedbackTestUpdate(policy, clock, first)
    let gap = try SourceInterval(
        epoch: first.interval.source.epoch, startSample: 4000, sampleCount: 4000, sampleRate: 16000)
    clock.set(1_500_000_000)
    let missing = try policy.recordGap(gap, sourceEndHostNanoseconds: clock.now())
    #expect(missing.reasons == [.droppedAudio])
    #expect(missing.evidence?.isGap == true)
    #expect(missing.coverage.missingSamples == 4000)
    #expect(missing.coverage.tags[MaskTag.missingAcquisition.rawValue] == 4000)
    #expect(missing.coverage.unobservedSamples == 0)
    _ = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 2))
    let result = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 4))
    #expect(result.reasons.contains(.missingData))
    #expect(result.coverage.sourceSamples == 20_000)
    #expect(result.coverage.selectedSamples == 12_000)
    #expect(result.coverage.missingSamples == 4000)
    #expect(result.coverage.unobservedSamples == 4000)
    #expect(result.coverage.qualifiedFraction == 0.6)
}

@Test func feedbackPartialSelectionsKeepTheFullCoverageDenominator() throws {
    let clock = FeedbackTestClock()
    let configuration = try PersonalTargetFeedbackConfiguration(
        warmupSeconds: 0, entryPersistenceSeconds: 0.25, cooldownSeconds: 0)
    let policy = try PersonalTargetFeedback(
        target: feedbackTestTarget(), configuration: configuration, clock: clock.now)
    let first = try feedbackTestUpdate(
        policy, clock, feedbackTestEvidence(index: 0, excluded: 2000))
    #expect(first.state == .approachingTarget)
    #expect(first.progress.entrySeconds == 0.125)
    let result = try feedbackTestUpdate(
        policy, clock, feedbackTestEvidence(index: 1, excluded: 2000))
    #expect(result.state == .onTarget)
    #expect(result.progress.entrySeconds == 0.25)
    #expect(result.coverage.sourceSamples == 8000)
    #expect(result.coverage.eligibleSamples == 8000)
    #expect(result.coverage.excludedEligibleSamples == 4000)
    #expect(result.coverage.matchingSummarySamples == 4000)
    #expect(result.coverage.qualifiedFraction == 0.5)
}

@Test func feedbackLargeSourceOriginsPreserveSmallEvidenceDurations() throws {
    let clock = FeedbackTestClock()
    let configuration = try PersonalTargetFeedbackConfiguration(
        warmupSeconds: 0, entryPersistenceSeconds: 0.000125, minimumObservations: 2,
        cooldownSeconds: 0)
    let policy = try PersonalTargetFeedback(
        target: feedbackTestTarget(), configuration: configuration, clock: clock.now)
    let origin: Int64 = (1 << 54) + 7
    for index in 0..<2 {
        _ = try feedbackTestUpdate(
            policy, clock,
            feedbackTestEvidence(
                index: index, start: origin + Int64(index), count: 1,
                end: 1_000_000_000 + UInt64(index + 1) * 62_500))
    }
    #expect(policy.latest.state == .onTarget)
    #expect(policy.latest.progress.entrySeconds == 0.000125)
    #expect(policy.latest.coverage.sourceSamples == 2)
}
