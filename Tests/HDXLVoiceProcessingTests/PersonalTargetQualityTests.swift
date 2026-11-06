import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func personalTargetAliasesDoNotMultiplySamplesOrChangeNumericalFit() throws {
    let original = try TargetTestFixture(dataset: targetTestDataset())
    let baseline = try original.fit()
    let source = original.reference
    let aliases = try (1001...1020).map { try targetTestCopy(source, id: calibrationTestID($0)) }
    let dataset = try original.dataset.revised(
        sessions: original.dataset.sessions.map { session in
            try CalibrationSession(
                id: session.id,
                takes: session.takes + (session.takes.contains(source) ? aliases : []))
        })
    let repeated = try TargetTestFixture(dataset: dataset)
    let fit = try repeated.fit()
    #expect(fit.training.classification.totalGroups == baseline.training.classification.totalGroups)
    #expect(fit.candidate?.rule == baseline.candidate?.rule)
    let group = try #require(
        fit.training.groups.first { $0.group.takes.contains { $0.takeID == source.id } })
    #expect(group.group.takes.count == 21)
    #expect(group.group.distinctAnalysisCount == 1)
    #expect(group.group.reasons.isEmpty)
    #expect(
        fit.training.classification.preferredConditionalInterval
            == baseline.training.classification.preferredConditionalInterval)
    var inconsistent = repeated.training
    inconsistent[aliases[0].id] = try targetTestRecord(aliases[0], cpps: 5)
    let rejected = try repeated.fit(training: inconsistent)
    #expect(
        rejected.training.groups.contains { $0.group.reasons.contains(.inconsistentAliasAnalysis) })
    #expect(rejected.training.classification.abstainedGroups == 1)
    let mixed = try targetTestRevised(dataset) { take in
        guard take.id == aliases[0].id else { return take }
        return try take.replacingLabel(
            CalibrationListeningLabel(
                preference: source.label?.preference == .usual ? .preferred : .usual,
                exposure: .blindedBeforeFeatures))
    }
    let mixedFit = try TargetTestFixture(dataset: mixed).fit()
    #expect(mixedFit.training.classification.unknownLabelGroups == 1)
    #expect(
        mixedFit.training.groups.contains { $0.group.reasons.contains(.conflictingGroupLabels) })
}

@Test func personalTargetLowCoverageWarningsAndUnavailableDataCannotBeHidden() throws {
    let base = try TargetTestFixture(dataset: targetTestDataset())
    let preferredIDs = Set(
        base.partition.fitting.filter {
            $0.take.label?.preference == .preferred
        }.map { $0.take.id })
    let dataset = try targetTestRevised(base.dataset) { take in
        guard preferredIDs.contains(take.id) else { return take }
        return try targetTestCopy(
            take,
            exclusions: [
                CalibrationExclusion(
                    source: SourceInterval(
                        epoch: take.source.epoch, startSample: 0, sampleCount: 2400,
                        sampleRate: 16000),
                    kind: .userSelection, reason: "Synthetic low coverage")
            ])
    }
    let low = try TargetTestFixture(dataset: dataset)
    let fit = try low.fit()
    #expect(fit.candidate == nil)
    #expect(fit.reasons.contains(.insufficientTrainingGroups))
    #expect(fit.training.inScopeClassification.preferredGroups == preferredIDs.count)
    #expect(fit.training.inScopeClassification.preferredAbstained == preferredIDs.count)
    #expect(
        fit.training.groups.filter { $0.group.actual == .preferred }.allSatisfy {
            $0.group.takes[0].coverage.selectedFraction == 0.25
                && $0.prediction.reasons.contains(.insufficientCoverage)
        })
    let take = base.reference
    for (record, reason) in try [
        (targetTestRecord(take, available: 2), PersonalTargetReason.insufficientMetricObservations),
        (targetTestRecord(take, available: 3, unavailable: 5), .insufficientMetricAvailability),
        (targetTestRecord(take, warnings: ["lowConfidence": 1]), .untrustedMetricWarnings),
        (targetTestRecord(take, warnings: ["partialCoverage": 3]), .excessiveBoundaryCoverage),
        (targetTestRecord(take, pitch: 0), .invalidMeasurements),
    ] {
        let observation = try PersonalTargetObservation(take: take, analysis: record)
        #expect(try observation.findings(policy: PersonalTargetPolicy()).contains(reason))
        #expect(try observation.values(policy: PersonalTargetPolicy()) == nil)
    }
    let edge = try PersonalTargetObservation(
        take: take, analysis: targetTestRecord(take, warnings: ["partialCoverage": 2]))
    #expect(try edge.findings(policy: PersonalTargetPolicy()).isEmpty)
}

@Test func personalTargetExposedLabelsAndUnknownReferenceConditionsPreventFitting() throws {
    let base = try targetTestDataset()
    let exposed = try targetTestRevised(base) { take in
        try take.replacingLabel(
            CalibrationListeningLabel(preference: take.label!.preference, exposure: .afterFeatures))
    }
    let fit = try TargetTestFixture(dataset: exposed).fit()
    #expect(fit.candidate == nil)
    #expect(
        fit.training.inScopeClassification.abstainedGroups
            == fit.training.classification.totalGroups)
    #expect(
        fit.training.groups.allSatisfy { $0.prediction.reasons.contains(.labelExposedToFeatures) })
    let unknown = try targetTestRevised(base) {
        try targetTestCopy($0, conditions: CalibrationRecordingConditions())
    }
    let missingConditions = try TargetTestFixture(dataset: unknown).fit()
    #expect(missingConditions.candidate == nil)
    #expect(missingConditions.training.inScopeClassification.totalGroups == 0)
    #expect(
        missingConditions.training.groups.allSatisfy {
            $0.prediction.reasons.contains(.unknownConditions)
        })
    let confidence = try targetTestRevised(base) { take in
        try take.replacingLabel(
            CalibrationListeningLabel(
                preference: take.label!.preference, exposure: .blindedBeforeFeatures))
    }
    let unweighted = try TargetTestFixture(dataset: confidence)
    #expect(try unweighted.fit().reasons.isEmpty)
    #expect(
        try unweighted.fit(policy: PersonalTargetPolicy(minimumLabelConfidence: 0.5)).candidate
            == nil)
}

@Test func personalTargetPolicyAndEvidenceRejectInvalidOrUnverifiedProfiles() throws {
    for value in [Double.nan, .infinity, -0.1, 1.1] {
        #expect(throws: PersonalTargetError.invalidConfiguration) {
            try PersonalTargetPolicy(minimumSelectedFraction: value)
        }
    }
    #expect(throws: PersonalTargetError.invalidConfiguration) {
        try PersonalTargetPolicy(minimumTrainingGroupsPerClass: 0)
    }
    #expect(throws: PersonalTargetError.invalidConfiguration) {
        try PersonalTargetPolicy(minimumBalancedAccuracy: 0.5)
    }
    #expect(throws: PersonalTargetError.invalidConfiguration) {
        try PersonalTargetPolicy(maximumAbstentionFraction: 1)
    }
    #expect(throws: PersonalTargetError.invalidConfiguration) {
        try PersonalTargetPolicy(interquartileMultiplier: .infinity)
    }
    #expect(
        try canonicalContractJSON(PersonalTargetPolicy(minimumLabelConfidence: -0.0))
            == canonicalContractJSON(PersonalTargetPolicy(minimumLabelConfidence: 0.0)))
    let profile = try calibrationTestProfile()
    let evidence = try targetTestValidation(profile)
    #expect(throws: PersonalTargetError.invalidValidationEvidence) {
        try PersonalTargetValidationEvidence(
            profile: profile, sourceIdentity: evidence.sourceIdentity,
            components: Array(evidence.components.dropLast()))
    }
    #expect(throws: PersonalTargetError.invalidValidationEvidence) {
        try PersonalTargetMetricValidation(
            metric: .cpps, referenceIdentity: evidence.sourceIdentity,
            reportIdentity: evidence.sourceIdentity,
            referenceCases: 1, chunkComparisons: 1, boundaryCases: 0,
            maximumReferenceErrorToBudget: 0, maximumChunkErrorToBudget: 0,
            maximumBoundaryErrorToBudget: 0)
    }
    #expect(throws: PersonalTargetError.invalidValidationEvidence) {
        try PersonalTargetMetricValidation(
            metric: .cpps, referenceIdentity: evidence.sourceIdentity,
            reportIdentity: evidence.sourceIdentity,
            referenceCases: 1, chunkComparisons: 1, boundaryCases: 1,
            maximumReferenceErrorToBudget: 1.001, maximumChunkErrorToBudget: 0,
            maximumBoundaryErrorToBudget: 0)
    }
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    #expect(throws: PersonalTargetError.invalidValidationEvidence) {
        try PersonalTargetFitter.fit(
            dataset: fixture.dataset, split: fixture.split, trainingAnalyses: fixture.training,
            referenceTakeID: fixture.reference.id,
            validation: targetTestValidation(calibrationTestProfile(hop: 80)),
            policy: PersonalTargetPolicy())
    }
}

@Test func personalTargetNumericalBoundsFailClosedAndEmptyUncertaintyIsAbsent() throws {
    #expect(throws: PersonalTargetError.invalidObservation) {
        try PersonalTargetDistribution([.nan])
    }
    let extreme = try PersonalTargetDistribution([-1e308, -1e308, 1e308, 1e308])
    #expect(throws: PersonalTargetError.invalidObservation) {
        try extreme.preferredInterval(multiplier: 1.5, support: extreme.extent)
    }
    #expect(PersonalTargetConditionalInterval(successes: 0, trials: 0) == nil)
    let empty = PersonalTargetClassificationReport([])
    #expect(empty.balancedAccuracy == nil && empty.classificationCoverage == nil)
    #expect(empty.preferredConditionalInterval == nil && empty.usualConditionalInterval == nil)
    let allCorrect = try #require(PersonalTargetConditionalInterval(successes: 4, trials: 4))
    #expect(abs(allCorrect.lower - 0.5101091635454027) < 1e-14)
    #expect(abs(allCorrect.upper - 1) < 1e-14)
    let split = try #require(PersonalTargetConditionalInterval(successes: 2, trials: 4))
    #expect(abs(split.lower - 0.15003898915214947) < 1e-14)
    #expect(abs(split.upper - 0.8499610108478506) < 1e-14)
    let object = try #require(
        JSONSerialization.jsonObject(with: canonicalContractJSON(split)) as? [String: Any])
    #expect(object["assumption"] as? String == "independent-acquisition-group-outcomes")
}
