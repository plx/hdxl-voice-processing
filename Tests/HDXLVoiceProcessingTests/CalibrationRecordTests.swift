import Foundation
import Testing

@testable import HDXLVoiceProcessing

func calibrationTestID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

func calibrationTestProfile(hop: Int = 160) throws -> AnalysisScheduleProfile {
    try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: PCMChannelSelection(channelIndex: 0),
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64, windowLength: 400, hopLength: hop,
            accumulation: .compensatedSliding, weighting: .none),
        pitch: YINProfile(
            estimator: YINConfiguration(
                sampleRate: 16000, inputPrecision: .float64, pitchFloorHz: 50,
                pitchCeilingHz: 700, hopLength: hop)),
        cpps: CPPSProfile(
            cepstrogram: CepstrogramConfiguration(
                sourceSampleRate: 16000, hopSeconds: 0.01, declaredInputBandwidthHz: 8000,
                conditioningMethod: .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
            settings: CPPSConfiguration(
                timeWindowSeconds: 0.02, prominence: CPPConfiguration(fitMethod: .leastSquares))))
}

func calibrationTestTake(
    _ id: Int, recordingID: Int? = nil, contentID: Int? = nil,
    task: CalibrationTaskCategory = .sustainedVowel,
    label: CalibrationListeningLabel? = nil, source: SourceInterval? = nil,
    exclusions: [CalibrationExclusion] = [], mask: MaskPlan? = nil
) throws -> CalibrationTake {
    try CalibrationTake(
        id: calibrationTestID(id),
        media: CalibrationMediaReference(
            referenceIdentifier: "test-media-\(id)",
            originalRecordingID: calibrationTestID(recordingID ?? id),
            content: CalibrationDigest(bytes: Data("test-audio-\(contentID ?? id)".utf8)),
            byteCount: 10000),
        task: CalibrationTask(
            category: task, promptIdentifier: "prompt-\(task.rawValue)",
            prompt: "原稿 café", languageTag: "ja"),
        repetition: 1, instruction: .preferred, instructionNotes: "Try my preferred delivery",
        label: label,
        source: source
            ?? SourceInterval(
                epoch: StreamEpoch(streamID: calibrationTestID(id)), startSample: 0,
                sampleCount: 3200, sampleRate: 16000),
        exclusions: exclusions,
        conditions: CalibrationRecordingConditions(
            routeIdentifier: "host-route", roomIdentifier: "room-a",
            microphoneDistanceMeters: 0.2, inputGainDB: 0,
            recordingSettings: ["automaticGainControl": .boolean(false)]),
        profile: calibrationTestProfile(), mask: mask)
}

func calibrationTestDataset(_ takes: [CalibrationTake]) throws -> CalibrationDataset {
    try CalibrationDataset(
        id: calibrationTestID(900), revision: 1, notes: "Personal reference, no target",
        sessions: [CalibrationSession(id: calibrationTestID(800), takes: takes)])
}

@Test func calibrationRecordsRoundTripTasksLabelsConditionsAndLargeIntervals() throws {
    let actual = try CalibrationListeningLabel(
        preference: .usual, confidence: 0.7, notes: "I intended preferred but heard usual",
        recordedAtUnixSeconds: 1_800_000_000, exposure: .blindedBeforeFeatures)
    let large = try SourceInterval(
        epoch: StreamEpoch(streamID: calibrationTestID(1), sequence: 9),
        startSample: (1 << 54) + 7, sampleCount: 3200, sampleRate: 16000)
    let exclusion = try CalibrationExclusion(
        source: SourceInterval(
            epoch: large.epoch, startSample: large.startSample + 17,
            sampleCount: 19, sampleRate: 16000),
        kind: .userSelection, reason: "Exclude the lead-in")
    let takes = try CalibrationTaskCategory.allCases.enumerated().map { index, category in
        try calibrationTestTake(
            index + 1, task: category, label: actual,
            source: index == 0 ? large : nil, exclusions: index == 0 ? [exclusion] : [])
    }
    let dataset = try calibrationTestDataset(takes)
    let bytes = try dataset.canonicalJSON()
    let decoded = try CalibrationDataset.decode(bytes)
    #expect(decoded == dataset)
    #expect(try decoded.canonicalJSON() == bytes)
    #expect(try decoded.identity() == dataset.identity())
    #expect(decoded.sessions[0].takes[0].source.startSample == (1 << 54) + 7)
    #expect(decoded.sessions[0].takes[0].exclusions == [exclusion])
    #expect(decoded.sessions[0].takes.allSatisfy { $0.instruction == .preferred })
    #expect(decoded.sessions[0].takes.allSatisfy { $0.label?.preference == .usual })
    #expect(decoded.sessions[0].takes[0].conditions.inputGainDB == 0)
    #expect(decoded.sessions[0].takes[0].task.languageTag == "ja")
    #expect(try decoded.sessions[0].takes[0].profile.identity() == takes[0].profileIdentity)
}

@Test func calibrationCanonicalOrderAndRevisionKeepOriginalDataImmutable() throws {
    let first = try calibrationTestTake(1)
    let second = try calibrationTestTake(2)
    let left = try calibrationTestDataset([first, second])
    let reversed = try calibrationTestDataset([second, first])
    #expect(try left.canonicalJSON() == reversed.canonicalJSON())
    let initialIdentity = try left.identity()
    let label = try CalibrationListeningLabel(preference: .other, exposure: .unknown)
    let revisedTake = try first.replacingLabel(label)
    let revised = try left.revised(sessions: [
        CalibrationSession(id: left.sessions[0].id, takes: [revisedTake, second])
    ])
    #expect(revised.revision == 2)
    #expect(revised.id == left.id)
    #expect(left.sessions[0].takes[0].label == nil)
    #expect(try left.identity() == initialIdentity)
    #expect(try revised.identity() != initialIdentity)
    let exhausted = try CalibrationDataset(id: left.id, revision: .max, sessions: left.sessions)
    #expect(throws: CalibrationError.arithmeticOverflow) {
        try exhausted.revised(sessions: exhausted.sessions)
    }
}

@Test func calibrationDecodeRejectsUnknownFieldsStaleProfilesAndOversizeInput() throws {
    let dataset = try calibrationTestDataset([calibrationTestTake(1)])
    let bytes = try dataset.canonicalJSON()
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["schemaVersion"] = 2
    #expect(throws: ContractError.unsupportedSchemaVersion(2)) {
        try CalibrationDataset.decode(JSONSerialization.data(withJSONObject: object))
    }
    object["schemaVersion"] = 1
    var sessions = try #require(object["sessions"] as? [[String: Any]])
    var takes = try #require(sessions[0]["takes"] as? [[String: Any]])
    var identity = try #require(takes[0]["profileIdentity"] as? [String: Any])
    identity["sha256"] = String(repeating: "0", count: 64)
    takes[0]["profileIdentity"] = identity
    sessions[0]["takes"] = takes
    object["sessions"] = sessions
    #expect(throws: ContractError.invalidFingerprint) {
        try CalibrationDataset.decode(JSONSerialization.data(withJSONObject: object))
    }
    object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    sessions = try #require(object["sessions"] as? [[String: Any]])
    takes = try #require(sessions[0]["takes"] as? [[String: Any]])
    var conditions = try #require(takes[0]["conditions"] as? [String: Any])
    conditions["silentlyIgnoredRecordingSetting"] = true
    takes[0]["conditions"] = conditions
    sessions[0]["takes"] = takes
    object["sessions"] = sessions
    #expect(throws: (any Error).self) {
        try CalibrationDataset.decode(JSONSerialization.data(withJSONObject: object))
    }
    #expect(throws: CalibrationError.capacityExceeded) {
        try CalibrationDataset.decode(
            Data(repeating: 32, count: CalibrationRecordLimits.maximumDatasetBytes + 1))
    }
}

@Test func calibrationSelectionComposesMasksAndExclusionsWithoutConflatingEvidence() throws {
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: calibrationTestID(1)), startSample: 0,
        sampleCount: 1000, sampleRate: 16000)
    func interval(_ start: Int64, _ count: Int64) throws -> SourceInterval {
        try SourceInterval(
            epoch: source.epoch, startSample: start, sampleCount: count, sampleRate: 16000)
    }
    let base = try MaskPlan(
        source: source,
        provenances: [
            MaskProvenance(
                kind: .externalAnnotation,
                identifier: VersionedIdentifier(name: "independent-test-selection", version: 1))
        ],
        policy: MaskSelectionPolicy(selectionSources: [0]),
        observations: [
            MaskObservation(
                source: interval(200, 600), provenanceIndex: 0,
                selection: .selected, tags: [.speechDetected]),
            MaskObservation(
                source: interval(250, 250), provenanceIndex: 0,
                tags: [.lowPeriodicityConfidence]),
        ], effectiveDelaySeconds: 0.25)
    let exclusions = try [
        CalibrationExclusion(source: interval(350, 50), kind: .missingAcquisition, reason: "Lost"),
        CalibrationExclusion(
            source: interval(400, 50), kind: .userSelection, reason: "Not selected"),
        CalibrationExclusion(
            source: interval(600, 50), kind: .invalidRecording, reason: "Technical"),
    ]
    let take = try calibrationTestTake(1, source: source, exclusions: exclusions, mask: base)
    let timeline = try MaskTimeline(take.effectiveMaskPlan())
    let selected = (0..<1000).filter {
        (200..<800).contains($0) && !(350..<450).contains($0) && !(600..<650).contains($0)
    }.count
    #expect(timeline.coverage.selectedSampleCount == Int64(selected))
    #expect(timeline.coverage.eligibleSampleCount == 950)
    #expect(timeline.coverage.missingSampleCount == 50)
    #expect(timeline.coverage.tags.first { $0.tag == .speechDetected }?.sampleCount == 600)
    #expect(
        timeline.coverage.tags.first { $0.tag == .lowPeriodicityConfidence }?.sampleCount == 250)
    #expect(timeline.plan.effectiveDelaySeconds == 0.25)
    let excluded = try take.replacingLabel(nil, exclusionReason: "Exclude this whole take")
    let excludedTimeline = try MaskTimeline(excluded.effectiveMaskPlan())
    #expect(excludedTimeline.coverage.selectedSampleCount == 0)
    #expect(excludedTimeline.coverage.missingSampleCount == 50)
    #expect(take.exclusionReason == nil)
}

@Test func calibrationLimitsAndMetadataRejectContradictoryOrNonfiniteRecords() throws {
    #expect(throws: CalibrationError.invalidRecord) {
        try CalibrationRecordingConditions(microphoneDistanceMeters: 0)
    }
    #expect(throws: CalibrationError.invalidRecord) {
        try CalibrationRecordingConditions(inputGainDB: .infinity)
    }
    #expect(throws: ContractError.invalidConfidence) {
        try CalibrationListeningLabel(preference: .preferred, confidence: .nan, exposure: .unknown)
    }
    #expect(throws: ContractError.invalidFingerprint) {
        try CalibrationDigest(sha256: String(repeating: "A", count: 64))
    }
    let take = try calibrationTestTake(1)
    #expect(throws: CalibrationError.capacityExceeded) {
        try CalibrationSession(
            id: calibrationTestID(99),
            takes: Array(repeating: take, count: CalibrationRecordLimits.maximumTakes + 1))
    }
    #expect(throws: CalibrationError.duplicateIdentity) {
        try CalibrationDataset(
            id: calibrationTestID(98), revision: 1,
            sessions: [
                CalibrationSession(id: calibrationTestID(99), takes: [take]),
                CalibrationSession(id: calibrationTestID(100), takes: [take]),
            ])
    }
    let empty = try calibrationTestTake(
        2,
        source: SourceInterval(
            epoch: StreamEpoch(streamID: calibrationTestID(2)), startSample: 0,
            sampleCount: 0, sampleRate: 16000))
    #expect(try MaskTimeline(empty.effectiveMaskPlan()).coverage.selectedSampleCount == 0)
}
