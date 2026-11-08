struct FeedbackFindings {
    let reasons: [PersonalTargetFeedbackReason]
    let feature: PersonalTargetFeedbackFeature?
    let uncertain: Bool
}

/// Explicit priority: model/context, capture, coverage/availability, pitch,
/// recording level, then CPPS support. Retain all findings, not just the winner.
func feedbackFindings(
    _ observation: PersonalTargetObservation, prediction: PersonalTargetPrediction,
    policy: PersonalTargetPolicy, selectedTags: [String: Int64]
) -> FeedbackFindings {
    var entries: [(PersonalTargetFeedbackReason, PersonalTargetFeedbackFeature, Bool)] = []
    let model = Set(prediction.reasons)
    func add(
        _ condition: Bool, _ reason: PersonalTargetFeedbackReason,
        _ feature: PersonalTargetFeedbackFeature, uncertain: Bool = false
    ) {
        if condition { entries.append((reason, feature, uncertain)) }
    }
    add(model.contains(.differentProfile), .incompatibleProfile, .context)
    add(model.contains(.incompatibleObservationSemantics), .incompatibleStatistic, .context)
    add(model.contains(.differentTask), .incompatibleTask, .context)
    add(
        !model.isDisjoint(with: [.changedConditions, .unknownConditions]), .changedConditions,
        .context)
    let summaries = [observation.cpps, observation.pitch, observation.level]
    func tagged(_ tag: MaskTag) -> Bool { selectedTags[tag.rawValue, default: 0] > 0 }
    func unavailable(_ reason: UnavailabilityReason) -> Bool {
        summaries.contains { $0.unavailable[reason.rawValue, default: 0] > 0 }
    }
    func warned(_ warning: MeasurementWarning) -> Bool {
        summaries.contains { $0.warnings[warning.rawValue, default: 0] > 0 }
    }
    add(observation.coverage.missing > 0, .droppedAudio, .capture)
    add(tagged(.silence) || unavailable(.silence), .silence, .capture)
    add(tagged(.suspectedExternalNoise), .suspectedNoise, .capture)
    add(tagged(.clipping) || unavailable(.clipping) || warned(.clipping), .clipping, .capture)
    add(tagged(.nonSpeechDetected), .nonSpeech, .capture)
    add(tagged(.energyIneligible), .insufficientEnergy, .capture)
    add(
        tagged(.lowPeriodicityConfidence), .lowPeriodicity, .capture, uncertain: true)
    add(tagged(.algorithmInsufficiency), .untrustedMeasurements, .capture, uncertain: true)
    add(model.contains(.insufficientCoverage), .insufficientCoverage, .coverage)
    let ordered: [(CalibrationMetricSummary, PersonalTargetFeedbackFeature)] = [
        (observation.pitch, .fundamentalFrequency), (observation.level, .levelDBFS),
        (observation.cpps, .cpps),
    ]
    for (summary, feature) in ordered {
        add(
            summary.availableCount < policy.minimumAvailableObservations
                || Double(summary.availableCount) / Double(max(1, summary.observationCount))
                    < policy.minimumAvailableFraction,
            .unavailableMeasurements, feature)
        add(
            summary.warnings.contains {
                $0.key != MeasurementWarning.partialCoverage.rawValue && $0.value > 0
            }, .untrustedMeasurements, feature, uncertain: true)
        let boundary = summary.warnings[MeasurementWarning.partialCoverage.rawValue, default: 0]
        add(
            Double(boundary) / Double(max(1, summary.availableCount))
                > policy.maximumBoundaryFraction,
            .insufficientCoverage, feature)
    }
    add(model.contains(.invalidMeasurements), .unavailableMeasurements, .fundamentalFrequency)
    add(
        model.contains(.outsideObservedPitch), .outsideObservedPitch, .fundamentalFrequency,
        uncertain: true)
    add(model.contains(.outsideObservedLevel), .outsideObservedLevel, .levelDBFS, uncertain: true)
    add(model.contains(.outsideObservedCPPS), .outsideObservedCPPS, .cpps, uncertain: true)
    if prediction.predicted == nil && entries.isEmpty {
        entries.append((.unavailableMeasurements, .cpps, false))
    }
    return FeedbackFindings(
        reasons: entries.map(\.0), feature: entries.first?.1,
        uncertain: !entries.isEmpty && entries.allSatisfy(\.2))
}
