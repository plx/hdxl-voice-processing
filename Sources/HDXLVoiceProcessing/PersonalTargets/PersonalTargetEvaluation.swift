import Foundation

extension PersonalTargetFitter {
    /// Evaluation is tied to the exact dataset/split version. A changed holdout
    /// requires a new version and fit receipt; it cannot mutate the previous fit.
    public static func evaluate(
        _ fit: PersonalTargetFit, dataset: CalibrationDataset, split: CalibrationSplitPlan,
        evaluationAnalyses: [UUID: CalibrationAnalysisRecord]
    ) throws -> PersonalTargetEvaluation {
        guard fit.calibrationID == dataset.id, fit.calibrationRevision == dataset.revision,
            fit.datasetIdentity == (try dataset.identity()),
            fit.splitIdentity == (try calibrationDigest(split))
        else { throw PersonalTargetError.incompatibleDataset }
        let partition = try split.partition(dataset: dataset)
        let members = partition.recordingEvaluation + partition.sessionEvaluation
        try validateTargetAnalysisKeys(evaluationAnalyses, members: members)
        guard
            let reference = partition.fitting.first(where: { $0.take.id == fit.referenceTakeID })?
                .take
        else { throw PersonalTargetError.referenceNotInTraining }
        let fitIdentity = try fit.identity()
        let evaluationIdentity = try calibrationDigest(
            TargetEvaluationFingerprint(
                fitIdentity: fitIdentity,
                records: targetInputIdentities(members, analyses: evaluationAnalyses)))
        let recordingGroups = try prepareTargetGroups(
            partition.recordingEvaluation, analyses: evaluationAnalyses,
            reference: reference, policy: fit.policy)
        let sessionGroups = try prepareTargetGroups(
            partition.sessionEvaluation, analyses: evaluationAnalyses,
            reference: reference, policy: fit.policy)
        let recording = targetPartitionReport(
            role: .recordingEvaluation, groups: recordingGroups, candidate: fit.candidate,
            missingCandidateReasons: fit.reasons)
        let session = targetPartitionReport(
            role: .sessionEvaluation, groups: sessionGroups, candidate: fit.candidate,
            missingCandidateReasons: fit.reasons)
        let laterSessions = split.sessionEvaluationIDs.map { sessionID in
            let results = session.groups.filter { $0.group.sessionIDs == [sessionID] }
            let inScope = results.filter { $0.group.isInScope }
            let counts = PersonalTargetClassificationReport(inScope)
            return PersonalTargetSessionReport(
                sessionID: sessionID,
                classification: PersonalTargetClassificationReport(results),
                inScopeClassification: counts,
                context: targetContextReports(
                    groups: inScope.map(\.group), candidate: fit.candidate, primary: counts))
        }
        var reasons = fit.reasons
        for report in [recording, session] {
            reasons += targetEvaluationReasons(report.inScopeClassification, policy: fit.policy)
            reasons += targetConfoundReasons(report.context)
        }
        let represented = laterSessions.filter { $0.inScopeClassification.totalGroups > 0 }
        if represented.count < fit.policy.minimumLaterSessions {
            reasons.append(.insufficientLaterSessions)
        }
        for report in represented {
            let counts = report.inScopeClassification
            if counts.preferredGroups == 0 || counts.usualGroups == 0
                || (counts.balancedAccuracy ?? 0) < fit.policy.minimumBalancedAccuracy
            {
                reasons.append(.poorSessionSeparation)
            }
            if (counts.abstentionFraction ?? 1) > fit.policy.maximumAbstentionFraction {
                reasons.append(.excessiveAbstention)
            }
            reasons += targetConfoundReasons(report.context)
        }
        let sessionAccuracies = represented.compactMap { $0.inScopeClassification.balancedAccuracy }
        let range =
            sessionAccuracies.count >= 2
            ? try PersonalTargetInterval(
                lower: sessionAccuracies.min()!, upper: sessionAccuracies.max()!)
            : nil
        var activated: ActivatedPersonalTarget?
        if reasons.isEmpty, let candidate = fit.candidate {
            let model = ActivatedPersonalTarget(
                candidate: candidate, evaluationIdentity: evaluationIdentity)
            guard
                try canonicalContractJSON(model).count
                    <= ActivatedPersonalTarget.maximumEncodedBytes
            else {
                throw PersonalTargetError.capacityExceeded
            }
            activated = model
        }
        return PersonalTargetEvaluation(
            schemaVersion: 1, fitIdentity: fitIdentity, evaluationIdentity: evaluationIdentity,
            recordingEvaluation: recording, sessionEvaluation: session,
            laterSessions: laterSessions,
            observedSessionBalancedAccuracyRange: range, reasons: targetReasons(reasons),
            activated: activated)
    }
}

private struct TargetEvaluationFingerprint: Encodable {
    let fitIdentity: CalibrationDigest
    let records: [CalibrationDigest]
}

private func targetEvaluationReasons(
    _ counts: PersonalTargetClassificationReport, policy: PersonalTargetPolicy
) -> [PersonalTargetReason] {
    var reasons: [PersonalTargetReason] = []
    if counts.preferredGroups < policy.minimumEvaluationGroupsPerClass
        || counts.usualGroups < policy.minimumEvaluationGroupsPerClass
    {
        reasons.append(.insufficientEvaluationGroups)
    }
    if (counts.balancedAccuracy ?? 0) < policy.minimumBalancedAccuracy {
        reasons.append(.poorHeldOutSeparation)
    }
    if (counts.abstentionFraction ?? 1) > policy.maximumAbstentionFraction {
        reasons.append(.excessiveAbstention)
    }
    return reasons
}
