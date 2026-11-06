import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test(arguments: [
    PersonalTargetContextMetric.fundamentalFrequency, .levelDBFS, .selectedFraction,
    .cppsAvailableFraction,
])
func personalTargetContextOnlySeparationBlocksPossibleConfounds(
    _ metric: PersonalTargetContextMetric
) throws {
    let base = try targetTestDataset()
    let dataset = try targetTestRevised(base) { take in
        guard metric == .selectedFraction, take.label?.preference == .usual else { return take }
        return try targetTestCopy(
            take,
            exclusions: [
                CalibrationExclusion(
                    source: SourceInterval(
                        epoch: take.source.epoch, startSample: 0, sampleCount: 800,
                        sampleRate: 16000),
                    kind: .userSelection, reason: "Synthetic coverage association")
            ])
    }
    let fixture = try TargetTestFixture(dataset: dataset) { member in
        let preferred = member.take.label?.preference == .preferred
        return try targetTestRecord(
            member.take,
            pitch: metric == .fundamentalFrequency && !preferred ? 150 : 200,
            level: metric == .levelDBFS && !preferred ? -30 : -20,
            available: metric == .cppsAvailableFraction && !preferred ? 6 : 8,
            unavailable: metric == .cppsAvailableFraction && !preferred ? 2 : 0)
    }
    let fit = try fixture.fit()
    let reason: PersonalTargetReason
    switch metric {
    case .fundamentalFrequency: reason = .possiblePitchConfound
    case .levelDBFS: reason = .possibleLevelConfound
    case .selectedFraction: reason = .possibleCoverageConfound
    default: reason = .possibleAvailabilityConfound
    }
    #expect(fit.training.classification.balancedAccuracy == 1)
    #expect(fit.reasons.contains(reason))
    #expect(
        fit.training.context.first { $0.metric == metric }?.classification.balancedAccuracy == 1)
    let evaluation = try fixture.evaluate(fit)
    #expect(evaluation.activated == nil)
    #expect(evaluation.reasons.contains(reason))
    #expect(
        evaluation.recordingEvaluation.context.first { $0.metric == metric }?.possibleConfound
            == true)
}

@Test func personalTargetReportsRouteShiftWithoutCountingItAsSuccessfulSessionEvidence() throws {
    let base = try targetTestDataset()
    let movedIDs = Set(base.sessions.last!.takes.map(\.id))
    let revised = try targetTestRevised(base) { take in
        guard movedIDs.contains(take.id) else { return take }
        return try targetTestCopy(
            take,
            conditions: CalibrationRecordingConditions(
                routeIdentifier: "different-mic", roomIdentifier: "room-a",
                microphoneDistanceMeters: 0.2, inputGainDB: 0,
                recordingSettings: ["automaticGainControl": .boolean(false)]))
    }
    let fixture = try TargetTestFixture(dataset: revised)
    let result = try fixture.evaluate(fixture.fit())
    #expect(result.sessionEvaluation.classification.totalGroups == 32)
    #expect(result.sessionEvaluation.classification.abstainedGroups == 16)
    #expect(result.sessionEvaluation.inScopeClassification.totalGroups == 16)
    #expect(result.sessionEvaluation.outOfScopeGroupIDs.count == 16)
    #expect(result.reasons.contains(.insufficientLaterSessions))
    #expect(result.activated == nil)
    #expect(
        result.sessionEvaluation.groups.filter { !$0.group.isInScope }.allSatisfy {
            $0.prediction.reasons.contains(.changedConditions)
        })
}

@Test func personalTargetNovelWordingIsExplicitlyOutsidePreselectedCohort() throws {
    let base = try TargetTestFixture(dataset: targetTestDataset())
    let different = try #require(base.partition.recordingEvaluation.first?.take)
    let dataset = try targetTestRevised(base.dataset) { take in
        guard take.id == different.id else { return take }
        return try targetTestCopy(
            take,
            task: CalibrationTask(
                category: take.task.category, promptIdentifier: "unseen-prompt",
                prompt: "New wording", languageTag: "en"))
    }
    let fixture = try TargetTestFixture(dataset: dataset)
    let result = try fixture.evaluate(fixture.fit())
    #expect(result.recordingEvaluation.outOfScopeGroupIDs.count == 1)
    #expect(result.recordingEvaluation.classification.abstainedGroups == 1)
    #expect(result.recordingEvaluation.inScopeClassification.abstainedGroups == 0)
    #expect(result.activated != nil)
    let row = try #require(
        result.recordingEvaluation.groups.first {
            $0.group.takes.contains { $0.takeID == different.id }
        })
    #expect(row.prediction.reasons.contains(.differentTask))
}

@Test func personalTargetMissingAndUncertainDataStayInActivationDenominators() throws {
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    let fit = try fixture.fit()
    let empty = try fixture.evaluate(fit, analyses: [:])
    #expect(
        empty.recordingEvaluation.inScopeClassification.totalGroups
            == fixture.partition.recordingEvaluation.count)
    #expect(empty.recordingEvaluation.inScopeClassification.classifiedGroups == 0)
    #expect(empty.recordingEvaluation.outOfScopeGroupIDs.isEmpty)
    #expect(empty.reasons.contains(.excessiveAbstention))
    #expect(empty.activated == nil)
    let preferredIDs = Set(
        fixture.partition.sessionEvaluation.filter {
            $0.take.label?.preference == .preferred
        }.map { $0.take.id })
    let revised = try targetTestRevised(fixture.dataset) { take in
        guard preferredIDs.contains(take.id) else { return take }
        return try take.replacingLabel(
            CalibrationListeningLabel(preference: .uncertain, exposure: .blindedBeforeFeatures))
    }
    let uncertain = try TargetTestFixture(dataset: revised)
    let result = try uncertain.evaluate(uncertain.fit())
    #expect(result.sessionEvaluation.inScopeClassification.unknownLabelGroups == preferredIDs.count)
    #expect(result.sessionEvaluation.inScopeClassification.abstainedGroups == preferredIDs.count)
    #expect(result.reasons.contains(.insufficientEvaluationGroups))
    #expect(result.activated == nil)
}

@Test func personalTargetPredictionEnforcesProfileScopeAndObservedSupport() throws {
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    let model = try #require(fixture.evaluate(fixture.fit()).activated)
    let take = fixture.reference
    let changed = try targetTestCopy(take, profile: calibrationTestProfile(hop: 80))
    let wrongProfile = try PersonalTargetObservation(
        take: changed, analysis: targetTestRecord(changed))
    #expect(model.prediction(for: wrongProfile).reasons.contains(.differentProfile))
    let shifted = try PersonalTargetObservation(
        take: take, analysis: targetTestRecord(take, cpps: 100, pitch: 400, level: -6))
    #expect(model.prediction(for: shifted).predicted == nil)
    #expect(
        Set(model.prediction(for: shifted).reasons) == [
            .outsideObservedCPPS, .outsideObservedPitch, .outsideObservedLevel,
        ])
    let unknown = try targetTestCopy(take, conditions: CalibrationRecordingConditions())
    let observation = try PersonalTargetObservation(
        take: unknown, analysis: targetTestRecord(unknown))
    #expect(model.prediction(for: observation).reasons.contains(.unknownConditions))
}
