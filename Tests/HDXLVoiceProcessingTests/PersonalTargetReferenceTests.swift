import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct TargetFittingReference: Decodable {
    struct Row: Decodable {
        let id, session: Int
        let role, groupSHA256: String
        let label: CalibrationListeningPreference
        let cpps, pitch, level: Double
    }
    struct Interval: Decodable {
        let lower, upper: Double
    }
    struct ConditionalInterval: Decodable {
        let successes, trials: Int
        let lower, upper: Double
    }
    struct Report: Decodable {
        struct Prediction: Decodable {
            let id: Int
            let predicted: String?
        }
        let counts: [String: Double]
        let predictions: [Prediction]
        let preferredInterval, usualInterval: ConditionalInterval
    }
    struct Case: Decodable {
        let name: String
        let rows: [Row]
        let preferredTraining, usualTraining: [String: Double]
        let preferredInterval, observedCPPS: Interval
        let direction: String
        let reports: [String: Report]
        let activated: Bool
    }
    let schemaVersion: Int
    let syntheticOnly: Bool
    let definition: String
    let cases: [Case]
}

private func targetExpectNumbers<T: Encodable>(
    _ value: T, expected: [String: Double]
) throws {
    let object = try #require(
        JSONSerialization.jsonObject(with: canonicalContractJSON(value)) as? [String: Any])
    for (key, wanted) in expected {
        let actual = try #require(object[key] as? Double)
        #expect(abs(actual - wanted) <= 1e-13, "\(key): \(actual) != \(wanted)")
    }
}

private func targetExpectConditional(
    _ value: PersonalTargetConditionalInterval?,
    expected: TargetFittingReference.ConditionalInterval
) throws {
    let value = try #require(value)
    #expect(value.successes == expected.successes && value.trials == expected.trials)
    #expect(abs(value.lower - expected.lower) <= 1e-14)
    #expect(abs(value.upper - expected.upper) <= 1e-14)
}

@Test func personalTargetFittingAndEvaluationMatchIndependentSyntheticOracle() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let url =
        ProcessInfo.processInfo.environment["HDXL_PERSONAL_TARGET_FITTING_REFERENCE"].map {
            URL(fileURLWithPath: $0)
        }
        ?? root.appending(
            path: "Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets/fitting-reference.json")
    let reference = try JSONDecoder().decode(
        TargetFittingReference.self, from: Data(contentsOf: url))
    #expect(reference.schemaVersion == 1 && reference.syntheticOnly)
    #expect(reference.definition == "independent-personal-cpps-iqr-band-v1")
    #expect(reference.cases.count == 9)
    for item in reference.cases {
        let sessions = try Dictionary(grouping: item.rows, by: \.session).map { session, rows in
            try CalibrationSession(
                id: calibrationTestID(session),
                takes: rows.map { row in
                    try calibrationTestTake(
                        row.id,
                        label: CalibrationListeningLabel(
                            preference: row.label, confidence: 1, exposure: .blindedBeforeFeatures))
                })
        }
        let dataset = try CalibrationDataset(
            id: calibrationTestID(900), revision: 1, sessions: sessions)
        let byID = Dictionary(
            uniqueKeysWithValues: item.rows.map { (calibrationTestID($0.id), $0) })
        let fixture = try TargetTestFixture(dataset: dataset) { member in
            let row = try #require(byID[member.take.id])
            try #require(member.role.rawValue == row.role)
            try #require(member.recordingGroup.sha256 == row.groupSHA256)
            return try targetTestRecord(
                member.take, cpps: row.cpps, pitch: row.pitch, level: row.level)
        }
        let fit = try fixture.fit()
        let candidate = try #require(fit.candidate)
        #expect(candidate.rule.direction.rawValue == item.direction, "\(item.name)")
        #expect(candidate.rule.preferredInterval.lower == item.preferredInterval.lower)
        #expect(candidate.rule.preferredInterval.upper == item.preferredInterval.upper)
        #expect(candidate.rule.observedCPPS.lower == item.observedCPPS.lower)
        #expect(candidate.rule.observedCPPS.upper == item.observedCPPS.upper)
        try targetExpectNumbers(candidate.rule.preferredTraining, expected: item.preferredTraining)
        try targetExpectNumbers(candidate.rule.usualTraining, expected: item.usualTraining)
        let evaluated = try fixture.evaluate(fit)
        #expect(
            (evaluated.activated != nil) == item.activated, "\(item.name): \(evaluated.reasons)")
        for actual in [fit.training, evaluated.recordingEvaluation, evaluated.sessionEvaluation] {
            let expected = try #require(item.reports[actual.role.rawValue])
            try targetExpectNumbers(actual.classification, expected: expected.counts)
            try targetExpectConditional(
                actual.classification.preferredConditionalInterval,
                expected: expected.preferredInterval)
            try targetExpectConditional(
                actual.classification.usualConditionalInterval, expected: expected.usualInterval)
            let predictions = Dictionary(
                uniqueKeysWithValues: expected.predictions.map {
                    (calibrationTestID($0.id), $0.predicted)
                })
            for row in actual.groups {
                #expect(row.group.takes.count == 1)
                let wanted = try #require(predictions[row.group.takes[0].takeID])
                #expect(row.prediction.predicted?.rawValue == wanted)
            }
        }
    }
}

@Test func personalTargetSupportsMaximumDatasetAndKeepsOnlySmallActivatedModel() throws {
    let fixture = try TargetTestFixture(
        dataset: targetTestDataset(sessions: 32, takesPerSession: 16))
    #expect(fixture.dataset.takeCount == 512 && fixture.dataset.sessions.count == 32)
    let fit = try fixture.fit()
    let result = try fixture.evaluate(fit)
    let model = try #require(result.activated)
    #expect(
        fit.training.groups.count + result.recordingEvaluation.groups.count
            + result.sessionEvaluation.groups.count == 512)
    let bytes = try canonicalContractJSON(model)
    #expect(bytes.count < ActivatedPersonalTarget.maximumEncodedBytes)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("test-media-") && !text.contains("analysisIdentity"))
    #expect(
        model.candidate.rule.preferredTraining.count == fit.training.classification.preferredGroups)
}
