import Foundation

/// Complete selected-interval evidence for a fitted personal target. Construct
/// on a worker/control path; validation and hashing allocate. No PCM is retained.
/// An individual live frame is not a selected-interval median.
public struct PersonalTargetFeedbackEvidence: Sendable, Hashable {
    public let observation: PersonalTargetObservation
    public let interval: PersonalTargetFeedbackInterval

    /// The host supplies the monotonic time at the end of source support, not
    /// publication or display time. File replay uses an explicit virtual mapping.
    /// This validates metadata consistency, not the authenticity of supplied data.
    public init(
        take: CalibrationTake, analysis: CalibrationAnalysisRecord,
        sourceEndHostNanoseconds: UInt64
    ) throws {
        try validateFeedbackAnchor(take.source, end: sourceEndHostNanoseconds)
        observation = try PersonalTargetObservation(take: take, analysis: analysis)
        let mask = try MaskTimeline(take.effectiveMaskPlan())
        interval = PersonalTargetFeedbackInterval(
            source: analysis.key.source,
            analysisIdentity: CalibrationDigest(bytes: try analysis.canonicalJSON()),
            profile: observation.profile, statistic: observation.statistic,
            analysisImplementation: observation.analysisImplementation,
            sourceEndHostNanoseconds: sourceEndHostNanoseconds, coverage: analysis.coverage,
            selectedTags: Dictionary(
                uniqueKeysWithValues: mask.coverage.tags.map {
                    ($0.tag.rawValue, $0.selectedSampleCount)
                }))
    }
}

func validateFeedbackAnchor(_ source: SourceInterval, end: UInt64) throws {
    let duration = ceil(source.durationSeconds * 1_000_000_000)
    guard source.sampleCount > 0, duration.isFinite, duration >= 1,
        duration < Double(UInt64.max), UInt64(duration) <= end
    else { throw PersonalTargetFeedbackError.invalidEvidence }
}
