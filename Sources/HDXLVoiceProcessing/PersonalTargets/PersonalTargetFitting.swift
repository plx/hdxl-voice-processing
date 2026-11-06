import Foundation

/// Deterministic offline fitting. The fitting entry point accepts only training
/// analyses; evaluation analyses are accepted by a separate entry point.
public enum PersonalTargetFitter {
    public static var implementation: VersionedIdentifier {
        try! VersionedIdentifier(name: "personal-cpps-iqr-band", version: 1)
    }

    public static func fit(
        dataset: CalibrationDataset, split: CalibrationSplitPlan,
        trainingAnalyses: [UUID: CalibrationAnalysisRecord], referenceTakeID: UUID,
        validation: PersonalTargetValidationEvidence, policy: PersonalTargetPolicy
    ) throws -> PersonalTargetFit {
        let partition = try split.partition(dataset: dataset)
        try validateTargetAnalysisKeys(trainingAnalyses, members: partition.fitting)
        guard
            let reference = partition.fitting.first(where: { $0.take.id == referenceTakeID })?.take
        else { throw PersonalTargetError.referenceNotInTraining }
        guard validation.profile == reference.profileIdentity,
            validation.analysisImplementation == CalibrationAnalysisKey.currentImplementation
        else { throw PersonalTargetError.invalidValidationEvidence }
        let splitIdentity = try calibrationDigest(split)
        let validationIdentity = try validation.identity()
        let trainingIdentity = try calibrationDigest(
            TargetTrainingFingerprint(
                referenceTakeID: referenceTakeID, policy: policy,
                validationIdentity: validationIdentity,
                records: targetInputIdentities(partition.fitting, analyses: trainingAnalyses)))
        let groups = try prepareTargetGroups(
            partition.fitting, analyses: trainingAnalyses, reference: reference, policy: policy)
        let preferred = groups.filter { $0.actual == .preferred && $0.values != nil }
        let usual = groups.filter { $0.actual == .usual && $0.values != nil }
        var reasons: [PersonalTargetReason] = []
        var candidate: PersonalTargetCandidate?
        if preferred.count < policy.minimumTrainingGroupsPerClass
            || usual.count < policy.minimumTrainingGroupsPerClass
        {
            reasons.append(.insufficientTrainingGroups)
        } else {
            do {
                candidate = try makeTargetCandidate(
                    dataset: dataset, splitIdentity: splitIdentity,
                    trainingIdentity: trainingIdentity, validationIdentity: validationIdentity,
                    reference: reference, preferred: preferred, usual: usual, policy: policy)
            } catch PersonalTargetError.invalidObservation {
                reasons.append(.unrepresentableInterval)
            }
        }
        let report = targetPartitionReport(
            role: .fitting, groups: groups, candidate: candidate, missingCandidateReasons: reasons)
        let counts = report.inScopeClassification
        if candidate != nil {
            if (counts.balancedAccuracy ?? 0) < policy.minimumBalancedAccuracy {
                reasons.append(.nonSeparatingTraining)
            }
            if 1 - (counts.classificationCoverage ?? 0) > policy.maximumAbstentionFraction {
                reasons.append(.excessiveAbstention)
            }
            reasons += targetConfoundReasons(report.context)
        }
        return PersonalTargetFit(
            schemaVersion: 1, calibrationID: dataset.id, calibrationRevision: dataset.revision,
            datasetIdentity: split.datasetIdentity, splitIdentity: splitIdentity,
            trainingIdentity: trainingIdentity, referenceTakeID: referenceTakeID, policy: policy,
            validation: validation, candidate: candidate, training: report,
            reasons: targetReasons(reasons))
    }
}

private struct TargetInputIdentity: Encodable {
    let sessionID: UUID
    let recordingGroup: CalibrationDigest
    let role: CalibrationSplitRole
    let take: CalibrationTake
    let analysisIdentity: CalibrationDigest?
}

private struct TargetTrainingFingerprint: Encodable {
    let referenceTakeID: UUID
    let policy: PersonalTargetPolicy
    let validationIdentity: CalibrationDigest
    let records: [CalibrationDigest]
}

/// Hash bounded records separately instead of constructing a second serialized
/// dataset-sized training array. Both included and rejected inputs are bound.
func targetInputIdentities(
    _ members: [CalibrationAssignedTake], analyses: [UUID: CalibrationAnalysisRecord]
) throws -> [CalibrationDigest] {
    try members.sorted { $0.take.id.uuidString < $1.take.id.uuidString }.map { member in
        try autoreleasepool {
            try calibrationDigest(
                TargetInputIdentity(
                    sessionID: member.sessionID, recordingGroup: member.recordingGroup,
                    role: member.role, take: member.take,
                    analysisIdentity: analyses[member.take.id].map { try calibrationDigest($0) }))
        }
    }
}

func validateTargetAnalysisKeys(
    _ analyses: [UUID: CalibrationAnalysisRecord], members: [CalibrationAssignedTake]
) throws {
    guard analyses.count <= CalibrationRecordLimits.maximumTakes else {
        throw PersonalTargetError.capacityExceeded
    }
    let allowed = Set(members.map { $0.take.id })
    guard Set(analyses.keys).isSubset(of: allowed) else {
        throw PersonalTargetError.unexpectedAnalysis
    }
}

private func makeTargetCandidate(
    dataset: CalibrationDataset, splitIdentity: CalibrationDigest,
    trainingIdentity: CalibrationDigest, validationIdentity: CalibrationDigest,
    reference: CalibrationTake, preferred: [PersonalTargetGroupSummary],
    usual: [PersonalTargetGroupSummary], policy: PersonalTargetPolicy
) throws -> PersonalTargetCandidate {
    let preferredPoints = preferred.compactMap(\.values)
    let usualPoints = usual.compactMap(\.values)
    let all = preferredPoints + usualPoints
    let preferredDistribution = try PersonalTargetDistribution(preferredPoints.map(\.cppsDB))
    let usualDistribution = try PersonalTargetDistribution(usualPoints.map(\.cppsDB))
    let support = try PersonalTargetDistribution(all.map(\.cppsDB)).extent
    let interval = try preferredDistribution.preferredInterval(
        multiplier: policy.interquartileMultiplier, support: support)
    let below = usualPoints.contains { $0.cppsDB < interval.lower }
    let above = usualPoints.contains { $0.cppsDB > interval.upper }
    let overlaps = usualPoints.contains { interval.contains($0.cppsDB) }
    let direction: PersonalTargetDirection
    if overlaps {
        direction = .overlapping
    } else if below && above {
        direction = .usualOnBothSides
    } else if below {
        direction = .usualBelowInterval
    } else {
        direction = .usualAboveInterval
    }
    let rule = PersonalTargetRule(
        statistic: .selectedIntervalLowerMedianV1, preferredInterval: interval,
        observedCPPS: support, preferredTraining: preferredDistribution,
        usualTraining: usualDistribution, direction: direction)
    let scope = PersonalTargetScope(
        profile: reference.profileIdentity,
        analysisImplementation: CalibrationAnalysisKey.currentImplementation,
        statistic: .selectedIntervalLowerMedianV1,
        task: reference.task, conditions: reference.conditions,
        observedPitchHz: try PersonalTargetDistribution(all.map(\.fundamentalFrequencyHz)).extent,
        observedLevelDBFS: try PersonalTargetDistribution(all.map(\.levelDBFS)).extent)
    let context = try PersonalTargetContextMetric.allCases.map { metric in
        let support = try PersonalTargetDistribution(all.map { $0.context(metric) }).extent
        return try PersonalTargetContextRule(
            metric: metric,
            preferredInterval: PersonalTargetDistribution(
                preferredPoints.map { $0.context(metric) }
            )
            .preferredInterval(multiplier: policy.interquartileMultiplier, support: support),
            observedSupport: support)
    }
    return try PersonalTargetCandidate(
        schemaVersion: 1, implementation: PersonalTargetFitter.implementation,
        calibrationID: dataset.id, calibrationRevision: dataset.revision,
        datasetIdentity: dataset.identity(), splitIdentity: splitIdentity,
        trainingIdentity: trainingIdentity, validationIdentity: validationIdentity,
        referenceTakeID: reference.id, rule: rule, scope: scope, policy: policy,
        contextRules: context)
}
