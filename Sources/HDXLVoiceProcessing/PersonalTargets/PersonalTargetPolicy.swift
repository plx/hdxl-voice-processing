import Foundation

public enum PersonalTargetError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidValidationEvidence, incompatibleDataset
    case unexpectedAnalysis, capacityExceeded, referenceNotInTraining, invalidObservation
}

/// Explicit engineering requirements for this personal association model. These
/// constants are neither clinical thresholds nor validated statistical sample sizes.
public struct PersonalTargetPolicy: Sendable, Hashable, Encodable {
    public let minimumTrainingGroupsPerClass: Int
    public let minimumEvaluationGroupsPerClass: Int
    public let minimumLaterSessions: Int
    public let minimumSelectedSamples: Int64
    public let minimumSelectedFraction: Double
    public let minimumAvailableFraction: Double
    public let minimumAvailableObservations: Int
    public let maximumBoundaryFraction: Double
    public let minimumLabelConfidence: Double
    public let minimumBalancedAccuracy: Double
    public let maximumAbstentionFraction: Double
    public let interquartileMultiplier: Double
    public let confoundAccuracyFloor: Double
    public let confoundComparisonSlack: Double

    public init(
        minimumTrainingGroupsPerClass: Int = 4,
        minimumEvaluationGroupsPerClass: Int = 4,
        minimumLaterSessions: Int = 2,
        minimumSelectedSamples: Int64 = 1,
        minimumSelectedFraction: Double = 0.5,
        minimumAvailableFraction: Double = 0.5,
        minimumAvailableObservations: Int = 3,
        maximumBoundaryFraction: Double = 0.25,
        minimumLabelConfidence: Double = 0,
        minimumBalancedAccuracy: Double = 0.8,
        maximumAbstentionFraction: Double = 0.2,
        interquartileMultiplier: Double = 1.5,
        confoundAccuracyFloor: Double = 0.8,
        confoundComparisonSlack: Double = 0.05
    ) throws {
        let fractions = [
            minimumSelectedFraction, minimumAvailableFraction, maximumBoundaryFraction,
            minimumLabelConfidence, minimumBalancedAccuracy, maximumAbstentionFraction,
            confoundAccuracyFloor, confoundComparisonSlack,
        ]
        guard fractions.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
            (1...256).contains(minimumTrainingGroupsPerClass),
            (1...256).contains(minimumEvaluationGroupsPerClass),
            (1...CalibrationRecordLimits.maximumSessions).contains(minimumLaterSessions),
            minimumSelectedSamples > 0, minimumAvailableFraction > 0,
            (1...CalibrationMetricSummary.maximumObservationCount).contains(
                minimumAvailableObservations),
            minimumBalancedAccuracy > 0.5, maximumAbstentionFraction < 1,
            confoundAccuracyFloor > 0.5, confoundComparisonSlack <= 0.5,
            interquartileMultiplier.isFinite, (0...3).contains(interquartileMultiplier)
        else { throw PersonalTargetError.invalidConfiguration }
        self.minimumTrainingGroupsPerClass = minimumTrainingGroupsPerClass
        self.minimumEvaluationGroupsPerClass = minimumEvaluationGroupsPerClass
        self.minimumLaterSessions = minimumLaterSessions
        self.minimumSelectedSamples = minimumSelectedSamples
        self.minimumSelectedFraction = minimumSelectedFraction == 0 ? 0 : minimumSelectedFraction
        self.minimumAvailableFraction = minimumAvailableFraction == 0 ? 0 : minimumAvailableFraction
        self.minimumAvailableObservations = minimumAvailableObservations
        self.maximumBoundaryFraction = maximumBoundaryFraction == 0 ? 0 : maximumBoundaryFraction
        self.minimumLabelConfidence = minimumLabelConfidence == 0 ? 0 : minimumLabelConfidence
        self.minimumBalancedAccuracy = minimumBalancedAccuracy == 0 ? 0 : minimumBalancedAccuracy
        self.maximumAbstentionFraction =
            maximumAbstentionFraction == 0 ? 0 : maximumAbstentionFraction
        self.interquartileMultiplier = interquartileMultiplier == 0 ? 0 : interquartileMultiplier
        self.confoundAccuracyFloor = confoundAccuracyFloor == 0 ? 0 : confoundAccuracyFloor
        self.confoundComparisonSlack = confoundComparisonSlack == 0 ? 0 : confoundComparisonSlack
    }
}

/// Stable reasons apply to records, groups, a proposed fit, or its activation.
/// A refused activation is an ordinary analytical result, not a thrown failure.
public enum PersonalTargetReason: String, Sendable, Hashable, Encodable, CaseIterable {
    case excludedRecording, missingLabel, unsupportedLabel, labelExposedToFeatures
    case insufficientLabelConfidence, unknownConditions, changedConditions
    case differentTask, differentProfile, missingAnalysis, incompatibleAnalysis
    case insufficientCoverage, insufficientMetricObservations, insufficientMetricAvailability
    case untrustedMetricWarnings, excessiveBoundaryCoverage, invalidMeasurements
    case conflictingGroupLabels, conflictingGroupMetadata, inconsistentAliasAnalysis
    case groupContainsRejectedTake, insufficientTrainingGroups, unrepresentableInterval
    case nonSeparatingTraining, insufficientEvaluationGroups, excessiveAbstention
    case poorHeldOutSeparation, insufficientLaterSessions, poorSessionSeparation
    case possiblePitchConfound, possibleLevelConfound, possibleCoverageConfound
    case possibleAvailabilityConfound, outsideObservedCPPS, outsideObservedPitch
    case outsideObservedLevel, incompatibleObservationSemantics
    case contextOutsideObservedRange
}

public enum PersonalTargetDirection: String, Sendable, Hashable, Encodable {
    case usualBelowInterval, usualAboveInterval, usualOnBothSides, overlapping
}

/// The model expects a selected-interval empirical median, not one instantaneous
/// frame, an arithmetic CPPS interval mean, or an amplitude-normalized recording.
public enum PersonalTargetStatistic: String, Sendable, Hashable, Encodable {
    case selectedIntervalLowerMedianV1
}

public enum PersonalTargetContextMetric: String, Sendable, Hashable, Encodable, CaseIterable {
    case fundamentalFrequency, levelDBFS, selectedFraction
    case cppsAvailableFraction, pitchAvailableFraction, levelAvailableFraction
}

func targetReasons(_ values: [PersonalTargetReason]) -> [PersonalTargetReason] {
    Array(Set(values)).sorted { $0.rawValue < $1.rawValue }
}
