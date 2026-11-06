import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func schedulingProfileRejectsMismatchedKernelInput() throws {
    let format = try PCMFormat(sampleRate: 48000, channelCount: 2, encoding: .float32)
    let level = try LevelConfiguration(
        sampleRate: 48000, inputPrecision: .float32, windowLength: 1200, hopLength: 480,
        accumulation: .compensatedSliding, weighting: .none)
    let valid = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean, levels: level)
    #expect(valid.inputPrecision == .float32)
    #expect(throws: AnalysisScheduleError.invalidConfiguration) {
        try AnalysisScheduleProfile(inputFormat: format, channels: .arithmeticMean)
    }
    #expect(throws: AnalysisScheduleError.invalidConfiguration) {
        try AnalysisScheduleProfile(
            inputFormat: format, channels: PCMChannelSelection(channelIndex: 2), levels: level)
    }
    let wrong = try LevelConfiguration(
        sampleRate: 16000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
        accumulation: .direct, weighting: .none)
    #expect(throws: AnalysisScheduleError.invalidConfiguration) {
        try AnalysisScheduleProfile(inputFormat: format, channels: .arithmeticMean, levels: wrong)
    }
    let data = try JSONEncoder().encode(valid)
    #expect(try JSONDecoder().decode(AnalysisScheduleProfile.self, from: data) == valid)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 2
    let future = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ContractError.unsupportedSchemaVersion(2)) {
        try JSONDecoder().decode(AnalysisScheduleProfile.self, from: future)
    }
}

@Test func schedulingProfilesDoNotSubstitutePreviewForWholeInterval() throws {
    let format = try PCMFormat(sampleRate: 48000, channelCount: 1, encoding: .float64)
    let reference = try CPPSProfile.murtonRecipePraat7(
        sourceSampleRate: 48000, declaredInputBandwidthHz: 24000)
    let offline = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean, cpps: reference)
    try offline.validate(mode: .finite)
    #expect(throws: AnalysisScheduleError.unsupportedLiveProfile) {
        try offline.validate(mode: .continuous)
    }
    let preview = try CPPSProfile(
        cepstrogram: CepstrogramConfiguration(
            sourceSampleRate: 48000, declaredInputBandwidthHz: 24000,
            conditioningMethod: .streamingPreview(lobes: 32, cutoffFraction: 0.9)),
        settings: .murtonRecipePraat7())
    let online = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean, cpps: preview)
    try online.validate(mode: .continuous)
    #expect(try online.identity() != offline.identity())
    let temporal = try #require(online.requirements().first)
    #expect(temporal.analysisSampleRate == 10000)
    #expect(abs(temporal.frameSupportSeconds - 0.1) < 1e-14)
    #expect(temporal.filterLookaheadSeconds > 0)
    #expect(abs(temporal.centeredSmoothingLookaheadSeconds - 0.006) < 1e-14)
    #expect(!temporal.requiresCompleteInterval)
    #expect(try offline.requirements().first?.requiresCompleteInterval == true)
}

@Test func schedulingLowPitchSupportIsIndependentOfHop() throws {
    let format = try PCMFormat(sampleRate: 48000, channelCount: 1, encoding: .float64)
    let yin = try YINConfiguration(
        sampleRate: 48000, inputPrecision: .float64,
        pitchFloorHz: 25, pitchCeilingHz: 2000, hopLength: 480)
    let profile = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean,
        pitch: YINProfile(estimator: yin))
    let temporal = try #require(profile.requirements().first)
    #expect(abs(temporal.frameSupportSeconds - 3841.0 / 48000) < 1e-14)
    #expect(temporal.outputIntervalSeconds == 0.01)
    #expect(temporal.centeredSmoothingLookaheadSeconds == 0)
    #expect(temporal.frameSupportSeconds > 8 * temporal.outputIntervalSeconds)
}

@Test func schedulingSourceMappingPreservesLargeOriginalPositions() throws {
    let capture = StreamEpoch(streamID: UUID(), sequence: 7)
    let continuity = StreamEpoch(streamID: capture.streamID, sequence: 12)
    let start: Int64 = (1 << 54) + 17
    let source = try SourceInterval(
        epoch: capture, startSample: start, sampleCount: 0, sampleRate: 48000)
    let origin = try AnalysisScheduleOrigin(
        source: source, continuityEpoch: continuity,
        sourceStartSeconds: 10, hostStartNanoseconds: 5_000_000_000,
        wallClockStartUnixSeconds: 1_700_000_000)
    let local = try SourceInterval(
        epoch: continuity, startSample: 3, sampleCount: 7, sampleRate: 48000)
    let mapped = try origin.sourceInterval(for: local)
    #expect(mapped.epoch == capture)
    #expect(mapped.startSample == start + 3)
    #expect(mapped.endSample == start + 10)
    #expect(mapped.sampleCount == 7)
    #expect(try origin.hostNanoseconds(atAnalysisSample: 3) == 5_000_062_500)
    #expect(try origin.sourceSeconds(atAnalysisSample: 48000) == 11)
    #expect(try origin.wallClockUnixSeconds(atAnalysisSample: 48000) == 1_700_000_001)
    let wrong = try SourceInterval(
        epoch: capture, startSample: 3, sampleCount: 7, sampleRate: 48000)
    #expect(throws: AnalysisScheduleError.unexpectedInput) {
        try origin.sourceInterval(for: wrong)
    }
    #expect(
        try JSONDecoder().decode(
            AnalysisScheduleOrigin.self, from: JSONEncoder().encode(origin)) == origin)
}

@Test func schedulingClockProjectionChecksOverflowAndKeepsAbsentClocksAbsent() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: 48000)
    let unanchored = try AnalysisScheduleOrigin(source: source, continuityEpoch: epoch)
    #expect(try unanchored.hostNanoseconds(atAnalysisSample: 1) == nil)
    #expect(try unanchored.sourceSeconds(atAnalysisSample: 1) == nil)
    #expect(try unanchored.wallClockUnixSeconds(atAnalysisSample: 1) == nil)
    let large = try AnalysisScheduleOrigin(
        source: source, continuityEpoch: epoch, hostStartNanoseconds: 1000)
    // Exact integer-rational oracle: round(((2^45 + 7) * 1e9) / 48000).
    #expect(
        try large.hostNanoseconds(atAnalysisSample: (1 << 45) + 7)
            == 733_007_751_850_813_500)
    let nearLimit = try AnalysisScheduleOrigin(
        source: source, continuityEpoch: epoch, hostStartNanoseconds: UInt64.max - 100)
    #expect(throws: AnalysisScheduleError.invalidClock) {
        try nearLimit.hostNanoseconds(atAnalysisSample: 1)
    }
    let last = try AnalysisScheduleOrigin(
        source: SourceInterval(
            epoch: epoch, startSample: Int64.max - 1, sampleCount: 0, sampleRate: 48000),
        continuityEpoch: epoch)
    let overflow = try SourceInterval(
        epoch: epoch, startSample: 2, sampleCount: 0, sampleRate: 48000)
    #expect(throws: ContractError.arithmeticOverflow) { try last.sourceInterval(for: overflow) }
}
