import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func feedbackPauseResumeAndResetRejectThePreviousObservation() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(target: feedbackTestTarget(), clock: clock.now)
    let first = try feedbackTestEvidence(index: 0)
    _ = try feedbackTestUpdate(policy, clock, first)
    #expect(try policy.pause().reasons == [.paused])
    clock.set(2_000_000_000)
    #expect(try policy.update(first).inputDisposition == .paused)
    #expect(try policy.resume().reasons == [.resumed])
    #expect(try policy.update(first).inputDisposition == .duplicate)
    #expect(policy.latest.progress.entrySeconds == 0)
    let fresh = try feedbackTestEvidence(index: 1, end: 2_250_000_000)
    #expect(try feedbackTestUpdate(policy, clock, fresh).state == .approachingTarget)
    #expect(try policy.reset(.routeChanged).reasons == [.routeChanged])
    #expect(try policy.update(fresh).inputDisposition == .duplicate)
    #expect(policy.latest.evidence == nil)
    #expect(policy.latest.coverage.sourceSamples == 0)
    #expect(try policy.reset(.droppedAudio).statistics.unknownLossEvents == 1)
}

@Test func feedbackEpochAndModelChangesStartNewEvidence() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(target: feedbackTestTarget(), clock: clock.now)
    let old = try feedbackTestEvidence(index: 0)
    _ = try feedbackTestUpdate(policy, clock, old)
    _ = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 1))
    #expect(policy.latest.state == .onTarget)
    let nextEpoch = StreamEpoch(streamID: old.interval.source.epoch.streamID, sequence: 1)
    let changed = try feedbackTestEvidence(index: 2, start: 0, epoch: nextEpoch)
    let result = try feedbackTestUpdate(policy, clock, changed)
    #expect(result.state == .approachingTarget)
    #expect(result.reasons.contains(.sourceDiscontinuity))
    #expect(result.coverage.sourceSamples == 4000)
    #expect(try policy.update(old).inputDisposition == .outOfOrder)
    #expect(policy.latest.coverage.epoch == nextEpoch)
    let newTarget = try feedbackTestTarget(preferred: 11)
    let replaced = try policy.replaceTarget(newTarget)
    #expect(replaced.reasons == [.modelChanged])
    #expect(try replaced.targetIdentity == newTarget.identity())
    #expect(try policy.update(changed).inputDisposition == .duplicate)
    #expect(policy.latest.progress.qualifiedSeconds == 0)
}

@Test func feedbackCancellationIsTerminalEvenWithABrokenClock() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(target: feedbackTestTarget(), clock: clock.now)
    let first = try feedbackTestEvidence(index: 0)
    _ = try feedbackTestUpdate(policy, clock, first)
    clock.set(0)
    let result = policy.finish(cancelled: true)
    #expect(Set(result.reasons) == [.cancelled, .invalidClock])
    #expect(policy.finish() == result)
    #expect(policy.poll() == result)
    #expect(throws: PersonalTargetFeedbackError.terminated) { try policy.update(first) }
    #expect(throws: PersonalTargetFeedbackError.terminated) { try policy.reset() }
}

@Test func feedbackStateTextDoesNotRequireColorOrInferHealth() {
    let descriptions = PersonalTargetFeedbackState.allCases.map(\.text)
    #expect(Set(descriptions).count == PersonalTargetFeedbackState.allCases.count)
    for text in descriptions {
        #expect(!text.isEmpty)
        for word in ["red", "green", "yellow", "health", "tension", "pressure"] {
            #expect(!text.lowercased().contains(word))
        }
    }
}

@Test func feedbackKnownLossRemainsAccountedWhilePaused() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(target: feedbackTestTarget(), clock: clock.now)
    let first = try feedbackTestEvidence(index: 0)
    _ = try feedbackTestUpdate(policy, clock, first)
    _ = try policy.pause()
    clock.set(1_750_000_000)
    let gap = try SourceInterval(
        epoch: first.interval.source.epoch, startSample: 8000, sampleCount: 4000, sampleRate: 16000)
    let paused = try policy.recordGap(gap, sourceEndHostNanoseconds: clock.now())
    #expect(Set(paused.reasons) == [.paused, .droppedAudio, .missingData])
    #expect(paused.progress.qualifiedSeconds == 0)
    #expect(paused.coverage.unobservedSamples == 4000)
    #expect(paused.coverage.missingSamples == 4000)
    #expect(paused.coverage.sourceSamples == 12_000)
    _ = try policy.resume()
    #expect(policy.latest.coverage.missingSamples == 4000)
    _ = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 3))
    #expect(policy.latest.state == .approachingTarget)
    #expect(policy.latest.coverage.missingSamples == 4000)
}
