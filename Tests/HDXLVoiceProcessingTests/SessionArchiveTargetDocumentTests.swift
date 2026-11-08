import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func sessionTestTargetDocument() throws -> (SessionArchiveTarget, PersonalTargetEvaluation)
{
    // Fabricated summaries and validation receipts test the software trust boundary
    // only. They are not DSP evidence, participant data, or a validated voice model.
    let fixture = try TargetTestFixture(dataset: targetTestDataset())
    let fit = try fixture.fit()
    let evaluation = try fixture.evaluate(fit)
    let target = try #require(evaluation.activated)
    return (
        try SessionArchiveTarget(
            datasetIndex: 0, splitIndex: 0, target: target, validation: fit.validation), evaluation
    )
}

@Test func sessionTargetDocumentPreservesCompleteRuleAndReferenceReceiptWithoutActivation() throws {
    let (document, evaluated) = try sessionTestTargetDocument()
    let bytes = try canonicalContractJSON(document)
    let decoded = try decodeSessionMetadata(SessionArchiveTarget.self, from: bytes)
    #expect(
        decoded == document && decoded.claimedEvaluationIdentity == evaluated.evaluationIdentity)
    #expect(decoded.candidate == evaluated.activated?.candidate)
    #expect(try decoded.candidate.identity() == evaluated.activated?.candidate.identity())
    #expect(try decoded.validationClaim.identity() == decoded.candidate.validationIdentity)
    #expect(decoded.validationClaim.components.count == 3)
    #expect(decoded.candidate.contextRules.count == PersonalTargetContextMetric.allCases.count)
    #expect(try canonicalContractJSON(decoded) == bytes)
    #expect(bytes.count < SessionArchiveTarget.maximumEncodedBytes)
    let proposal = try SessionArchiveTarget(
        datasetIndex: 0, splitIndex: 0, candidate: document.candidate,
        validation: TargetTestFixture(dataset: targetTestDataset()).validation)
    #expect(proposal.claimedEvaluationIdentity == nil)
    #expect(
        try decodeSessionMetadata(SessionArchiveTarget.self, from: canonicalContractJSON(proposal))
            == proposal)
}

@Test func sessionTargetDocumentRejectsUnknownScaleAndMalformedRules() throws {
    let (document, _) = try sessionTestTargetDocument()
    let base = try #require(
        JSONSerialization.jsonObject(with: canonicalContractJSON(document)) as? [String: Any])
    let edits: [(inout [String: Any]) -> Void] = [
        { $0["schemaVersion"] = 2 },
        { $0["activated"] = true },
        { root in
            var c = root["candidate"] as! [String: Any]
            c["schemaVersion"] = 2
            root["candidate"] = c
        },
        { root in
            var c = root["candidate"] as! [String: Any]
            var r = c["rule"] as! [String: Any]
            r["featureScaling"] = "normalized-new-CPPS-scale"
            c["rule"] = r
            root["candidate"] = c
        },
        { root in
            var c = root["candidate"] as! [String: Any]
            var r = c["rule"] as! [String: Any]
            r["statistic"] = "instantaneousFrame"
            c["rule"] = r
            root["candidate"] = c
        },
        { root in
            var c = root["candidate"] as! [String: Any]
            c["calibrationRevision"] = 0
            root["candidate"] = c
        },
        { root in
            var c = root["candidate"] as! [String: Any]
            c["contextRules"] = []
            root["candidate"] = c
        },
        { root in
            var c = root["candidate"] as! [String: Any]
            var p = c["policy"] as! [String: Any]
            p["minimumBalancedAccuracy"] = 0
            c["policy"] = p
            root["candidate"] = c
        },
        { root in
            var c = root["candidate"] as! [String: Any]
            var r = c["rule"] as! [String: Any]
            r["preferredInterval"] = ["lower": 9, "upper": 11]
            c["rule"] = r
            root["candidate"] = c
        },
        { root in
            var c = root["candidate"] as! [String: Any]
            var r = c["rule"] as! [String: Any]
            var d = r["preferredTraining"] as! [String: Any]
            d["count"] = 1
            d["minimum"] = 9
            r["preferredTraining"] = d
            c["rule"] = r
            root["candidate"] = c
        },
        { root in
            var v = root["validationClaim"] as! [String: Any]
            v["components"] = []
            root["validationClaim"] = v
        },
        { root in
            var v = root["validationClaim"] as! [String: Any]
            v["sourceIdentity"] = ["sha256": String(repeating: "0", count: 64)]
            root["validationClaim"] = v
        },
    ]
    for edit in edits {
        var changed = base
        edit(&changed)
        let bytes = try JSONSerialization.data(
            withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(throws: (any Error).self) {
            _ = try decodeSessionMetadata(SessionArchiveTarget.self, from: bytes)
        }
    }
}

@Test func sessionTargetDistributionInspectsOnlyPossibleOrderedEmpiricalSummaries() throws {
    for count in 1...12 {
        let values = (0..<count).map(Double.init)
        let original = try PersonalTargetDistribution(values)
        let decoded = try PersonalTargetDistribution(
            count: count, minimum: original.minimum, lowerQuartile: original.lowerQuartile,
            median: original.median, upperQuartile: original.upperQuartile,
            maximum: original.maximum)
        #expect(decoded == original)
    }
    #expect(throws: PersonalTargetError.invalidObservation) {
        _ = try PersonalTargetDistribution(
            count: 1, minimum: 0, lowerQuartile: 0, median: 1, upperQuartile: 1, maximum: 1)
    }
    #expect(throws: PersonalTargetError.invalidObservation) {
        _ = try PersonalTargetDistribution(
            count: 3, minimum: 0, lowerQuartile: 0, median: .infinity, upperQuartile: .infinity,
            maximum: .infinity)
    }
    #expect(throws: PersonalTargetError.invalidObservation) {
        _ = try PersonalTargetDistribution(
            count: 0, minimum: 0, lowerQuartile: 0, median: 0, upperQuartile: 0, maximum: 0)
    }
}
