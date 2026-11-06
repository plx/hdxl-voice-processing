import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func personalTargetClearSeparationActivatesInspectableSmallImmutableRule() throws {
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    let fit = try fixture.fit()
    #expect(fit.reasons.isEmpty)
    let candidate = try #require(fit.candidate)
    #expect(candidate.rule.preferredInterval == (try PersonalTargetInterval(lower: 10, upper: 10)))
    #expect(candidate.rule.observedCPPS == (try PersonalTargetInterval(lower: 4, upper: 10)))
    #expect(candidate.rule.direction == .usualBelowInterval)
    #expect(candidate.scope.statistic == .selectedIntervalLowerMedianV1)
    #expect(fit.training.classification.balancedAccuracy == 1)
    #expect(fit.training.context.allSatisfy { !$0.possibleConfound })
    let identityBefore = try fit.identity()
    let result = try fixture.evaluate(fit)
    #expect(result.reasons.isEmpty)
    let model = try #require(result.activated)
    #expect(model.candidate == candidate)
    #expect(try fit.identity() == identityBefore)
    #expect(result.laterSessions.count == 2)
    #expect(result.laterSessions.allSatisfy { $0.inScopeClassification.balancedAccuracy == 1 })
    #expect(
        result.observedSessionBalancedAccuracyRange
            == (try PersonalTargetInterval(lower: 1, upper: 1)))
    #expect(try canonicalContractJSON(model).count < ActivatedPersonalTarget.maximumEncodedBytes)
    for member in fixture.partition.sessionEvaluation {
        let observation = try PersonalTargetObservation(
            take: member.take, analysis: #require(fixture.evaluation[member.take.id]))
        let expected: PersonalTargetClass =
            member.take.label?.preference == .preferred ? .preferred : .usual
        #expect(model.prediction(for: observation).predicted == expected)
    }
}

@Test func personalTargetDirectionIsLearnedAndOverlapRefusesActivation() throws {
    let dataset = try targetTestDataset()
    let inverted = try TargetTestFixture(dataset: dataset) {
        try targetTestRecord($0.take, cpps: $0.take.label?.preference == .preferred ? 4 : 10)
    }
    let fit = try inverted.fit()
    #expect(fit.candidate?.rule.direction == .usualAboveInterval)
    #expect(try inverted.evaluate(fit).activated != nil)
    let overlap = try TargetTestFixture(dataset: dataset) { try targetTestRecord($0.take, cpps: 7) }
    let overlapping = try overlap.fit()
    #expect(overlapping.candidate?.rule.direction == .overlapping)
    #expect(overlapping.training.classification.balancedAccuracy == 0.5)
    #expect(overlapping.reasons.contains(.nonSeparatingTraining))
    #expect(try overlap.evaluate(overlapping).activated == nil)
}

@Test func personalTargetQuartilesAreRobustButOutliersRemainErrors() throws {
    let initial = try TargetTestFixture(dataset: targetTestDataset())
    let preferred = initial.partition.fitting.filter { $0.take.label?.preference == .preferred }
    let outlier = try #require(preferred.first?.take)
    var analyses = initial.training
    analyses[outlier.id] = try targetTestRecord(outlier, cpps: 100)
    let fit = try initial.fit(training: analyses)
    #expect(
        fit.candidate?.rule.preferredInterval == (try PersonalTargetInterval(lower: 10, upper: 10)))
    #expect(fit.candidate?.rule.preferredTraining.maximum == 100)
    #expect(fit.candidate?.rule.preferredTraining.count == preferred.count)
    #expect(fit.training.classification.preferredPredictedUsual == 1)
    #expect(fit.training.classification.errorGroups.count == 1)
    #expect(fit.training.classification.abstainedGroups == 0)
    #expect(try initial.evaluate(fit).activated != nil)
}

@Test func personalTargetRejectsLeakageAndHeldoutCannotRetuneFrozenBounds() throws {
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    let fit = try fixture.fit()
    var leakedTraining = fixture.training
    let heldout = try #require(fixture.partition.recordingEvaluation.first?.take)
    leakedTraining[heldout.id] = fixture.evaluation[heldout.id]
    #expect(throws: PersonalTargetError.unexpectedAnalysis) {
        try fixture.fit(training: leakedTraining)
    }
    var leakedEvaluation = fixture.evaluation
    leakedEvaluation[fixture.reference.id] = fixture.training[fixture.reference.id]
    #expect(throws: PersonalTargetError.unexpectedAnalysis) {
        try fixture.evaluate(fit, analyses: leakedEvaluation)
    }
    #expect(throws: PersonalTargetError.referenceNotInTraining) {
        try PersonalTargetFitter.fit(
            dataset: fixture.dataset, split: fixture.split, trainingAnalyses: fixture.training,
            referenceTakeID: heldout.id, validation: fixture.validation,
            policy: PersonalTargetPolicy())
    }
    var shifted = fixture.evaluation
    for member in fixture.partition.recordingEvaluation + fixture.partition.sessionEvaluation {
        shifted[member.take.id] = try targetTestRecord(member.take, cpps: 50)
    }
    let failed = try fixture.evaluate(fit, analyses: shifted)
    #expect(failed.activated == nil)
    #expect(failed.reasons.contains(.poorHeldOutSeparation))
    #expect(failed.recordingEvaluation.classification.classifiedGroups == 0)
    #expect(fit.candidate?.rule.preferredInterval.upper == 10)
    let revised = try targetTestRevised(fixture.dataset) { take in
        if take.id != heldout.id { return take }
        return try take.replacingLabel(
            CalibrationListeningLabel(preference: .uncertain, exposure: .blindedBeforeFeatures))
    }
    let next = try TargetTestFixture(dataset: revised)
    let newFit = try next.fit()
    #expect(newFit.trainingIdentity == fit.trainingIdentity)
    #expect(newFit.candidate?.rule == fit.candidate?.rule)
    #expect(newFit.datasetIdentity != fit.datasetIdentity)
    #expect(try newFit.identity() != fit.identity())
    #expect(throws: PersonalTargetError.incompatibleDataset) { try next.evaluate(fit) }
}
