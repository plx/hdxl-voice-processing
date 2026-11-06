import Foundation

public struct PersonalTargetRule: Sendable, Hashable, Encodable {
    public let statistic: PersonalTargetStatistic
    public let preferredInterval: PersonalTargetInterval
    public let observedCPPS: PersonalTargetInterval
    public let preferredTraining: PersonalTargetDistribution
    public let usualTraining: PersonalTargetDistribution
    public let direction: PersonalTargetDirection
    public let featureScaling = "identity; CPPS dB"
    public let procedure = "preferred empirical quartiles plus IQR fences within training support"
}

public struct PersonalTargetContextRule: Sendable, Hashable, Encodable {
    public let metric: PersonalTargetContextMetric
    public let preferredInterval: PersonalTargetInterval
    public let observedSupport: PersonalTargetInterval
}

public struct PersonalTargetScope: Sendable, Hashable, Encodable {
    public let profile: ProfileIdentity
    public let analysisImplementation: VersionedIdentifier
    public let statistic: PersonalTargetStatistic
    public let task: CalibrationTask
    public let conditions: CalibrationRecordingConditions
    public let observedPitchHz: PersonalTargetInterval
    public let observedLevelDBFS: PersonalTargetInterval
}

/// A proposal is deliberately distinct from an activated target. Numerical
/// parameters are immutable; evaluating a proposal never widens these intervals.
public struct PersonalTargetCandidate: Sendable, Hashable, Encodable {
    public let schemaVersion: Int
    public let implementation: VersionedIdentifier
    public let calibrationID: UUID
    public let calibrationRevision: UInt64
    public let datasetIdentity: CalibrationDigest
    public let splitIdentity: CalibrationDigest
    public let trainingIdentity: CalibrationDigest
    public let validationIdentity: CalibrationDigest
    public let referenceTakeID: UUID
    public let rule: PersonalTargetRule
    public let scope: PersonalTargetScope
    public let policy: PersonalTargetPolicy
    public let contextRules: [PersonalTargetContextRule]

    public func identity() throws -> CalibrationDigest { try calibrationDigest(self) }

    func predict(_ values: PersonalTargetValues) -> PersonalTargetPrediction {
        var reasons: [PersonalTargetReason] = []
        if !rule.observedCPPS.contains(values.cppsDB) { reasons.append(.outsideObservedCPPS) }
        if !scope.observedPitchHz.contains(values.fundamentalFrequencyHz) {
            reasons.append(.outsideObservedPitch)
        }
        if !scope.observedLevelDBFS.contains(values.levelDBFS) {
            reasons.append(.outsideObservedLevel)
        }
        return PersonalTargetPrediction(
            predicted: reasons.isEmpty
                ? (rule.preferredInterval.contains(values.cppsDB) ? .preferred : .usual) : nil,
            reasons: targetReasons(reasons))
    }
}

/// Contains no dataset, per-take history, PCM, or fitted-on-every-block state.
/// The complete encoded model is limited to 64 KiB; normal models are much smaller.
/// Construct observations on a worker path with the declared summary semantics.
public struct ActivatedPersonalTarget: Sendable, Hashable, Encodable {
    public static let maximumEncodedBytes = 64 * 1024
    public let candidate: PersonalTargetCandidate
    public let evaluationIdentity: CalibrationDigest
    public let activationReasons = [
        "exact-profile-reference-and-boundary-evidence",
        "sufficient-training-and-holdout-groups",
        "training-and-whole-recording-holdout-separation",
        "later-whole-session-separation",
        "bounded-abstention-with-explicit-conditions",
        "no-comparable-context-only-separation-observed",
    ]

    public func identity() throws -> CalibrationDigest { try calibrationDigest(self) }

    public func prediction(for observation: PersonalTargetObservation) -> PersonalTargetPrediction {
        let scope = candidate.scope
        var reasons = observation.findings(policy: candidate.policy)
        if observation.profile != scope.profile
            || observation.analysisImplementation != scope.analysisImplementation
        {
            reasons.append(.differentProfile)
        }
        if observation.statistic != scope.statistic {
            reasons.append(.incompatibleObservationSemantics)
        }
        if observation.task != scope.task { reasons.append(.differentTask) }
        reasons += targetConditionFindings(observation.conditions, reference: scope.conditions)
        guard reasons.isEmpty, let point = observation.values(policy: candidate.policy) else {
            if reasons.isEmpty { reasons.append(.invalidMeasurements) }
            return PersonalTargetPrediction(predicted: nil, reasons: targetReasons(reasons))
        }
        return candidate.predict(point)
    }
}

func targetPartitionReport(
    role: CalibrationSplitRole, groups: [PersonalTargetGroupSummary],
    candidate: PersonalTargetCandidate?, missingCandidateReasons: [PersonalTargetReason]
) -> PersonalTargetPartitionReport {
    let results = groups.map { group in
        let prediction: PersonalTargetPrediction
        if let values = group.values, let candidate {
            prediction = candidate.predict(values)
        } else {
            let reasons = group.reasons.isEmpty ? missingCandidateReasons : group.reasons
            prediction = PersonalTargetPrediction(predicted: nil, reasons: targetReasons(reasons))
        }
        return PersonalTargetGroupResult(group: group, prediction: prediction)
    }
    let classification = PersonalTargetClassificationReport(results)
    let inScope = PersonalTargetClassificationReport(results.filter { $0.group.isInScope })
    return PersonalTargetPartitionReport(
        role: role, groups: results, classification: classification,
        inScopeClassification: inScope,
        outOfScopeGroupIDs: groups.filter { !$0.isInScope }.map(\.recordingGroup),
        context: targetContextReports(
            groups: groups.filter(\.isInScope), candidate: candidate, primary: inScope))
}

func targetContextReports(
    groups: [PersonalTargetGroupSummary], candidate: PersonalTargetCandidate?,
    primary: PersonalTargetClassificationReport
) -> [PersonalTargetContextReport] {
    guard let candidate else { return [] }
    return candidate.contextRules.map { rule in
        let results = groups.map { group in
            let predicted: PersonalTargetClass?
            var reasons = group.reasons
            if let point = group.values, rule.observedSupport.contains(point.context(rule.metric)) {
                predicted =
                    rule.preferredInterval.contains(point.context(rule.metric))
                    ? .preferred : .usual
            } else {
                predicted = nil
                if reasons.isEmpty { reasons.append(.contextOutsideObservedRange) }
            }
            return PersonalTargetGroupResult(
                group: group,
                prediction: PersonalTargetPrediction(
                    predicted: predicted, reasons: targetReasons(reasons)))
        }
        let comparison = PersonalTargetClassificationReport(results)
        let confound =
            comparison.balancedAccuracy.map { accuracy in
                accuracy >= candidate.policy.confoundAccuracyFloor
                    && accuracy + candidate.policy.confoundComparisonSlack
                        >= (primary.balancedAccuracy ?? 1)
            } ?? false
        return PersonalTargetContextReport(
            metric: rule.metric, classification: comparison, possibleConfound: confound)
    }
}

func targetConfoundReasons(_ reports: [PersonalTargetContextReport]) -> [PersonalTargetReason] {
    reports.filter(\.possibleConfound).map {
        switch $0.metric {
        case .fundamentalFrequency: .possiblePitchConfound
        case .levelDBFS: .possibleLevelConfound
        case .selectedFraction: .possibleCoverageConfound
        default: .possibleAvailabilityConfound
        }
    }
}
