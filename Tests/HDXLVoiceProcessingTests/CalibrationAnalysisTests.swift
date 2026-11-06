import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func calibrationAnalysisTestCopy(
    _ take: CalibrationTake, media: CalibrationMediaReference? = nil,
    conditions: CalibrationRecordingConditions? = nil, source: SourceInterval? = nil,
    profile: AnalysisScheduleProfile? = nil, exclusions: [CalibrationExclusion]? = nil
) throws -> CalibrationTake {
    try CalibrationTake(
        id: take.id, media: media ?? take.media, task: take.task, repetition: take.repetition,
        instruction: take.instruction, label: take.label,
        source: source ?? take.source, exclusions: exclusions ?? take.exclusions,
        conditions: conditions ?? take.conditions, profile: profile ?? take.profile)
}

private func calibrationAnalysisTestDecoder(_ take: CalibrationTake, runtime: String = "test-os-1")
    throws -> CalibrationDecoderProvenance
{
    try CalibrationDecoderProvenance(
        identifier: "independent-test-decoder", runtime: runtime,
        storage: ["format": .text("test-pcm")],
        decodedPCM: take.profile.inputFormat, fileSampleCount: take.source.endSample + 100)
}

private func calibrationAnalysisTestRecord(_ take: CalibrationTake) throws
    -> CalibrationAnalysisRecord
{
    let mask = try PreparedAnalysisMask(
        timeline: MaskTimeline(take.effectiveMaskPlan()), scope: .selected)
    return try CalibrationAnalysisRecord(
        key: CalibrationAnalysisKey(take: take, decoder: calibrationAnalysisTestDecoder(take)),
        coverage: CalibrationCoverage(mask.coverage(of: take.source)),
        summaries: calibrationMetrics(for: take.profile).map {
            try CalibrationMetricSummary(
                metric: $0, values: [8, -3, 2, 5], unavailable: ["insufficientData": 2],
                warnings: ["partialCoverage": 1])
        })
}

@Test func calibrationSummaryUsesDeclaredEmpiricalQuantilesAndKeepsUnavailableSeparate() throws {
    let value = try CalibrationMetricSummary(
        metric: .levelDBFS, values: [8, -3, 2, 5], unavailable: ["silence": 3, "invalidInput": 1],
        warnings: ["clipping": 2])
    #expect(value.availableCount == 4)
    #expect(value.observationCount == 8)
    #expect(value.minimum == -3 && value.lowerQuartile == -3 && value.median == 2)
    #expect(value.upperQuartile == 5 && value.maximum == 8)
    #expect(value.unavailable == ["silence": 3, "invalidInput": 1])
    let empty = try CalibrationMetricSummary(
        metric: .fundamentalFrequency, values: [], unavailable: ["lowConfidence": 4], warnings: [:])
    #expect(empty.median == nil && empty.minimum == nil && empty.maximum == nil)
    #expect(empty.availableCount == 0 && empty.observationCount == 4)
    let bytes = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(CalibrationMetricSummary.self, from: bytes) == value)
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["median"] = 100
    #expect(throws: CalibrationError.invalidRecord) {
        try JSONDecoder().decode(
            CalibrationMetricSummary.self, from: JSONSerialization.data(withJSONObject: object))
    }
    #expect(throws: CalibrationError.invalidRecord) {
        try CalibrationMetricSummary(
            metric: .rms, values: [1], unavailable: ["invented": 1], warnings: [:])
    }
    #expect(throws: CalibrationError.capacityExceeded) {
        try CalibrationMetricSummary(metric: .rms, values: [.nan], unavailable: [:], warnings: [:])
    }
    #expect(throws: CalibrationError.invalidRecord) {
        try CalibrationMetricSummary(
            metric: .rms, values: [1], unavailable: ["silence": 30000], warnings: [:])
    }
}

@Test func calibrationCacheIdentityBindsNumericsButAllowsRelabelingAndReportsConditionChanges()
    throws
{
    let take = try calibrationTestTake(1)
    let record = try calibrationAnalysisTestRecord(take)
    try record.validate(for: take)
    let bytes = try record.canonicalJSON()
    #expect(try CalibrationAnalysisRecord.decode(bytes, for: take) == record)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("test-media-1"))
    let relabeled = try take.replacingLabel(
        CalibrationListeningLabel(preference: .other, exposure: .afterFeatures))
    #expect(try record.key.matches(relabeled))
    let conditions = try CalibrationRecordingConditions(
        routeIdentifier: "different-microphone", roomIdentifier: "different-room",
        microphoneDistanceMeters: 0.4, inputGainDB: 6,
        recordingSettings: ["automaticGainControl": .boolean(true)])
    let changed = try calibrationAnalysisTestCopy(take, conditions: conditions)
    #expect(try record.key.matches(changed))
    let report = try CalibrationTakeAssessment(
        take: changed, reference: take, analysis: record, policy: CalibrationAssessmentPolicy())
    for field in CalibrationConditionField.allCases {
        #expect(report.findings.contains(.changedCondition(field)))
    }
    #expect(report.findings.contains(.missingLabel))
    #expect(!report.findings.contains(.incompatibleAnalysis))
    let newRuntime = try CalibrationAnalysisKey(
        take: take, decoder: calibrationAnalysisTestDecoder(take, runtime: "test-os-2"))
    #expect(newRuntime != record.key)
    #expect(try newRuntime.identity() != record.key.identity())
}

@Test func calibrationCacheRejectsChangedAudioSelectionProfileAndIncompleteSummaries() throws {
    let take = try calibrationTestTake(1)
    let record = try calibrationAnalysisTestRecord(take)
    let media = try CalibrationMediaReference(
        referenceIdentifier: take.media.referenceIdentifier,
        originalRecordingID: take.media.originalRecordingID,
        content: CalibrationDigest(bytes: Data("replacement".utf8)), byteCount: take.media.byteCount
    )
    let shifted = try SourceInterval(
        epoch: take.source.epoch, startSample: 1, sampleCount: take.source.sampleCount - 1,
        sampleRate: take.source.sampleRate)
    let variations = try [
        calibrationAnalysisTestCopy(take, media: media),
        calibrationAnalysisTestCopy(take, source: shifted),
        calibrationAnalysisTestCopy(take, profile: calibrationTestProfile(hop: 80)),
        calibrationAnalysisTestCopy(
            take,
            exclusions: [
                CalibrationExclusion(source: shifted, kind: .userSelection, reason: "removed tail")
            ]),
    ]
    for changed in variations {
        #expect(try !record.key.matches(changed))
        #expect(throws: CalibrationError.incompatibleDataset) { try record.validate(for: changed) }
    }
    let incomplete = try CalibrationAnalysisRecord(
        key: record.key, coverage: record.coverage, summaries: Array(record.summaries.dropLast()))
    #expect(throws: CalibrationError.incompatibleDataset) { try incomplete.validate(for: take) }
    let excluded = try take.replacingLabel(nil, exclusionReason: "Unusable")
    #expect(try !record.key.matches(excluded))
    #expect(throws: CalibrationError.capacityExceeded) {
        try CalibrationAnalysisRecord.decode(
            Data(repeating: 32, count: CalibrationAnalysisRecord.maximumEncodedBytes + 1), for: take
        )
    }
}

@Test func calibrationAssessmentKeepsUnknownsAndInsufficientCoverageExplicit() throws {
    let reference = try calibrationTestTake(1)
    let unknown = try calibrationAnalysisTestCopy(
        reference, conditions: CalibrationRecordingConditions())
    let report = try CalibrationTakeAssessment(
        take: unknown, reference: unknown, policy: CalibrationAssessmentPolicy())
    for field in CalibrationConditionField.allCases {
        #expect(report.findings.contains(.unknownCondition(field)))
        #expect(report.findings.contains(.unknownReferenceCondition(field)))
        #expect(!report.findings.contains(.changedCondition(field)))
    }
    #expect(report.findings.contains(.missingAnalysis))
    let excluded = try reference.replacingLabel(nil, exclusionReason: "Missing media")
    let excludedReport = try CalibrationTakeAssessment(
        take: excluded, policy: CalibrationAssessmentPolicy(minimumSelectedFraction: 0.5))
    #expect(excludedReport.findings.contains(.excluded))
    #expect(excludedReport.findings.contains(.noSelectedAudio))
    #expect(excludedReport.findings.contains(.insufficientCoverage))
    #expect(!excludedReport.findings.contains(.missingLabel))
    #expect(excludedReport.coverage.selected == 0)
    #expect(excludedReport.coverage.eligible == reference.source.sampleCount)
    let record = try calibrationAnalysisTestRecord(reference)
    let threshold = try CalibrationTakeAssessment(
        take: reference, analysis: record,
        policy: CalibrationAssessmentPolicy(minimumAvailableObservations: 5))
    #expect(
        Set(
            threshold.findings.filter {
                if case .insufficientMetricObservations = $0 { return true }
                return false
            }
        ).count == record.summaries.count)
    #expect(throws: CalibrationError.invalidRecord) {
        try CalibrationAssessmentPolicy(minimumSelectedFraction: .nan)
    }
}

@Test func calibrationAccumulatorRefusesOverflowWithoutReturningPartialCache() throws {
    let take = try calibrationTestTake(1)
    let origin = try AnalysisScheduleOrigin(
        source: SourceInterval(
            epoch: take.source.epoch, startSample: 0, sampleCount: 0, sampleRate: 16000),
        continuityEpoch: take.source.epoch)
    let scheduler = try PreparedAnalysisSchedule<Double>(
        profile: take.profile, origin: origin, mode: .finite,
        expectedSampleCount: take.source.sampleCount)
    var collector = try CalibrationSummaryAccumulator(
        profile: take.profile, maximumObservationsPerMetric: 1)
    #expect(collector.reservedValueBytes == 5 * 8)
    var collectionError: CalibrationError?
    let values = (0..<3200).map { 0.2 * sin(2 * .pi * 160 * Double($0) / 16000) }
    _ = try values.withUnsafeBufferPointer {
        try scheduler.processInterleaved($0, interval: take.source) { frame in
            guard collectionError == nil else { return }
            do { try collector.append(frame) } catch {
                collectionError = error as? CalibrationError
            }
        }
    }
    #expect(collectionError == .capacityExceeded)
    #expect(collector.retainedValueCount <= 5)
    let record = try calibrationAnalysisTestRecord(take)
    #expect(throws: CalibrationError.invalidState) {
        try collector.finish(key: record.key, coverage: record.coverage)
    }
}
