import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func swipeScheduleOrigin(rate: Int, sequence: UInt64 = 0) throws -> AnalysisScheduleOrigin {
    let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000044")!)
    return try AnalysisScheduleOrigin(
        source: SourceInterval(
            epoch: epoch, startSample: (1 << 54) + 44, sampleCount: 0, sampleRate: Double(rate)),
        continuityEpoch: StreamEpoch(streamID: epoch.streamID, sequence: sequence),
        sourceStartSeconds: 12.5, hostStartNanoseconds: 1_000_000_000)
}

@Test func swipePrimeDirectAndScheduledClocksAgreeOnHalfNanosecondTies() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 128000, pitchFloorHz: 16000, pitchCeilingHz: 32000, hopLength: 1)
    let origin = try swipeScheduleOrigin(rate: c.sampleRate)
    let worker = try PreparedSWIPEPrimeAnalyzer<Double>(
        configuration: c,
        origin: AnalysisTiming(
            source: origin.source, includedSampleCount: 0,
            hostStartNanoseconds: origin.hostStartNanoseconds))
    let pcm = Array(repeating: 0.0, count: c.requiredSampleCount + 3)
    let interval = try SourceInterval(
        epoch: origin.source.epoch, startSample: origin.source.startSample,
        sampleCount: Int64(pcm.count), sampleRate: 128000)
    var times: [UInt64?] = []
    try pcm.withUnsafeBufferPointer {
        _ = try worker.process($0, interval: interval) {
            times.append($0.result.timing.hostStartNanoseconds)
        }
    }
    try worker.finish { times.append($0.result.timing.hostStartNanoseconds) }
    let expected: [UInt64?] = [
        1_000_000_000, 1_000_007_812, 1_000_015_625, 1_000_023_438, 1_000_031_250,
    ]
    #expect(times == expected)
    for index in expected.indices {
        #expect(try origin.hostNanoseconds(atAnalysisSample: Int64(index)) == expected[index])
    }
}

private func swipeScheduled<Sample: BinaryFloatingPoint & Sendable>(
    _ pcm: [Sample], profile: AnalysisScheduleProfile, origin: AnalysisScheduleOrigin,
    mode: AnalysisScheduleMode = .finite, chunks: [Int]
) throws -> ([ScheduledFrame], AnalysisScheduleCompletion) {
    let worker = try PreparedAnalysisSchedule<Sample>(
        profile: profile, origin: origin, mode: mode,
        expectedSampleCount: mode == .finite ? Int64(pcm.count) : nil, sourceTileCapacity: 61)
    let bytes = worker.preparedBufferBytes
    let stereo = pcm.flatMap { [Sample(0.23), $0] }
    var frames: [ScheduledFrame] = []
    var offset = 0
    var index = 0
    try stereo.withUnsafeBufferPointer { input in
        while offset < pcm.count {
            let count = min(chunks[index % chunks.count], pcm.count - offset)
            let source = try SourceInterval(
                epoch: origin.source.epoch, startSample: origin.source.startSample + Int64(offset),
                sampleCount: Int64(count), sampleRate: origin.source.sampleRate)
            let report = try worker.processInterleaved(
                UnsafeBufferPointer(rebasing: input[2 * offset..<2 * (offset + count)]),
                interval: source
            ) { frames.append($0) }
            #expect(report.consumedSourceSamples == count && !report.isCancelled)
            offset += count
            index += 1
        }
    }
    let end = try worker.finish { frames.append($0) }
    #expect(worker.preparedBufferBytes == bytes)
    #expect(try worker.finish { _ in Issue.record("Repeated scheduler finish emitted") } == end)
    return (frames, end)
}

private func swipeCompareSchedule<Sample: BinaryFloatingPoint & Sendable>(
    _ samples: [Sample], configuration c: SWIPEPrimeConfiguration
) throws {
    let format = try PCMFormat(
        sampleRate: Double(c.sampleRate), channelCount: 2,
        encoding: c.inputPrecision == .float32 ? .float32 : .float64)
    let channels = try PCMChannelSelection(channelIndex: 1)
    let level = try LevelConfiguration(
        sampleRate: c.sampleRate, inputPrecision: c.inputPrecision,
        windowLength: c.hopLength * 3, hopLength: c.hopLength,
        accumulation: .compensatedSliding, weighting: .none)
    let yin = try YINProfile(
        estimator: YINConfiguration(
            sampleRate: c.sampleRate, inputPrecision: c.inputPrecision,
            pitchFloorHz: c.pitchFloorHz, pitchCeilingHz: c.pitchCeilingHz, hopLength: c.hopLength))
    let baseline = try AnalysisScheduleProfile(
        inputFormat: format, channels: channels, levels: level, pitch: yin)
    let profile = try AnalysisScheduleProfile(
        inputFormat: format, channels: channels, levels: level, pitch: yin, swipePrime: c)
    let origin = try swipeScheduleOrigin(rate: c.sampleRate)
    let old = try swipeScheduled(
        samples, profile: baseline, origin: origin, chunks: [samples.count])
    let batch = try swipeScheduled(
        samples, profile: profile, origin: origin, chunks: [samples.count])
    let chunks = try swipeScheduled(
        samples, profile: profile, origin: origin, mode: .continuous, chunks: [1, 7, 83, 3])
    #expect(batch.0 == chunks.0 && batch.1 == chunks.1)
    let preserved = batch.0.filter { $0.algorithm != .swipePrime }
    #expect(old.0.map(\.value) == preserved.map(\.value))
    #expect(old.0.map(\.timing) == preserved.map(\.timing))
    #expect(old.0.map(\.coverage) == preserved.map(\.coverage))
    #expect(
        old.1.pitch == batch.1.pitch && old.1.levels == batch.1.levels && old.1.swipePrime == nil)
    let native = try PreparedSWIPEPrimeAnalyzer<Sample>(
        configuration: c, epoch: origin.continuityEpoch)
    var direct: [SWIPEPrimeFrameResult] = []
    try samples.withUnsafeBufferPointer {
        _ = try native.process(
            $0,
            interval: SourceInterval(
                epoch: native.epoch, startSample: 0,
                sampleCount: Int64(samples.count), sampleRate: Double(c.sampleRate))
        ) { direct.append($0.result) }
    }
    let completion = try native.finish { direct.append($0.result) }
    #expect(batch.1.swipePrime == completion)
    let scheduled = batch.0.filter { $0.algorithm == .swipePrime }
    try #require(scheduled.count == direct.count && !direct.isEmpty)
    for (frame, raw) in zip(scheduled, direct) {
        #expect(frame.value == .swipePrime(raw))
        #expect(try frame.timing == origin.mappedTiming(raw.timing))
        #expect(
            frame.frameCenterSecondsFromOrigin == Double(raw.timing.source.startSample)
                / raw.timing.source.sampleRate + raw.timing.source.durationSeconds / 2)
        let export = try frame.export(.fundamentalFrequency)
        #expect(try export.result.outcome == raw.measurementResult().outcome)
        #expect(export.result.profile == frame.schedule && export.dependencyTiming == frame.timing)
        #expect(export.dependencyCoverage.source == frame.timing.source.sampleCount)
        #expect(throws: AnalysisScheduleError.invalidConfiguration) {
            try frame.export(.trackedFundamentalFrequency)
        }
    }
}

@Test func swipePrimeScheduleOptionalLanePreservesBaselineAndDirectResults() throws {
    for rate in [16000, 44100, 48000] {
        for precision in [AnalysisPrecision.float32, .float64] {
            let c = try SWIPEPrimeConfiguration(
                sampleRate: rate, inputPrecision: precision,
                pitchFloorHz: 100, pitchCeilingHz: 700, hopLength: rate / 100)
            let samples = (0..<c.requiredSampleCount + c.hopLength + 7).map {
                0.4 * sin(2 * .pi * 200 * Double($0) / Double(rate))
                    + 0.1 * sin(2 * .pi * 400 * Double($0) / Double(rate))
            }
            if precision == .float32 {
                try swipeCompareSchedule(samples.map(Float.init), configuration: c)
            } else {
                try swipeCompareSchedule(samples, configuration: c)
            }
        }
    }
}

@Test func swipePrimeScheduleProfilesPreserveLegacyEncodingAndRejectMismatchedInput() throws {
    let format = try PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64)
    let c = try SWIPEPrimeConfiguration(sampleRate: 16000, hopLength: 160)
    let yin = try YINProfile(estimator: YINConfiguration(sampleRate: 16000, hopLength: 160))
    let legacy = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean, pitch: yin)
    let absent = try canonicalContractJSON(legacy)
    let object = try #require(JSONSerialization.jsonObject(with: absent) as? [String: Any])
    #expect(object["swipePrime"] == nil)
    #expect(try JSONDecoder().decode(AnalysisScheduleProfile.self, from: absent) == legacy)
    let explicitNil = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean, pitch: yin, swipePrime: nil)
    #expect(
        try canonicalContractJSON(explicitNil) == absent
            && explicitNil.identity() == legacy.identity())
    let only = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean, swipePrime: c)
    try only.validate(mode: .continuous)
    #expect(
        try JSONDecoder().decode(AnalysisScheduleProfile.self, from: canonicalContractJSON(only))
            == only)
    #expect(try only.identity() != legacy.identity())
    let requirement = try #require(only.requirements().first)
    #expect(requirement.algorithm == .swipePrime && requirement.history == .finiteWindow)
    #expect(
        requirement.frameSupportSeconds == c.supportDurationSeconds
            && requirement.outputIntervalSeconds == 0.01)
    #expect(
        requirement.partialWindowPolicy == .emitUnavailable && !requirement.requiresCompleteInterval
    )
    for wrong in [
        try SWIPEPrimeConfiguration(sampleRate: 4000, hopLength: 40),
        try SWIPEPrimeConfiguration(sampleRate: 16000, inputPrecision: .float32, hopLength: 160),
    ] {
        #expect(throws: AnalysisScheduleError.invalidConfiguration) {
            try AnalysisScheduleProfile(
                inputFormat: format, channels: .arithmeticMean, swipePrime: wrong)
        }
    }
}

@Test func swipePrimeScheduleCancellationAndResetRecreateOptionalWorker() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 4000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean, swipePrime: c)
    let origin = try swipeScheduleOrigin(rate: 4000)
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .finite,
        expectedSampleCount: 200, sourceTileCapacity: 31)
    let source = try SourceInterval(
        epoch: origin.source.epoch, startSample: origin.source.startSample, sampleCount: 200,
        sampleRate: 4000)
    let samples = (0..<200).map { sin(2 * .pi * Double($0) / 6) }
    var emissions = 0
    let report = try samples.withUnsafeBufferPointer {
        try worker.processInterleaved($0, interval: source) { frame in
            #expect(frame.algorithm == .swipePrime)
            emissions += 1
            worker.cancel()
        }
    }
    #expect(emissions == 1 && report.isCancelled && report.consumedSourceSamples == 93)
    #expect(worker.preparedBufferBytes == 0)
    let next = try swipeScheduleOrigin(rate: 4000, sequence: 1)
    try worker.reset(origin: next, expectedSampleCount: 200)
    let bytes = worker.preparedBufferBytes
    #expect(bytes > 0)
    var frames: [ScheduledFrame] = []
    try samples.withUnsafeBufferPointer {
        _ = try worker.processInterleaved($0, interval: source) { frames.append($0) }
    }
    let end = try worker.finish { frames.append($0) }
    #expect(!end.isCancelled && end.swipePrime?.framing.completeFrameCount == 35)
    #expect(frames.count == 36 && frames[0].origin.continuityEpoch == next.continuityEpoch)
    try worker.reset(origin: swipeScheduleOrigin(rate: 4000, sequence: 2), expectedSampleCount: 0)
    #expect(worker.preparedBufferBytes == bytes)
    let empty = try worker.finish { _ in Issue.record("Empty optional lane emitted") }
    #expect(empty.swipePrime?.framing.disposition == .empty)
}

@Test func swipePrimeScheduleMasksKeepExcludedSamplesDistinctFromUnavailablePitch() throws {
    let epoch = StreamEpoch(streamID: UUID())
    func source(_ start: Int64, _ count: Int64) throws -> SourceInterval {
        try SourceInterval(epoch: epoch, startSample: start, sampleCount: count, sampleRate: 4000)
    }
    let provenance = try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "swipe-mask-test", version: 1))
    let mask = try PreparedAnalysisMask(
        timeline: MaskTimeline(
            MaskPlan(
                source: source(0, 300), provenances: [provenance],
                policy: MaskSelectionPolicy(selectionSources: [0]),
                observations: [
                    MaskObservation(
                        source: source(0, 50), provenanceIndex: 0, selection: .selected),
                    MaskObservation(
                        source: source(200, 100), provenanceIndex: 0, selection: .selected),
                ])), scope: .selected)
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 4000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean, swipePrime: c)
    let origin = try AnalysisScheduleOrigin(source: source(0, 0), continuityEpoch: epoch)
    let worker = try PreparedMaskedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .finite, mask: mask, sourceTileCapacity: 31)
    var frames: [ScheduledFrame] = []
    var regions: [AnalysisScheduleCompletion] = []
    try Array(repeating: 0.0, count: 300).withUnsafeBufferPointer {
        _ = try worker.processInterleaved(
            $0, interval: source(0, 300), emit: { frames.append($0) },
            regionCompleted: { regions.append($0) })
    }
    let end = try worker.finish()
    #expect(end.analyzedSampleCount == 150 && end.coverage.excludedEligible == 150)
    #expect(regions.count == 2 && regions[0].swipePrime?.framing.completeFrameCount == 0)
    #expect(frames.first?.timing.source.sampleCount == 50)
    for frame in frames {
        #expect(frame.timing.source.endSample <= 50 || frame.timing.source.startSample >= 200)
        #expect(
            frame.coverage.selected == frame.coverage.source && frame.coverage.excludedEligible == 0
        )
        guard case .swipePrime(let value) = frame.value else {
            Issue.record("Wrong optional lane")
            continue
        }
        #expect(
            value.unavailability
                == (value.timing.source.sampleCount < 64 ? .insufficientData : .silence))
    }
}
