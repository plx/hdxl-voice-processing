import Foundation
import HDXLVoiceProcessing
import Testing

private let fixtureEpoch = StreamEpoch(
    streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

private func golden(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return Data(
        try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            .utf8)
}

private func fixtureProfile() throws -> AnalysisProfile {
    try JSONDecoder().decode(AnalysisProfile.self, from: golden("profile-v1"))
}

@Test func discontinuityRequiresNewEpochAndPreservesUnknownLoss() throws {
    let next = try fixtureEpoch.successor()
    let unknown = try SourceDiscontinuity(
        previousEpoch: fixtureEpoch, nextEpoch: next, reason: .pause)
    #expect(unknown.missingSource == nil)
    let loss = try SourceInterval(
        epoch: fixtureEpoch, startSample: 480, sampleCount: 480, sampleRate: 48_000)
    let gap = try SourceDiscontinuity(
        previousEpoch: fixtureEpoch, nextEpoch: next, reason: .droppedAudio, missingSource: loss)
    #expect(
        try JSONDecoder().decode(SourceDiscontinuity.self, from: JSONEncoder().encode(gap)) == gap)
    #expect(throws: ContractError.invalidInterval) {
        try SourceDiscontinuity(
            previousEpoch: fixtureEpoch, nextEpoch: fixtureEpoch, reason: .profileChange)
    }
    #expect(throws: ContractError.invalidInterval) {
        try SourceDiscontinuity(previousEpoch: fixtureEpoch, nextEpoch: next, reason: .newSource)
    }
}

private func fixtureResult() throws -> MeasurementResult {
    try JSONDecoder().decode(MeasurementResult.self, from: golden("result-v1"))
}

private func changedJSON(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

@Test func goldenProfileAndResultRoundTrip() throws {
    let profile = try fixtureProfile()
    let result = try fixtureResult()
    #expect(try profile.canonicalJSON() == golden("profile-v1"))
    #expect(try result.canonicalJSON() == golden("result-v1"))
    #expect(try profile.identity() == result.profile)
    #expect(result.measurement == profile.measurement)
    #expect(result.timing.coverage == 0.75)
    #expect(result.outcome.estimate?.value == 12.5)
}

@Test func resultCanonicalizationNormalizesEverySignedZero() throws {
    let fixture = try fixtureResult()
    func result(zero: Double) throws -> MeasurementResult {
        let snapshot = try IntermediateSnapshot(
            stage: fixture.profile.identifier, source: fixture.timing.source,
            xUnit: .hertz, yUnit: .normalizedAmplitude, xOrigin: zero, xStep: 1, values: [zero])
        return try MeasurementResult(
            measurement: fixture.measurement, profile: fixture.profile,
            timing: AnalysisTiming(
                source: fixture.timing.source, includedSampleCount: 768,
                sourceStartSeconds: zero, effectiveDelaySeconds: zero),
            outcome: .available(ScalarEstimate(value: zero, confidence: zero)),
            intermediatePolicy: IntermediateOutputPolicy(maximumScalarCount: 1),
            intermediates: [snapshot])
    }
    let positive = try result(zero: 0.0)
    let negative = try result(zero: -0.0)
    #expect(positive == negative)
    #expect(try positive.canonicalJSON() == negative.canonicalJSON())
    let bytes = try negative.canonicalJSON()
    #expect(try JSONDecoder().decode(MeasurementResult.self, from: bytes).canonicalJSON() == bytes)
}

@Test func equivalentUnicodeSettingsHaveIdenticalProfileHashes() throws {
    let original = try golden("profile-v1")
    func profile(text: String) throws -> AnalysisProfile {
        let bytes = try changedJSON(original) { object in
            object["algorithmSettings"] = ["label": ["type": "text", "text": text]]
        }
        return try JSONDecoder().decode(AnalysisProfile.self, from: bytes)
    }
    let composed = try profile(text: "\u{00e9}")
    let decomposed = try profile(text: "e\u{0301}")
    #expect(composed == decomposed)
    #expect(try composed.canonicalJSON() == decomposed.canonicalJSON())
    #expect(try composed.identity() == decomposed.identity())
}

@Test func profileIdentityIgnoresDictionaryInsertionOrder() throws {
    let profile = try fixtureProfile()
    let reversed = try AnalysisProfile(
        identifier: profile.identifier, measurement: profile.measurement,
        inputFormat: profile.inputFormat,
        channels: profile.channels, precision: profile.precision, frameLength: profile.frameLength,
        hopLength: profile.hopLength, analysisSampleRate: profile.analysisSampleRate,
        window: profile.window,
        preprocessing: Dictionary(
            uniqueKeysWithValues: profile.preprocessing.sorted { $0.key > $1.key }),
        algorithmSettings: Dictionary(
            uniqueKeysWithValues: profile.algorithmSettings.sorted { $0.key > $1.key }),
        partialWindowPolicy: profile.partialWindowPolicy)
    #expect(try profile.identity() == reversed.identity())
}

@Test(arguments: [
    "identifier", "measurement", "inputFormat", "channels", "precision", "frameLength",
    "hopLength", "analysisSampleRate", "window", "preprocessing", "algorithmSettings",
    "partialWindowPolicy",
])
func allProfileDimensionsAffectIdentity(field: String) throws {
    let source = try golden("profile-v1")
    let changed = try changedJSON(source) { object in
        switch field {
        case "identifier", "window":
            var nested = object[field] as! [String: Any]
            nested["version"] = 2
            object[field] = nested
        case "measurement":
            var nested = object[field] as! [String: Any]
            nested["kind"] = "cpp"
            object[field] = nested
        case "inputFormat":
            var nested = object[field] as! [String: Any]
            nested["encoding"] = "float64"
            object[field] = nested
        case "channels": object[field] = ["channelIndex": NSNull()]
        case "precision": object[field] = "float32"
        case "frameLength": object[field] = 2048
        case "hopLength": object[field] = 240
        case "analysisSampleRate": object[field] = 24000
        case "preprocessing": object[field] = ["preEmphasis": ["type": "real", "real": 0.95]]
        case "algorithmSettings": object[field] = ["pitchFloorHz": ["type": "real", "real": 70]]
        case "partialWindowPolicy": object[field] = "emitUnavailable"
        default: Issue.record("Unexpected fixture field")
        }
    }
    let original = try JSONDecoder().decode(AnalysisProfile.self, from: source)
    let modified = try JSONDecoder().decode(AnalysisProfile.self, from: changed)
    #expect(try original.identity() != modified.identity())
}

@Test func profileSettingsNormalizeNegativeZeroAndPreserveType() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(
        try encoder.encode(ProfileSetting.real(-0.0)) == encoder.encode(ProfileSetting.real(0.0)))
    #expect(try encoder.encode(ProfileSetting.real(1)) != encoder.encode(ProfileSetting.integer(1)))
    #expect(throws: ContractError.invalidConfiguration) {
        try encoder.encode(ProfileSetting.real(.nan))
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            ProfileSetting.self, from: Data(#"{"type":"real","real":1,"integer":1}"#.utf8))
    }
}

@Test(arguments: ["profile-v1", "result-v1"])
func futureVersionsAndUnknownFieldsAreRejected(name: String) throws {
    let data = try golden(name)
    for badData in [
        try changedJSON(data) { $0["schemaVersion"] = 2 },
        try changedJSON(data) { $0["futureField"] = true },
        try changedJSON(data) { $0.removeValue(forKey: "schemaVersion") },
    ] {
        #expect(throws: (any Error).self) {
            if name == "profile-v1" {
                _ = try JSONDecoder().decode(AnalysisProfile.self, from: badData)
            } else {
                _ = try JSONDecoder().decode(MeasurementResult.self, from: badData)
            }
        }
    }
    let nested = try changedJSON(data) { object in
        var measurement = object["measurement"] as! [String: Any]
        measurement["futureUnitReference"] = "unknown"
        object["measurement"] = measurement
    }
    #expect(throws: (any Error).self) {
        if name == "profile-v1" {
            _ = try JSONDecoder().decode(AnalysisProfile.self, from: nested)
        } else {
            _ = try JSONDecoder().decode(MeasurementResult.self, from: nested)
        }
    }
}

@Test(arguments: UnavailabilityReason.allCases)
func unavailableHasNoNumericZero(reason: UnavailabilityReason) throws {
    let source = try fixtureResult()
    let result = try MeasurementResult(
        measurement: source.measurement, profile: source.profile, timing: source.timing,
        outcome: .unavailable(reason))
    #expect(result.outcome.estimate == nil)
    let data = try result.canonicalJSON()
    #expect(!String(decoding: data, as: UTF8.self).contains("\"value\""))
    #expect(try JSONDecoder().decode(MeasurementResult.self, from: data) == result)
}

@Test func invalidNumbersAndConflictingStatusAreRejected() throws {
    for value in [Double.nan, .infinity, -.infinity] {
        #expect(throws: ContractError.invalidValue) { try ScalarEstimate(value: value) }
    }
    for confidence in [Double.nan, -.infinity, -0.1, 1.1] {
        #expect(throws: ContractError.invalidConfidence) {
            try ScalarEstimate(value: 0, confidence: confidence)
        }
    }
    #expect(try ScalarEstimate(value: 0).value == 0)
    for payload in [
        #"{"status":"unavailable","reason":"silence","estimate":{"value":0,"warnings":[]}}"#,
        #"{"status":"available","estimate":{"value":0,"warnings":[]},"reason":"silence"}"#,
        #"{"status":"available"}"#,
        #"{"status":"unavailable","reason":"futureReason"}"#,
    ] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MeasurementOutcome.self, from: Data(payload.utf8))
        }
    }
}

@Test func unitsAndNumericalDefinitionsRemainDistinct() throws {
    let algorithm = try VersionedIdentifier(name: "fixture", version: 1)
    #expect(throws: ContractError.invalidUnit) {
        try MeasurementDescriptor(kind: .cpps, unit: .decibelsFullScale, algorithm: algorithm)
    }
    #expect(throws: ContractError.invalidUnit) {
        try MeasurementDescriptor(
            kind: .calibratedSPL, unit: .decibelsFullScale, algorithm: algorithm)
    }
    let fraction = try MeasurementDescriptor(
        kind: .jitterLocal, unit: .fraction, algorithm: algorithm)
    let percent = try MeasurementDescriptor(
        kind: .jitterLocal, unit: .percent, algorithm: algorithm)
    #expect(fraction != percent)
    #expect(
        try JSONDecoder().decode(MeasurementDescriptor.self, from: JSONEncoder().encode(fraction))
            == fraction)
    #expect(!MeasurementKind.cpp.accepts(.percent))
}

@Test func longStreamArithmeticAndOverflow() throws {
    let source = try SourceInterval(
        epoch: fixtureEpoch, startSample: Int64.max - 2048, sampleCount: 1024, sampleRate: 48_000)
    let timing = try AnalysisTiming(source: source, includedSampleCount: 768)
    #expect(source.endSample == Int64.max - 1024)
    #expect(source.durationSeconds == 1024.0 / 48_000)
    #expect(timing.includedDurationSeconds == 768.0 / 48_000)
    #expect(timing.excludedDurationSeconds == 256.0 / 48_000)
    #expect(timing.coverage == 0.75)
    #expect(throws: ContractError.arithmeticOverflow) {
        try SourceInterval(
            epoch: fixtureEpoch, startSample: .max, sampleCount: 1, sampleRate: 48_000)
    }
    #expect(throws: ContractError.invalidInterval) {
        try SourceInterval(epoch: fixtureEpoch, startSample: -1, sampleCount: 0, sampleRate: 48_000)
    }
    #expect(throws: ContractError.invalidInterval) {
        try SourceInterval(
            epoch: fixtureEpoch, startSample: 0, sampleCount: 1, sampleRate: .leastNonzeroMagnitude)
    }
    #expect(throws: ContractError.arithmeticOverflow) {
        try StreamEpoch(streamID: fixtureEpoch.streamID, sequence: .max).successor()
    }
    #expect(try fixtureEpoch.successor().sequence == 1)
}

@Test func sourceDisplayAndCompletionClocksAreIndependent() throws {
    let interval = try SourceInterval(
        epoch: fixtureEpoch, startSample: 960, sampleCount: 480, sampleRate: 48_000)
    let timing = try AnalysisTiming(
        source: interval, includedSampleCount: 240, sourceStartSeconds: 10,
        hostStartNanoseconds: 1_000, completedHostNanoseconds: 1_000_000_000,
        effectiveDelaySeconds: 0.02)
    #expect(timing.displayTimeSeconds == 10.005)
    #expect(timing.measuredWindowSamples == 480)
    #expect(timing.excludedSampleCount == 240)
    #expect(throws: ContractError.invalidTiming) {
        try AnalysisTiming(
            source: interval, includedSampleCount: 1, hostStartNanoseconds: 2,
            completedHostNanoseconds: 1)
    }
    #expect(throws: ContractError.invalidCoverage) {
        try AnalysisTiming(source: interval, includedSampleCount: 481)
    }
    #expect(throws: ContractError.invalidTiming) {
        try AnalysisTiming(
            source: interval, includedSampleCount: 1, effectiveDelaySeconds: -.infinity)
    }
    let empty = try SourceInterval(
        epoch: fixtureEpoch, startSample: 0, sampleCount: 0, sampleRate: 48_000)
    let emptyTiming = try AnalysisTiming(source: empty, includedSampleCount: 0)
    #expect(emptyTiming.coverage == 0)
    let fixture = try fixtureResult()
    #expect(throws: ContractError.invalidCoverage) {
        try MeasurementResult(
            measurement: fixture.measurement, profile: fixture.profile, timing: emptyTiming,
            outcome: .available(ScalarEstimate(value: 0)))
    }
}

@Test func decodingCannotBypassValidation() throws {
    for payload in [
        #"{"sampleRate":0,"channelCount":1,"encoding":"float32","layout":"interleaved"}"#,
        #"{"sampleRate":48000,"channelCount":0,"encoding":"float32","layout":"interleaved"}"#,
        #"{"sampleRate":48000,"channelCount":1,"encoding":"future","layout":"interleaved"}"#,
    ] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PCMFormat.self, from: Data(payload.utf8))
        }
    }
    let data = try golden("profile-v1")
    for bad in [
        try changedJSON(data) { $0["frameLength"] = 0 },
        try changedJSON(data) { $0["hopLength"] = -1 },
        try changedJSON(data) { $0["channels"] = ["channelIndex": 2] },
        try changedJSON(data) { $0["analysisSampleRate"] = 0 },
        try changedJSON(data) {
            $0["preprocessing"] = ["bad key": ["type": "boolean", "boolean": true]]
        },
    ] {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AnalysisProfile.self, from: bad)
        }
    }
}

@Test func intermediateBudgetIsSharedAndSnapshotsOwnTheirValues() async throws {
    let source = try fixtureResult()
    let stage = try VersionedIdentifier(name: "spectrum", version: 1)
    var values = [1.0, 2.0]
    let snapshot = try IntermediateSnapshot(
        stage: stage, source: source.timing.source, xUnit: .hertz,
        yUnit: .normalizedSquaredAmplitude,
        xOrigin: 0, xStep: 100, values: values)
    values[0] = 999
    #expect(snapshot.values[0] == 1)
    #expect(throws: ContractError.intermediateBudgetExceeded) {
        try MeasurementResult(
            measurement: source.measurement, profile: source.profile, timing: source.timing,
            outcome: source.outcome, intermediates: [snapshot])
    }
    let policy = try IntermediateOutputPolicy(maximumScalarCount: 3)
    #expect(throws: ContractError.intermediateBudgetExceeded) {
        try MeasurementResult(
            measurement: source.measurement, profile: source.profile, timing: source.timing,
            outcome: source.outcome, intermediatePolicy: policy,
            intermediates: [snapshot, snapshot])
    }
    let result = try MeasurementResult(
        measurement: source.measurement, profile: source.profile, timing: source.timing,
        outcome: source.outcome, intermediatePolicy: policy, intermediates: [snapshot])
    let copied = await Task.detached { result }.value
    #expect(copied == result)
    #expect(
        try JSONDecoder().decode(MeasurementResult.self, from: result.canonicalJSON()) == result)
    #expect(try fixtureResult().intermediates.isEmpty)
    #expect(throws: ContractError.invalidConfiguration) {
        try IntermediateOutputPolicy(maximumScalarCount: .max)
    }
}
