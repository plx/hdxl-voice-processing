import Foundation

public struct PersonalTargetPrediction: Sendable, Hashable, Encodable {
    /// Nil is abstention. A prediction is an association with the supplied personal
    /// labels, never a probability, diagnosis, or universal judgment of a voice.
    public let predicted: PersonalTargetClass?
    public let reasons: [PersonalTargetReason]
}

public struct PersonalTargetGroupResult: Sendable, Hashable, Encodable {
    public let group: PersonalTargetGroupSummary
    public let prediction: PersonalTargetPrediction
}

public struct PersonalTargetClassificationReport: Sendable, Hashable, Encodable {
    public let totalGroups: Int
    public let preferredGroups: Int
    public let usualGroups: Int
    public let unknownLabelGroups: Int
    public let preferredPredictedPreferred: Int
    public let preferredPredictedUsual: Int
    public let preferredAbstained: Int
    public let usualPredictedUsual: Int
    public let usualPredictedPreferred: Int
    public let usualAbstained: Int
    public let classifiedGroups: Int
    public let abstainedGroups: Int
    public let classificationCoverage: Double?
    // Compute from counts: subtracting coverage can round an exact policy
    // boundary upward. Nil preserves the explicit empty-partition behavior.
    var abstentionFraction: Double? {
        totalGroups == 0 ? nil : Double(abstainedGroups) / Double(totalGroups)
    }
    /// Includes abstentions as failures to recognize the actual class. Conditional
    /// accuracy among answered examples alone must not hide discarded hard cases.
    public let preferredRecall: Double?
    public let usualRecall: Double?
    public let balancedAccuracy: Double?
    public let accuracyAmongClassified: Double?
    public let preferredConditionalInterval: PersonalTargetConditionalInterval?
    public let usualConditionalInterval: PersonalTargetConditionalInterval?
    public let errorGroups: [CalibrationDigest]
    public let abstainedGroupIDs: [CalibrationDigest]
    public let statisticalUnit = "original-acquisition-or-identical-content-group"
    public let uncertaintyLimitations = [
        "Wilson intervals assume independent acquisition-group outcomes",
        "Within-person and within-session correlation can invalidate those intervals",
        "No independent-voice or population inference; inspect per-session outcomes",
    ]

    init(_ results: [PersonalTargetGroupResult]) {
        totalGroups = results.count
        let preferred = results.filter { $0.group.actual == .preferred }
        let usual = results.filter { $0.group.actual == .usual }
        preferredGroups = preferred.count
        usualGroups = usual.count
        unknownLabelGroups = results.count - preferred.count - usual.count
        preferredPredictedPreferred =
            preferred.filter { $0.prediction.predicted == .preferred }.count
        preferredPredictedUsual = preferred.filter { $0.prediction.predicted == .usual }.count
        preferredAbstained = preferred.filter { $0.prediction.predicted == nil }.count
        usualPredictedUsual = usual.filter { $0.prediction.predicted == .usual }.count
        usualPredictedPreferred = usual.filter { $0.prediction.predicted == .preferred }.count
        usualAbstained = usual.filter { $0.prediction.predicted == nil }.count
        classifiedGroups = results.filter { $0.prediction.predicted != nil }.count
        abstainedGroups = results.count - classifiedGroups
        classificationCoverage =
            results.isEmpty ? nil : Double(classifiedGroups) / Double(results.count)
        preferredRecall =
            preferred.isEmpty
            ? nil : Double(preferredPredictedPreferred) / Double(preferred.count)
        usualRecall = usual.isEmpty ? nil : Double(usualPredictedUsual) / Double(usual.count)
        if let preferredRecall, let usualRecall {
            balancedAccuracy = (preferredRecall + usualRecall) / 2
        } else {
            balancedAccuracy = nil
        }
        let classifiedKnown =
            preferredPredictedPreferred + preferredPredictedUsual
            + usualPredictedUsual + usualPredictedPreferred
        accuracyAmongClassified =
            classifiedKnown == 0
            ? nil
            : Double(preferredPredictedPreferred + usualPredictedUsual) / Double(classifiedKnown)
        preferredConditionalInterval = PersonalTargetConditionalInterval(
            successes: preferredPredictedPreferred, trials: preferred.count)
        usualConditionalInterval = PersonalTargetConditionalInterval(
            successes: usualPredictedUsual, trials: usual.count)
        errorGroups = results.filter {
            $0.group.actual != nil && $0.prediction.predicted != nil
                && $0.group.actual != $0.prediction.predicted
        }.map { $0.group.recordingGroup }
        abstainedGroupIDs = results.filter { $0.prediction.predicted == nil }
            .map { $0.group.recordingGroup }
    }
}

/// This comparison detects associations, not a causal explanation. All context
/// intervals are fitted on training data once, just like the primary CPPS rule.
public struct PersonalTargetContextReport: Sendable, Hashable, Encodable {
    public let metric: PersonalTargetContextMetric
    public let classification: PersonalTargetClassificationReport
    public let possibleConfound: Bool
}

public struct PersonalTargetPartitionReport: Sendable, Hashable, Encodable {
    public let role: CalibrationSplitRole
    public let groups: [PersonalTargetGroupResult]
    public let classification: PersonalTargetClassificationReport
    /// Activation applies only to the task/conditions/profile selected before fit.
    /// Overall classification above still discloses all out-of-scope abstentions.
    public let inScopeClassification: PersonalTargetClassificationReport
    public let outOfScopeGroupIDs: [CalibrationDigest]
    public let context: [PersonalTargetContextReport]
}

public struct PersonalTargetSessionReport: Sendable, Hashable, Encodable {
    public let sessionID: UUID
    public let classification: PersonalTargetClassificationReport
    public let inScopeClassification: PersonalTargetClassificationReport
    public let context: [PersonalTargetContextReport]
}

public struct PersonalTargetFit: Sendable, Hashable, Encodable {
    public let schemaVersion: Int
    public let calibrationID: UUID
    public let calibrationRevision: UInt64
    public let datasetIdentity: CalibrationDigest
    public let splitIdentity: CalibrationDigest
    public let trainingIdentity: CalibrationDigest
    public let referenceTakeID: UUID
    public let policy: PersonalTargetPolicy
    public let validation: PersonalTargetValidationEvidence
    public let candidate: PersonalTargetCandidate?
    public let training: PersonalTargetPartitionReport
    public let reasons: [PersonalTargetReason]

    public func identity() throws -> CalibrationDigest { try calibrationDigest(self) }
}

public struct PersonalTargetEvaluation: Sendable, Hashable, Encodable {
    public let schemaVersion: Int
    public let fitIdentity: CalibrationDigest
    public let evaluationIdentity: CalibrationDigest
    public let recordingEvaluation: PersonalTargetPartitionReport
    public let sessionEvaluation: PersonalTargetPartitionReport
    public let laterSessions: [PersonalTargetSessionReport]
    /// Observed between-session range, not a confidence bound for future sessions.
    /// Nil unless at least two later sessions have defined balanced accuracy.
    public let observedSessionBalancedAccuracyRange: PersonalTargetInterval?
    public let reasons: [PersonalTargetReason]
    public let activated: ActivatedPersonalTarget?
}
