import Foundation
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

final class FeedbackTestClock: Sendable {
    private let value = Mutex<UInt64>(0)
    func set(_ next: UInt64) { value.withLock { $0 = next } }
    func now() -> UInt64 { value.withLock { $0 } }
}

// Fabricated summaries/labels exercise policy contracts, not phonation or DSP.
func feedbackTestTarget(preferred: Double = 10) throws -> ActivatedPersonalTarget {
    let fixture = try TargetTestFixture(dataset: targetTestDataset()) { member in
        let id = Int(member.take.id.uuidString.suffix(12))!
        return try targetTestRecord(
            member.take,
            cpps: member.take.label?.preference == .preferred
                ? preferred : (id.isMultiple(of: 3) ? preferred + 4 : preferred - 6))
    }
    let fit = try fixture.fit()
    let target = try #require(fixture.evaluate(fit).activated)
    #expect(target.candidate.rule.preferredInterval.lower == preferred)
    #expect(target.candidate.rule.preferredInterval.upper == preferred)
    #expect(target.candidate.rule.observedCPPS.lower == preferred - 6)
    #expect(target.candidate.rule.observedCPPS.upper == preferred + 4)
    return target
}

func feedbackTestConfiguration() throws -> PersonalTargetFeedbackConfiguration {
    try PersonalTargetFeedbackConfiguration(
        warmupSeconds: 0, entryPersistenceSeconds: 0, exitPersistenceSeconds: 0,
        minimumObservations: 1, cooldownSeconds: 0)
}

func feedbackTestEvidence(
    index: Int, value: Double = 10, pitch: Double = 200, level: Double = -20,
    start: Int64? = nil, count: Int64 = 4000, epoch: StreamEpoch? = nil,
    end: UInt64? = nil, tags: [MaskTag] = [], taggedSamples: Int64? = nil, excluded: Int64 = 0,
    available: Int = 8, unavailable: Int = 0, warnings: [String: Int] = [:],
    missingMetric: ScheduledMetric? = nil,
    profile: AnalysisScheduleProfile? = nil, conditions: CalibrationRecordingConditions? = nil,
    task: CalibrationTask? = nil
) throws -> PersonalTargetFeedbackEvidence {
    let source = try SourceInterval(
        epoch: epoch ?? StreamEpoch(streamID: calibrationTestID(5700)),
        startSample: start ?? Int64(index) * count, sampleCount: count, sampleRate: 16000)
    let mask: MaskPlan? =
        tags.isEmpty
        ? nil
        : try MaskPlan(
            source: source,
            provenances: [
                MaskProvenance(
                    kind: .externalAnnotation,
                    identifier: VersionedIdentifier(name: "feedback-test-tags", version: 1))
            ],
            policy: MaskSelectionPolicy(selectionSources: [0]),
            observations: [
                MaskObservation(source: source, provenanceIndex: 0, selection: .selected),
                MaskObservation(
                    source: SourceInterval(
                        epoch: source.epoch, startSample: source.startSample,
                        sampleCount: taggedSamples ?? count, sampleRate: source.sampleRate),
                    provenanceIndex: 0, tags: tags),
            ])
    let exclusions: [CalibrationExclusion] =
        excluded == 0
        ? []
        : [
            try CalibrationExclusion(
                source: SourceInterval(
                    epoch: source.epoch, startSample: source.startSample,
                    sampleCount: excluded, sampleRate: source.sampleRate),
                kind: .userSelection, reason: "synthetic exclusion")
        ]
    let original = try calibrationTestTake(
        5701 + index, source: source, exclusions: exclusions, mask: mask)
    let take = try targetTestCopy(original, task: task, conditions: conditions, profile: profile)
    let originalRecord = try targetTestRecord(
        take, cpps: value, pitch: pitch, level: level, available: available,
        unavailable: unavailable, warnings: warnings)
    let record = try CalibrationAnalysisRecord(
        key: originalRecord.key, coverage: originalRecord.coverage,
        summaries: originalRecord.summaries.map { summary in
            guard summary.metric == missingMetric else { return summary }
            return try CalibrationMetricSummary(
                metric: summary.metric, values: [], unavailable: ["insufficientData": 8],
                warnings: [:])
        })
    return try PersonalTargetFeedbackEvidence(
        take: take, analysis: record,
        sourceEndHostNanoseconds: end ?? (1_000_000_000 + UInt64(index + 1) * 250_000_000))
}

func feedbackTestUpdate(
    _ policy: PersonalTargetFeedback, _ clock: FeedbackTestClock,
    _ evidence: PersonalTargetFeedbackEvidence, delay: UInt64 = 0
) throws -> PersonalTargetFeedbackSnapshot {
    clock.set(evidence.interval.sourceEndHostNanoseconds + delay)
    return try policy.update(evidence)
}
