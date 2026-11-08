import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func feedbackRejectsIncompatibleMetricsUnitsAndInvalidControls() throws {
    for kind in [MeasurementKind.cpp, .fundamentalFrequency, .jitterLocal] {
        #expect(throws: PersonalTargetFeedbackError.incompatibleMeasurement) {
            try PersonalTargetFeedbackConfiguration(measurement: kind)
        }
    }
    for unit in [MeasurementUnit.fraction, .percent, .decibelsFullScale, .decibelsSPL] {
        #expect(throws: PersonalTargetFeedbackError.incompatibleMeasurement) {
            try PersonalTargetFeedbackConfiguration(unit: unit)
        }
    }
    for value in [Double.nan, .infinity, -1, 61] {
        #expect(throws: PersonalTargetFeedbackError.invalidConfiguration) {
            try PersonalTargetFeedbackConfiguration(entryPersistenceSeconds: value)
        }
    }
    #expect(throws: PersonalTargetFeedbackError.invalidConfiguration) {
        try PersonalTargetFeedbackConfiguration(maximumAgeSeconds: 0)
    }
    #expect(throws: PersonalTargetFeedbackError.invalidConfiguration) {
        try PersonalTargetFeedbackConfiguration(minimumObservations: 0)
    }
    #expect(throws: PersonalTargetFeedbackError.invalidConfiguration) {
        try PersonalTargetFeedbackConfiguration(exitMarginDB: .nan)
    }
}

@Test func feedbackValidZeroIsDifferentFromUnavailable() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(
        target: feedbackTestTarget(preferred: 0), configuration: feedbackTestConfiguration(),
        clock: clock.now)
    let zero = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 0, value: 0))
    #expect(zero.state == .onTarget)
    #expect(zero.values?.cppsDB == 0)
    let missing = try feedbackTestUpdate(
        policy, clock, feedbackTestEvidence(index: 1, value: 0, available: 0, unavailable: 8))
    #expect(missing.state == .unavailable)
    #expect(missing.values == nil)
    #expect(missing.reasons.contains(.unavailableMeasurements))
    #expect(missing.coverage.sourceSamples == 8000)
    #expect(missing.coverage.qualifiedSummarySamples == 4000)
}

@Test func feedbackCaptureReasonsDistinguishSilenceNoiseAndPeriodicity() throws {
    let target = try feedbackTestTarget()
    let cases: [(MaskTag, PersonalTargetFeedbackReason, PersonalTargetFeedbackState)] = [
        (.silence, .silence, .unavailable),
        (.suspectedExternalNoise, .suspectedNoise, .unavailable),
        (.clipping, .clipping, .unavailable),
        (.nonSpeechDetected, .nonSpeech, .unavailable),
        (.energyIneligible, .insufficientEnergy, .unavailable),
        (.lowPeriodicityConfidence, .lowPeriodicity, .uncertain),
        (.missingAcquisition, .droppedAudio, .unavailable),
    ]
    for (tag, reason, state) in cases {
        let clock = FeedbackTestClock()
        let policy = try PersonalTargetFeedback(
            target: target, configuration: feedbackTestConfiguration(), clock: clock.now)
        _ = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 0))
        let bad = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 1, tags: [tag]))
        #expect(bad.state == state)
        #expect(bad.reasons.contains(reason))
        #expect(bad.progress.entrySeconds == 0)
        #expect(bad.coverage.tags[tag.rawValue] == 4000)
        if tag != .silence { #expect(!bad.reasons.contains(.silence)) }
    }
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(
        target: target, configuration: feedbackTestConfiguration(), clock: clock.now)
    let conflicting = try feedbackTestUpdate(
        policy, clock,
        feedbackTestEvidence(
            index: 0, tags: [.silence, .lowPeriodicityConfidence, .suspectedExternalNoise]))
    #expect(Set(conflicting.reasons) == [.silence, .lowPeriodicity, .suspectedNoise])
    #expect(conflicting.responsibleFeature == .capture)
    #expect(conflicting.coverage.sourceSamples == 4000)
    #expect(conflicting.coverage.tags.values.reduce(0, +) >= 12_000)
}

@Test func feedbackContextGatesHaveExplicitPriorityAndNoHiddenAverage() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(
        target: feedbackTestTarget(), configuration: feedbackTestConfiguration(), clock: clock.now)
    let shifted = try feedbackTestUpdate(
        policy, clock, feedbackTestEvidence(index: 0, value: 15, pitch: 201, level: -21))
    #expect(shifted.state == .uncertain)
    #expect(
        Set(shifted.reasons) == [
            .outsideObservedPitch, .outsideObservedLevel, .outsideObservedCPPS,
        ])
    #expect(shifted.responsibleFeature == .fundamentalFrequency)
    #expect(shifted.values == nil)
    let level = try feedbackTestUpdate(
        policy, clock, feedbackTestEvidence(index: 1, value: 10, level: -21))
    #expect(level.responsibleFeature == .levelDBFS)
    #expect(level.state == .uncertain)
    let cpps = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 2, value: 15))
    #expect(cpps.responsibleFeature == .cpps)
    #expect(cpps.reasons == [.outsideObservedCPPS])
}

@Test func feedbackProfileTaskAndRouteMismatchAbstainAndClearPersistence() throws {
    let target = try feedbackTestTarget()
    let changedRoute = try CalibrationRecordingConditions(
        routeIdentifier: "different-route", roomIdentifier: "room-a", microphoneDistanceMeters: 0.2,
        inputGainDB: 0, recordingSettings: ["automaticGainControl": .boolean(false)])
    let changedTask = try CalibrationTask(
        category: .mostlyVoicedSentence, promptIdentifier: "different", prompt: "different")
    let inputs = [
        try feedbackTestEvidence(index: 1, profile: calibrationTestProfile(hop: 320)),
        try feedbackTestEvidence(index: 1, conditions: changedRoute),
        try feedbackTestEvidence(index: 1, task: changedTask),
    ]
    let reasons: [PersonalTargetFeedbackReason] = [
        .incompatibleProfile, .changedConditions, .incompatibleTask,
    ]
    for (input, reason) in zip(inputs, reasons) {
        let clock = FeedbackTestClock()
        let policy = try PersonalTargetFeedback(
            target: target, configuration: feedbackTestConfiguration(), clock: clock.now)
        _ = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: 0))
        let result = try feedbackTestUpdate(policy, clock, input)
        #expect(result.state == .unavailable)
        #expect(result.reasons.contains(reason))
        #expect(result.responsibleFeature == .context)
        #expect(result.progress.qualifiedSeconds == 0)
        #expect(result.profile == target.candidate.scope.profile)
        #expect(result.evidence?.profile == input.observation.profile)
        #expect(result.evidence?.statistic == input.observation.statistic)
        #expect(result.evidence?.analysisImplementation == input.observation.analysisImplementation)
    }
}

@Test func feedbackExpiresWithoutPollingAndDelayedDeliveryCannotAddTime() throws {
    let target = try feedbackTestTarget()
    let timelyClock = FeedbackTestClock()
    let delayedClock = FeedbackTestClock()
    let timely = try PersonalTargetFeedback(target: target, clock: timelyClock.now)
    let delayed = try PersonalTargetFeedback(target: target, clock: delayedClock.now)
    for index in 0..<4 {
        let input = try feedbackTestEvidence(index: index)
        let a = try feedbackTestUpdate(timely, timelyClock, input)
        let b = try feedbackTestUpdate(delayed, delayedClock, input, delay: 100_000_000)
        #expect(a.state == b.state)
        #expect(a.progress == b.progress)
        #expect(a.coverage == b.coverage)
        #expect(a.evidence == b.evidence)
    }
    // No timer callback occurred during the pause in evidence. A new timestamp
    // must not keep the preceding match latched across an expired interval.
    let later = try feedbackTestEvidence(index: 4, end: 5_000_000_000)
    let result = try feedbackTestUpdate(timely, timelyClock, later)
    #expect(result.state == .approachingTarget)
    #expect(result.progress.entrySeconds == 0.25)
    #expect(result.progress.entryObservations == 1)
    let old = try feedbackTestEvidence(index: 5, end: 5_250_000_000)
    timelyClock.set(7_250_000_000)
    #expect(try timely.update(old).reasons == [.stale])
    #expect(timely.latest.progress.entrySeconds == 0)
}

@Test func feedbackEvidenceRejectsImpossibleSourceAnchorsAndEmptySupport() throws {
    #expect(throws: PersonalTargetFeedbackError.invalidEvidence) {
        try feedbackTestEvidence(index: 0, end: 1)
    }
    #expect(throws: PersonalTargetFeedbackError.invalidEvidence) {
        try feedbackTestEvidence(index: 0, count: 0)
    }
}

@Test func feedbackPreservesExcludedCaptureTagsWithoutTreatingThemAsSelectedEvidence() throws {
    let clock = FeedbackTestClock()
    let policy = try PersonalTargetFeedback(
        target: feedbackTestTarget(), configuration: feedbackTestConfiguration(), clock: clock.now)
    let result = try feedbackTestUpdate(
        policy, clock,
        feedbackTestEvidence(
            index: 0, tags: [.silence, .suspectedExternalNoise], taggedSamples: 2000, excluded: 2000
        ))
    #expect(result.state == .onTarget)
    #expect(result.coverage.sourceSamples == 4000)
    #expect(result.coverage.selectedSamples == 2000)
    #expect(result.coverage.qualifiedFraction == 0.5)
    #expect(result.coverage.tags[MaskTag.silence.rawValue] == 2000)
    #expect(result.coverage.tags[MaskTag.suspectedExternalNoise.rawValue] == 2000)
    #expect(result.evidence?.selectedTags[MaskTag.silence.rawValue] == 0)
    #expect(result.evidence?.selectedTags[MaskTag.suspectedExternalNoise.rawValue] == 0)
    #expect(!result.reasons.contains(.silence))
    #expect(!result.reasons.contains(.suspectedNoise))
}

@Test func feedbackMissingMetricIdentifiesItsActualFeature() throws {
    let target = try feedbackTestTarget()
    let cases: [(ScheduledMetric, PersonalTargetFeedbackFeature)] = [
        (.cpps, .cpps), (.fundamentalFrequency, .fundamentalFrequency), (.levelDBFS, .levelDBFS),
    ]
    for (metric, feature) in cases {
        let clock = FeedbackTestClock()
        let policy = try PersonalTargetFeedback(
            target: target, configuration: feedbackTestConfiguration(), clock: clock.now)
        let result = try feedbackTestUpdate(
            policy, clock, feedbackTestEvidence(index: 0, missingMetric: metric))
        #expect(result.state == .unavailable)
        #expect(result.responsibleFeature == feature)
        #expect(result.reasons == [.unavailableMeasurements])
        #expect(!result.reasons.contains(.silence))
    }
}
