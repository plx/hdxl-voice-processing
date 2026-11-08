import Foundation

/// Inspection-only fitted rule and provenance. This imports a proposal, never an
/// ActivatedPersonalTarget or a fit receipt. A claimed evaluation identity records
/// what the exporter said; it is not evidence that the imported numbers are true.
public struct SessionArchiveTarget: Sendable, Hashable, Codable {
    public let schemaVersion = 1
    public let datasetIndex: UInt32
    public let splitIndex: UInt32
    public let candidate: PersonalTargetCandidate
    public let validationClaim: SessionArchiveValidationClaim
    public let claimedEvaluationIdentity: CalibrationDigest?
    public static let maximumEncodedBytes = 128 * 1024

    public init(
        datasetIndex: UInt32, splitIndex: UInt32, candidate: PersonalTargetCandidate,
        validation: PersonalTargetValidationEvidence,
        claimedEvaluationIdentity: CalibrationDigest? = nil
    ) throws {
        try self.init(
            datasetIndex: datasetIndex, splitIndex: splitIndex, candidate: candidate,
            validationClaim: SessionArchiveValidationClaim(validation),
            claimedEvaluationIdentity: claimedEvaluationIdentity)
    }

    private init(
        datasetIndex: UInt32, splitIndex: UInt32, candidate: PersonalTargetCandidate,
        validationClaim: SessionArchiveValidationClaim,
        claimedEvaluationIdentity: CalibrationDigest?
    ) throws {
        try validateArchivedCandidate(candidate)
        guard try validationClaim.identity() == candidate.validationIdentity,
            validationClaim.profile == candidate.scope.profile,
            validationClaim.analysisImplementation == candidate.scope.analysisImplementation
        else { throw SessionArchiveError.incompatibleProfile }
        self.datasetIndex = datasetIndex
        self.splitIndex = splitIndex
        self.candidate = candidate
        self.validationClaim = validationClaim
        self.claimedEvaluationIdentity = claimedEvaluationIdentity
        guard try canonicalContractJSON(self).count <= Self.maximumEncodedBytes else {
            throw SessionArchiveError.sizeLimitExceeded
        }
    }

    public init(
        datasetIndex: UInt32, splitIndex: UInt32, target: ActivatedPersonalTarget,
        validation: PersonalTargetValidationEvidence
    ) throws {
        try self.init(
            datasetIndex: datasetIndex, splitIndex: splitIndex,
            candidate: target.candidate, validation: validation,
            claimedEvaluationIdentity: target.evaluationIdentity)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, datasetIndex, splitIndex, candidate, validationClaim,
            claimedEvaluationIdentity
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw SessionArchiveError.unsupportedVersion
        }
        guard c.contains(.claimedEvaluationIdentity) else {
            throw SessionArchiveError.invalidMetadata
        }
        try self.init(
            datasetIndex: c.decode(UInt32.self, forKey: .datasetIndex),
            splitIndex: c.decode(UInt32.self, forKey: .splitIndex),
            candidate: c.decode(ArchivedCandidateDocument.self, forKey: .candidate).value,
            validationClaim: c.decode(SessionArchiveValidationClaim.self, forKey: .validationClaim),
            claimedEvaluationIdentity: c.decodeIfPresent(
                CalibrationDigest.self, forKey: .claimedEvaluationIdentity))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(datasetIndex, forKey: .datasetIndex)
        try c.encode(splitIndex, forKey: .splitIndex)
        try c.encode(candidate, forKey: .candidate)
        try c.encode(validationClaim, forKey: .validationClaim)
        try c.encode(claimedEvaluationIdentity, forKey: .claimedEvaluationIdentity)
    }
}

// These private decoding bridges deliberately do not add Decodable to runtime
// targets, candidates, fit/evaluation receipts or validation evidence. Structural
// import cannot create any of the capabilities required for feedback activation.
private struct ArchivedIntervalDocument: Decodable {
    let value: PersonalTargetInterval
    private enum CodingKeys: String, CodingKey, CaseIterable { case lower, upper }
    init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        value = try PersonalTargetInterval(
            lower: c.decode(Double.self, forKey: .lower),
            upper: c.decode(Double.self, forKey: .upper))
    }
}

private struct ArchivedDistributionDocument: Decodable {
    let value: PersonalTargetDistribution
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case count, minimum, lowerQuartile, median, upperQuartile, maximum
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        value = try PersonalTargetDistribution(
            count: c.decode(Int.self, forKey: .count),
            minimum: c.decode(Double.self, forKey: .minimum),
            lowerQuartile: c.decode(Double.self, forKey: .lowerQuartile),
            median: c.decode(Double.self, forKey: .median),
            upperQuartile: c.decode(Double.self, forKey: .upperQuartile),
            maximum: c.decode(Double.self, forKey: .maximum))
    }
}

private struct ArchivedPolicyDocument: Decodable {
    let value: PersonalTargetPolicy
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case minimumTrainingGroupsPerClass, minimumEvaluationGroupsPerClass, minimumLaterSessions
        case minimumSelectedSamples, minimumSelectedFraction, minimumAvailableFraction,
            minimumAvailableObservations
        case maximumBoundaryFraction, minimumLabelConfidence, minimumBalancedAccuracy,
            maximumAbstentionFraction
        case interquartileMultiplier, confoundAccuracyFloor, confoundComparisonSlack
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        value = try PersonalTargetPolicy(
            minimumTrainingGroupsPerClass: c.decode(
                Int.self, forKey: .minimumTrainingGroupsPerClass),
            minimumEvaluationGroupsPerClass: c.decode(
                Int.self, forKey: .minimumEvaluationGroupsPerClass),
            minimumLaterSessions: c.decode(Int.self, forKey: .minimumLaterSessions),
            minimumSelectedSamples: c.decode(Int64.self, forKey: .minimumSelectedSamples),
            minimumSelectedFraction: c.decode(Double.self, forKey: .minimumSelectedFraction),
            minimumAvailableFraction: c.decode(Double.self, forKey: .minimumAvailableFraction),
            minimumAvailableObservations: c.decode(Int.self, forKey: .minimumAvailableObservations),
            maximumBoundaryFraction: c.decode(Double.self, forKey: .maximumBoundaryFraction),
            minimumLabelConfidence: c.decode(Double.self, forKey: .minimumLabelConfidence),
            minimumBalancedAccuracy: c.decode(Double.self, forKey: .minimumBalancedAccuracy),
            maximumAbstentionFraction: c.decode(Double.self, forKey: .maximumAbstentionFraction),
            interquartileMultiplier: c.decode(Double.self, forKey: .interquartileMultiplier),
            confoundAccuracyFloor: c.decode(Double.self, forKey: .confoundAccuracyFloor),
            confoundComparisonSlack: c.decode(Double.self, forKey: .confoundComparisonSlack))
    }
}

private func archivedEnum<Value: RawRepresentable>(_ type: Value.Type, raw: String) throws -> Value
where Value.RawValue == String {
    guard let value = type.init(rawValue: raw) else { throw SessionArchiveError.unsupportedRecord }
    return value
}

private struct ArchivedRuleDocument: Decodable {
    let value: PersonalTargetRule
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case statistic, preferredInterval, observedCPPS, preferredTraining, usualTraining,
            direction, featureScaling, procedure
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        value = try PersonalTargetRule(
            statistic: archivedEnum(
                PersonalTargetStatistic.self, raw: c.decode(String.self, forKey: .statistic)),
            preferredInterval: c.decode(ArchivedIntervalDocument.self, forKey: .preferredInterval)
                .value,
            observedCPPS: c.decode(ArchivedIntervalDocument.self, forKey: .observedCPPS).value,
            preferredTraining: c.decode(
                ArchivedDistributionDocument.self, forKey: .preferredTraining
            ).value,
            usualTraining: c.decode(ArchivedDistributionDocument.self, forKey: .usualTraining)
                .value,
            direction: archivedEnum(
                PersonalTargetDirection.self, raw: c.decode(String.self, forKey: .direction)))
        guard try c.decode(String.self, forKey: .featureScaling) == value.featureScaling,
            try c.decode(String.self, forKey: .procedure) == value.procedure
        else { throw SessionArchiveError.incompatibleProfile }
    }
}

private struct ArchivedScopeDocument: Decodable {
    let value: PersonalTargetScope
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case profile, analysisImplementation, statistic, task, conditions, observedPitchHz,
            observedLevelDBFS
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        value = try PersonalTargetScope(
            profile: c.decode(ProfileIdentity.self, forKey: .profile),
            analysisImplementation: c.decode(
                VersionedIdentifier.self, forKey: .analysisImplementation),
            statistic: archivedEnum(
                PersonalTargetStatistic.self, raw: c.decode(String.self, forKey: .statistic)),
            task: c.decode(CalibrationTask.self, forKey: .task),
            conditions: c.decode(CalibrationRecordingConditions.self, forKey: .conditions),
            observedPitchHz: c.decode(ArchivedIntervalDocument.self, forKey: .observedPitchHz)
                .value,
            observedLevelDBFS: c.decode(ArchivedIntervalDocument.self, forKey: .observedLevelDBFS)
                .value)
    }
}

private struct ArchivedContextDocument: Decodable {
    let value: PersonalTargetContextRule
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metric, preferredInterval, observedSupport
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        value = try PersonalTargetContextRule(
            metric: archivedEnum(
                PersonalTargetContextMetric.self, raw: c.decode(String.self, forKey: .metric)),
            preferredInterval: c.decode(ArchivedIntervalDocument.self, forKey: .preferredInterval)
                .value,
            observedSupport: c.decode(ArchivedIntervalDocument.self, forKey: .observedSupport).value
        )
    }
}

private struct ArchivedCandidateDocument: Decodable {
    let value: PersonalTargetCandidate
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, implementation, calibrationID, calibrationRevision, datasetIdentity,
            splitIdentity
        case trainingIdentity, validationIdentity, referenceTakeID, rule, scope, policy,
            contextRules
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw SessionArchiveError.unsupportedVersion
        }
        value = try PersonalTargetCandidate(
            schemaVersion: 1,
            implementation: c.decode(VersionedIdentifier.self, forKey: .implementation),
            calibrationID: c.decode(UUID.self, forKey: .calibrationID),
            calibrationRevision: c.decode(UInt64.self, forKey: .calibrationRevision),
            datasetIdentity: c.decode(CalibrationDigest.self, forKey: .datasetIdentity),
            splitIdentity: c.decode(CalibrationDigest.self, forKey: .splitIdentity),
            trainingIdentity: c.decode(CalibrationDigest.self, forKey: .trainingIdentity),
            validationIdentity: c.decode(CalibrationDigest.self, forKey: .validationIdentity),
            referenceTakeID: c.decode(UUID.self, forKey: .referenceTakeID),
            rule: c.decode(ArchivedRuleDocument.self, forKey: .rule).value,
            scope: c.decode(ArchivedScopeDocument.self, forKey: .scope).value,
            policy: c.decode(ArchivedPolicyDocument.self, forKey: .policy).value,
            contextRules: c.decode([ArchivedContextDocument].self, forKey: .contextRules).map(
                \.value))
        try validateArchivedCandidate(value)
    }
}

private func validateArchivedCandidate(_ candidate: PersonalTargetCandidate) throws {
    guard candidate.schemaVersion == 1 else { throw SessionArchiveError.unsupportedVersion }
    let rule = candidate.rule
    let scope = candidate.scope
    let contexts = candidate.contextRules
    guard candidate.calibrationRevision > 0, rule.statistic == scope.statistic,
        scope.observedPitchHz.lower > 0,
        contexts.count == PersonalTargetContextMetric.allCases.count,
        Set(contexts.map(\.metric)) == Set(PersonalTargetContextMetric.allCases),
        rule.preferredTraining.count >= candidate.policy.minimumTrainingGroupsPerClass,
        rule.usualTraining.count >= candidate.policy.minimumTrainingGroupsPerClass,
        rule.observedCPPS.lower == min(rule.preferredTraining.minimum, rule.usualTraining.minimum),
        rule.observedCPPS.upper == max(rule.preferredTraining.maximum, rule.usualTraining.maximum),
        try rule.preferredInterval
            == rule.preferredTraining.preferredInterval(
                multiplier: candidate.policy.interquartileMultiplier, support: rule.observedCPPS)
    else { throw SessionArchiveError.invalidMetadata }
    for context in contexts {
        guard context.observedSupport.contains(context.preferredInterval.lower),
            context.observedSupport.contains(context.preferredInterval.upper)
        else {
            throw SessionArchiveError.invalidMetadata
        }
        switch context.metric {
        case .fundamentalFrequency:
            guard context.observedSupport == scope.observedPitchHz else {
                throw SessionArchiveError.invalidMetadata
            }
        case .levelDBFS:
            guard context.observedSupport == scope.observedLevelDBFS else {
                throw SessionArchiveError.invalidMetadata
            }
        case .selectedFraction, .cppsAvailableFraction, .pitchAvailableFraction,
            .levelAvailableFraction:
            guard context.observedSupport.lower >= 0, context.observedSupport.upper <= 1 else {
                throw SessionArchiveError.invalidMetadata
            }
        }
    }
}
