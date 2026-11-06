import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func calibrationBlindedLabelingSeparatesPresenterAndControllerUntilCompletion() throws {
    let original = try calibrationTestDataset([
        calibrationTestTake(1), calibrationTestTake(2), calibrationTestTake(3),
    ])
    let initialIdentity = try original.identity()
    let workflow = try CalibrationLabelingSession(dataset: original, shuffleSeed: 47)
    #expect(workflow.completedCount == 0)
    #expect(!workflow.isComplete)
    #expect(throws: CalibrationError.missingLabels) { try workflow.complete() }

    let projection = try JSONEncoder().encode(workflow.items)
    let rows = try #require(JSONSerialization.jsonObject(with: projection) as? [[String: Any]])
    #expect(rows.count == 3)
    for (index, row) in rows.enumerated() {
        #expect(Set(row.keys) == ["token", "ordinal"])
        #expect(row["ordinal"] as? Int == index + 1)
    }
    let text = String(decoding: projection, as: UTF8.self)
    for secret in [
        "preferred", "usual", "test-media", "profile", "source", "Try my preferred delivery",
    ] {
        #expect(!text.contains(secret))
    }
    for item in workflow.items {
        let media = try workflow.replayMedia(for: item.token)
        switch media.media.referenceIdentifier {
        case "test-media-1":
            try workflow.submit(
                item.token, preference: .usual, confidence: 0.8, notes: "Heard usual")
        case "test-media-2":
            try workflow.submit(item.token, preference: .uncertain)
            try workflow.submit(
                item.token, preference: .preferred, notes: "Changed while listening")
        case "test-media-3":
            try workflow.exclude(item.token, reason: "Media is unavailable")
        default: Issue.record("Unexpected controller media")
        }
    }
    #expect(workflow.completedCount == 3)
    let completed = try workflow.complete()
    #expect(workflow.isComplete)
    #expect(try workflow.complete() == completed)
    #expect(completed.revision == 2)
    #expect(completed.sessions[0].takes[0].instruction == .preferred)
    #expect(completed.sessions[0].takes[0].label?.preference == .usual)
    #expect(completed.sessions[0].takes[0].label?.exposure == .blindedBeforeFeatures)
    #expect(completed.sessions[0].takes[1].label?.preference == .preferred)
    #expect(completed.sessions[0].takes[2].label == nil)
    #expect(completed.sessions[0].takes[2].exclusionReason == "Media is unavailable")
    #expect(try original.identity() == initialIdentity)
    #expect(original.sessions[0].takes.allSatisfy { $0.label == nil && $0.exclusionReason == nil })
    #expect(throws: CalibrationError.invalidState) {
        try workflow.submit(workflow.items[0].token, preference: .other)
    }
    #expect(throws: CalibrationError.invalidState) {
        try workflow.exclude(workflow.items[0].token, reason: "Late edit")
    }
}

@Test func calibrationReplayOrderIsReproducibleAndBadSubmissionsDoNotAdvanceIt() throws {
    let takes = try (1...12).map { try calibrationTestTake($0) }
    let original = try calibrationTestDataset(takes)
    let reordered = try calibrationTestDataset(takes.reversed())
    let first = try CalibrationLabelingSession(dataset: original, shuffleSeed: 47)
    let same = try CalibrationLabelingSession(dataset: reordered, shuffleSeed: 47)
    #expect(first.items == same.items)
    let other = try CalibrationLabelingSession(dataset: original, shuffleSeed: 48)
    #expect(first.items != other.items)
    #expect(throws: CalibrationError.unknownReplay) {
        try first.submit(other.items[0].token, preference: .usual)
    }
    #expect(throws: CalibrationError.unknownReplay) {
        try first.replayMedia(for: other.items[0].token)
    }
    #expect(throws: ContractError.invalidConfidence) {
        try first.submit(first.items[0].token, preference: .preferred, confidence: 2)
    }
    #expect(throws: CalibrationError.invalidRecord) {
        try first.exclude(first.items[0].token, reason: "   ")
    }
    #expect(first.completedCount == 0)
    #expect(throws: CalibrationError.missingLabels) { try first.complete() }
}

private func calibrationSplitFixture(reverse: Bool = false) throws -> CalibrationDataset {
    let first = try (1...20).map { try calibrationTestTake($0) }
    let later = try (21...24).map { try calibrationTestTake($0, task: .novelPassage) }
    let sessions = try [
        CalibrationSession(id: calibrationTestID(801), takes: reverse ? first.reversed() : first),
        CalibrationSession(id: calibrationTestID(802), takes: reverse ? later.reversed() : later),
    ]
    return try CalibrationDataset(
        id: calibrationTestID(900), revision: 1,
        sessions: reverse ? sessions.reversed() : sessions)
}

@Test func calibrationSplitsUseCompleteTakesAndUntouchedLaterSessions() throws {
    let dataset = try calibrationSplitFixture()
    let plan = try CalibrationSplitPlan(
        dataset: dataset, sessionEvaluationIDs: [calibrationTestID(802)],
        recordingEvaluationFraction: 0.5, seed: 47)
    let reordered = try CalibrationSplitPlan(
        dataset: calibrationSplitFixture(reverse: true),
        sessionEvaluationIDs: [calibrationTestID(802)], recordingEvaluationFraction: 0.5, seed: 47)
    #expect(plan == reordered)
    #expect(try plan.canonicalJSON() == reordered.canonicalJSON())
    let partition = try plan.partition(dataset: dataset)
    #expect(partition.sessionEvaluation.count == 4)
    #expect(partition.sessionEvaluation.allSatisfy { $0.sessionID == calibrationTestID(802) })
    #expect(partition.fitting.count + partition.recordingEvaluation.count == 20)
    #expect(!partition.fitting.isEmpty)
    #expect(!partition.recordingEvaluation.isEmpty)
    #expect(partition.fitting.allSatisfy { $0.sessionID == calibrationTestID(801) })
    #expect(partition.recordingEvaluation.allSatisfy { $0.sessionID == calibrationTestID(801) })
    #expect(Set(plan.assignments.map(\.takeID)).count == 24)
    #expect(try CalibrationSplitPlan.decode(plan.canonicalJSON(), for: dataset) == plan)

    for fraction in [0.0, 1.0] {
        let endpoint = try CalibrationSplitPlan(
            dataset: dataset, sessionEvaluationIDs: [calibrationTestID(802)],
            recordingEvaluationFraction: fraction, seed: 47
        ).partition(dataset: dataset)
        #expect(endpoint.sessionEvaluation.count == 4)
        #expect(endpoint.fitting.count == (fraction == 0 ? 20 : 0))
        #expect(endpoint.recordingEvaluation.count == (fraction == 1 ? 20 : 0))
    }
}

@Test func calibrationSplitGroupsAcquisitionsAndDuplicateAudioTransitively() throws {
    // A--B share an acquisition; B--C share bytes under another acquisition ID.
    let a = try calibrationTestTake(1, recordingID: 100, contentID: 201)
    let b = try calibrationTestTake(2, recordingID: 100, contentID: 202)
    let c = try calibrationTestTake(3, recordingID: 101, contentID: 202)
    let independent = try calibrationTestTake(4, recordingID: 102, contentID: 203)
    let together = try calibrationTestDataset([a, b, c, independent])
    let plan = try CalibrationSplitPlan(
        dataset: together, sessionEvaluationIDs: [], recordingEvaluationFraction: 0.5, seed: 47)
    let connected = plan.assignments.filter { $0.takeID != independent.id }
    #expect(Set(connected.map(\.recordingGroup)).count == 1)
    #expect(Set(connected.map(\.role)).count == 1)
    #expect(
        plan.assignments.first { $0.takeID == independent.id }?.recordingGroup
            != connected[0].recordingGroup)

    let crossing = try CalibrationDataset(
        id: calibrationTestID(900), revision: 1,
        sessions: [
            CalibrationSession(id: calibrationTestID(801), takes: [a, b, independent]),
            CalibrationSession(id: calibrationTestID(802), takes: [c]),
        ])
    #expect(throws: CalibrationError.recordingLeakage) {
        try CalibrationSplitPlan(
            dataset: crossing, sessionEvaluationIDs: [calibrationTestID(802)],
            recordingEvaluationFraction: 0.5, seed: 47)
    }
}

@Test func calibrationSplitRejectsChangedEvaluationDataAndForgedAssignments() throws {
    let dataset = try calibrationSplitFixture()
    let plan = try CalibrationSplitPlan(
        dataset: dataset, sessionEvaluationIDs: [calibrationTestID(802)],
        recordingEvaluationFraction: 0, seed: 47)
    let later = dataset.sessions[1]
    var changedTakes = later.takes
    changedTakes[0] = try changedTakes[0].replacingLabel(
        CalibrationListeningLabel(preference: .preferred, exposure: .afterFeatures))
    let changed = try dataset.revised(sessions: [
        dataset.sessions[0], CalibrationSession(id: later.id, takes: changedTakes),
    ])
    #expect(throws: CalibrationError.incompatibleDataset) { try plan.partition(dataset: changed) }
    #expect(try plan.partition(dataset: dataset).sessionEvaluation[0].take.label == nil)

    var object = try #require(
        JSONSerialization.jsonObject(with: plan.canonicalJSON()) as? [String: Any])
    var assignments = try #require(object["assignments"] as? [[String: Any]])
    assignments[0]["role"] = "recordingEvaluation"
    object["assignments"] = assignments
    #expect(throws: CalibrationError.invalidSplit) {
        try CalibrationSplitPlan.decode(
            JSONSerialization.data(withJSONObject: object), for: dataset)
    }
    #expect(throws: CalibrationError.invalidSplit) {
        try CalibrationSplitPlan(
            dataset: dataset, sessionEvaluationIDs: [calibrationTestID(999)],
            recordingEvaluationFraction: 0.5, seed: 47)
    }
    #expect(throws: CalibrationError.invalidSplit) {
        try CalibrationSplitPlan(
            dataset: dataset, sessionEvaluationIDs: [], recordingEvaluationFraction: .nan, seed: 47)
    }
}
