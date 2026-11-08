import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func sessionCalibrationReader(_ bytes: Data, recover: Bool = false) throws
    -> SessionArchiveReader
{
    var offset = 0
    return try SessionArchiveReader(
        limits: SessionArchiveLimits(),
        recovery: recover ? .inspectCompletePrefix : .requireComplete
    ) { n in
        let bytes = Data(bytes.dropFirst(offset).prefix(min(n, 997)))
        offset += bytes.count
        return bytes
    }
}

private func sessionCalibrationArchive(
    _ fixture: TargetTestFixture, fit: PersonalTargetFit,
    evaluation: PersonalTargetEvaluation, completion: SessionArchiveCompletion = .completed,
    claimedEvaluationIdentity: CalibrationDigest? = nil
) throws -> (complete: Data, prefix: Data) {
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionTestHeader(), limits: SessionArchiveLimits()
    ) { bytes.append($0) }
    try writer.addCalibrationDataset(fixture.dataset)
    try writer.addCalibrationSplit(
        SessionArchiveCalibrationSplit(datasetIndex: 0, plan: fixture.split))
    let analyses = fixture.training.merging(fixture.evaluation) { _, _ in
        preconditionFailure("Partitions overlap")
    }
    for id in analyses.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        try writer.addCalibrationAnalysis(
            SessionArchiveCalibrationAnalysis(datasetIndex: 0, takeID: id, record: analyses[id]!))
    }
    let target = try SessionArchiveTarget(
        datasetIndex: 0, splitIndex: 0, candidate: #require(fit.candidate),
        validation: fit.validation,
        claimedEvaluationIdentity: claimedEvaluationIdentity ?? evaluation.evaluationIdentity)
    try writer.addTarget(target)
    let prefix = bytes
    try writer.finish(completion)
    return (bytes, prefix)
}

@Test func sessionCalibrationRoundTripRetainsLabelsSplitsAnalysesAndInspectOnlyTarget() throws {
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    let fit = try fixture.fit()
    let evaluated = try fixture.evaluate(fit)
    let bytes = try sessionCalibrationArchive(fixture, fit: fit, evaluation: evaluated)
    let reader = try sessionCalibrationReader(bytes.complete)
    #expect(throws: SessionArchiveError.activationRefused) {
        _ = try reader.activateTarget(
            at: 0, currentProfile: fixture.reference.profile, verifiedEvaluation: evaluated)
    }
    var targets = 0
    var analyses = 0
    while let event = try reader.next() {
        switch event {
        case .target(let index, let target):
            #expect(index == 0 && target.candidate == fit.candidate)
            #expect(reader.seal == nil)
            #expect(
                try target.compatibility(with: fixture.reference.profile)
                    == .requiresVerifiedEvaluation)
            targets += 1
        case .calibrationAnalysis(_, let record):
            #expect(
                record.record == fixture.training[record.takeID]
                    ?? fixture.evaluation[record.takeID])
            analyses += 1
        default: break
        }
    }
    #expect(targets == 1 && analyses == fixture.dataset.takeCount)
    #expect(try reader.calibrationDataset(at: 0) == fixture.dataset)
    #expect(try reader.calibrationSplit(at: 0).plan == fixture.split)
    #expect(reader.statistics.catalogEntries == fixture.dataset.takeCount + 4)
    let model = try reader.activateTarget(
        at: 0, currentProfile: fixture.reference.profile, verifiedEvaluation: evaluated)
    #expect(model == evaluated.activated)
    #expect(try model.identity() == evaluated.activated?.identity())
    let otherProfile = try AnalysisScheduleProfile(
        inputFormat: fixture.reference.profile.inputFormat,
        channels: fixture.reference.profile.channels, levels: fixture.reference.profile.levels)
    #expect(try reader.target(at: 0).compatibility(with: otherProfile) == .differentProfile)
    #expect(throws: SessionArchiveError.activationRefused) {
        _ = try reader.activateTarget(
            at: 0, currentProfile: otherProfile, verifiedEvaluation: evaluated)
    }
}

@Test func sessionCalibrationActivationRefusesIncompletePartialAndChangedEvaluation() throws {
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    let fit = try fixture.fit()
    let evaluated = try fixture.evaluate(fit)
    for completion in [SessionArchiveCompletion.partial, .cancelled] {
        let bytes = try sessionCalibrationArchive(
            fixture, fit: fit, evaluation: evaluated, completion: completion)
        let reader = try sessionCalibrationReader(bytes.complete)
        while try reader.next() != nil {}
        #expect(reader.seal?.completion == completion)
        #expect(throws: SessionArchiveError.activationRefused) {
            _ = try reader.activateTarget(
                at: 0, currentProfile: fixture.reference.profile, verifiedEvaluation: evaluated)
        }
    }
    let bytes = try sessionCalibrationArchive(fixture, fit: fit, evaluation: evaluated)
    let incomplete = try sessionCalibrationReader(bytes.prefix, recover: true)
    while try incomplete.next() != nil {}
    #expect(incomplete.isIncomplete && incomplete.seal == nil)
    #expect(try incomplete.target(at: 0).candidate == fit.candidate)
    #expect(throws: SessionArchiveError.activationRefused) {
        _ = try incomplete.activateTarget(
            at: 0, currentProfile: fixture.reference.profile, verifiedEvaluation: evaluated)
    }
    let alternate = try TargetTestFixture(dataset: fixture.dataset) {
        try targetTestRecord($0.take, cpps: $0.take.label?.preference == .preferred ? 11 : 3)
    }
    let otherEvaluation = try alternate.evaluate(alternate.fit())
    #expect(otherEvaluation.activated != nil)
    let complete = try sessionCalibrationReader(bytes.complete)
    while try complete.next() != nil {}
    #expect(throws: SessionArchiveError.activationRefused) {
        _ = try complete.activateTarget(
            at: 0, currentProfile: fixture.reference.profile, verifiedEvaluation: otherEvaluation)
    }
    let forged = try sessionCalibrationArchive(
        fixture, fit: fit, evaluation: evaluated,
        claimedEvaluationIdentity: CalibrationDigest(sha256: String(repeating: "0", count: 64)))
    let claimed = try sessionCalibrationReader(forged.complete)
    while try claimed.next() != nil {}
    #expect(throws: SessionArchiveError.activationRefused) {
        _ = try claimed.activateTarget(
            at: 0, currentProfile: fixture.reference.profile, verifiedEvaluation: evaluated)
    }
}

@Test func sessionCalibrationRejectsUnboundReferencesAndDuplicateRecordsWithoutWritingThem() throws
{
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    let fit = try fixture.fit()
    let evaluated = try fixture.evaluate(fit)
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionTestHeader(), limits: SessionArchiveLimits()
    ) { bytes.append($0) }
    let split = SessionArchiveCalibrationSplit(datasetIndex: 0, plan: fixture.split)
    let before = bytes
    #expect(throws: SessionArchiveError.outOfOrder) { try writer.addCalibrationSplit(split) }
    #expect(bytes == before)
    try writer.addCalibrationDataset(fixture.dataset)
    #expect(throws: SessionArchiveError.duplicateIdentity) {
        try writer.addCalibrationDataset(fixture.dataset)
    }
    try writer.addCalibrationSplit(split)
    #expect(throws: SessionArchiveError.duplicateIdentity) { try writer.addCalibrationSplit(split) }
    let first = try #require(fixture.training.first)
    let analysis = SessionArchiveCalibrationAnalysis(
        datasetIndex: 0, takeID: first.key, record: first.value)
    try writer.addCalibrationAnalysis(analysis)
    #expect(throws: SessionArchiveError.duplicateIdentity) {
        try writer.addCalibrationAnalysis(analysis)
    }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        try writer.addCalibrationAnalysis(
            SessionArchiveCalibrationAnalysis(
                datasetIndex: 0, takeID: calibrationTestID(99999), record: first.value))
    }
    let target = try SessionArchiveTarget(
        datasetIndex: 0, splitIndex: 0, target: #require(evaluated.activated),
        validation: fit.validation)
    try writer.addTarget(target)
    #expect(throws: SessionArchiveError.duplicateIdentity) { try writer.addTarget(target) }
    #expect(writer.statistics.catalogEntries == 5)
    try writer.finish()
    let reader = try sessionCalibrationReader(bytes)
    while try reader.next() != nil {}
    #expect(reader.seal != nil)
}
