import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func scheduleTestOrigin(start: Int64 = 0, rate: Double = 16000) throws
    -> AnalysisScheduleOrigin
{
    let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!)
    return try AnalysisScheduleOrigin(
        source: SourceInterval(epoch: epoch, startSample: start, sampleCount: 0, sampleRate: rate),
        continuityEpoch: StreamEpoch(streamID: epoch.streamID, sequence: 3),
        hostStartNanoseconds: 1_000_000_000)
}

private func scheduleTestProfile() throws -> AnalysisScheduleProfile {
    try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 2, encoding: .float64),
        channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
            accumulation: .compensatedSliding, weighting: .none),
        pitch: YINProfile(
            estimator: YINConfiguration(
                sampleRate: 16000, inputPrecision: .float64,
                pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 160)),
        cpps: CPPSProfile(
            cepstrogram: CepstrogramConfiguration(
                sourceSampleRate: 16000, hopSeconds: 0.01, declaredInputBandwidthHz: 8000,
                conditioningMethod: .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
            settings: CPPSConfiguration(
                timeWindowSeconds: 0.02, prominence: CPPConfiguration(fitMethod: .leastSquares))))
}

@Test func schedulingPartitionsPreserveAllAlgorithmOutputsAndDirectValues() throws {
    let count = 2401
    let signal = (0..<count).map { index in
        0.3 * sin(2 * .pi * 125 * Double(index) / 16000)
            + 0.07 * cos(2 * .pi * 375 * Double(index) / 16000)
    }
    let stereo = signal.flatMap { [$0, $0 * 0.5] }
    let mono = signal.map { $0 * 0.75 }
    let profile = try scheduleTestProfile()
    let origin = try scheduleTestOrigin(start: (1 << 54) + 29)
    var baseline: [ScheduledFrame] = []
    var baselineCompletion: AnalysisScheduleCompletion?
    var seed: UInt64 = 40
    let randomized = (0..<127).map { _ in
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return 1 + Int((seed >> 32) % 701)
    }
    for partition in [[count], [1], [7, 131, 2, 509, 3, 64], randomized] {
        let worker = try PreparedAnalysisSchedule<Double>(
            profile: profile, origin: origin, mode: .finite,
            expectedSampleCount: Int64(count), sourceTileCapacity: 128)
        let memory = worker.preparedBufferBytes
        var frames: [ScheduledFrame] = []
        var offset = 0
        var chunk = 0
        try stereo.withUnsafeBufferPointer { input in
            while offset < count {
                let n = min(partition[chunk % partition.count], count - offset)
                let source = try SourceInterval(
                    epoch: origin.source.epoch,
                    startSample: origin.source.startSample + Int64(offset),
                    sampleCount: Int64(n), sampleRate: 16000)
                let report = try worker.processInterleaved(
                    UnsafeBufferPointer(rebasing: input[(2 * offset)..<(2 * (offset + n))]),
                    interval: source
                ) { frames.append($0) }
                #expect(report.consumedSourceSamples == n)
                offset += n
                chunk += 1
            }
        }
        let completion = try worker.finish { frames.append($0) }
        #expect(worker.preparedBufferBytes == memory)
        #expect(completion.observedSource.sampleCount == Int64(count))
        #expect(completion.observedSource.startSample == origin.source.startSample)
        #expect(try worker.finish { _ in Issue.record("Finish emitted twice") } == completion)
        if baseline.isEmpty {
            baseline = frames
            baselineCompletion = completion
        } else {
            #expect(frames == baseline)
            #expect(completion == baselineCompletion)
        }
    }
    let interval = try SourceInterval(
        epoch: origin.continuityEpoch, startSample: 0, sampleCount: Int64(count), sampleRate: 16000)
    let levels = try PreparedLevelAnalyzer<Double>(
        configuration: #require(profile.levels), epoch: origin.continuityEpoch)
    let pitch = try PreparedYINAnalyzer<Double>(
        profile: #require(profile.pitch), epoch: origin.continuityEpoch)
    let cpps = try PreparedPreviewCPPS<Double>(
        profile: #require(profile.cpps), epoch: origin.continuityEpoch)
    var levelValues: [LevelWindowResult] = []
    var pitchValues: [YINFrameResult] = []
    var cppsValues: [CPPSFrameResult] = []
    try mono.withUnsafeBufferPointer { input in
        _ = try levels.process(input, interval: interval) { levelValues.append($0) }
        _ = try pitch.process(input, interval: interval) { pitchValues.append($0.raw.result) }
        _ = try cpps.process(input, interval: interval) { cppsValues.append($0.result) }
    }
    _ = try levels.finish { levelValues.append($0) }
    _ = try pitch.finish { pitchValues.append($0.raw.result) }
    _ = try cpps.finish { cppsValues.append($0.result) }
    let scheduledLevels = baseline.compactMap { frame -> LevelWindowResult? in
        if case .levels(let value) = frame.value { return value }
        return nil
    }
    let scheduledPitch = baseline.compactMap { frame -> YINFrameResult? in
        if case .pitch(let raw, _) = frame.value { return raw }
        return nil
    }
    let scheduledCPPS = baseline.compactMap { frame -> CPPSFrameResult? in
        if case .cpps(let value) = frame.value { return value }
        return nil
    }
    #expect(scheduledLevels == levelValues)
    #expect(scheduledPitch == pitchValues)
    #expect(!scheduledCPPS.isEmpty && scheduledCPPS.count == cppsValues.count)
    for (scheduled, direct) in zip(scheduledCPPS, cppsValues) {
        #expect(scheduled.observation == direct.observation)
        #expect(scheduled.unavailability == direct.unavailability)
        #expect(scheduled.context.timing.source == direct.context.timing.source)
        #expect(
            scheduled.context.firstAnalysisSampleIndex == direct.context.firstAnalysisSampleIndex)
        #expect(scheduled.context.centerSecondsFromOrigin == direct.context.centerSecondsFromOrigin)
    }
    for frame in baseline {
        #expect(frame.timing.source.epoch == origin.source.epoch)
        #expect(frame.timing.source.startSample >= origin.source.startSample)
        #expect(frame.workerBatchingUpperBoundSeconds == 128.0 / 16000)
    }
}

@Test func schedulingRejectsInvalidWholeChunksBeforeConsumption() throws {
    let profile = try scheduleTestProfile()
    let origin = try scheduleTestOrigin()
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .continuous, sourceTileCapacity: 32)
    var samples = [Double](repeating: 0.2, count: 1024)
    samples[samples.count - 1] = .nan
    let source = try SourceInterval(
        epoch: origin.source.epoch, startSample: 0, sampleCount: 512, sampleRate: 16000)
    #expect(throws: AnalysisScheduleError.invalidInput) {
        try samples.withUnsafeBufferPointer { input in
            try worker.processInterleaved(input, interval: source) { _ in
                Issue.record("Invalid chunk emitted")
            }
        }
    }
    #expect(worker.receivedSampleCount == 0)
    #expect(worker.emittedFrameCount == 0)
    samples[samples.count - 1] = 0.2
    _ = try samples.withUnsafeBufferPointer {
        try worker.processInterleaved($0, interval: source) { _ in }
    }
    #expect(worker.receivedSampleCount == 512)
}

@Test func schedulingCancellationDoesNotReleaseActiveInputOrPoisonAnotherWorker() throws {
    let origin = try scheduleTestOrigin()
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64, windowLength: 32, hopLength: 16,
            accumulation: .direct, weighting: .none))
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .continuous, sourceTileCapacity: 64)
    let samples = [Double](repeating: 0.25, count: 256)
    let source = try SourceInterval(
        epoch: origin.source.epoch, startSample: 0, sampleCount: 256, sampleRate: 16000)
    var emitted = 0
    let report = try samples.withUnsafeBufferPointer { input in
        try worker.processInterleaved(input, interval: source) { frame in
            emitted += 1
            #expect(throws: AnalysisScheduleError.reentrantCall) { try worker.finish { _ in } }
            worker.cancel()
            do {
                #expect(try frame.measurementResult(.rms).outcome.estimate?.value == 0.25)
            } catch { Issue.record(error) }
        }
    }
    #expect(report.isCancelled && report.consumedSourceSamples == 64)
    #expect(emitted == 1)
    #expect(worker.preparedBufferBytes == 0)
    let independent = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .finite, expectedSampleCount: 256)
    _ = try samples.withUnsafeBufferPointer {
        try independent.processInterleaved($0, interval: source) { _ in }
    }
    #expect(try independent.finish { _ in }.levels?.completeWindowCount == 15)
}

@Test func schedulingFiniteTailsAndEmptyReferenceRemainTyped() throws {
    let origin = try scheduleTestOrigin()
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64, windowLength: 4, hopLength: 2,
            accumulation: .direct, weighting: .none))
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .finite, expectedSampleCount: 3)
    _ = try [0.1].withUnsafeBufferPointer {
        try worker.processInterleaved(
            $0,
            interval: SourceInterval(
                epoch: origin.source.epoch, startSample: 0, sampleCount: 1, sampleRate: 16000)
        ) { _ in }
    }
    #expect(throws: AnalysisScheduleError.unexpectedInput) { try worker.finish { _ in } }
    _ = try [0.2, 0.3].withUnsafeBufferPointer {
        try worker.processInterleaved(
            $0,
            interval: SourceInterval(
                epoch: origin.source.epoch, startSample: 1, sampleCount: 2, sampleRate: 16000)
        ) { _ in }
    }
    var frames: [ScheduledFrame] = []
    let done = try worker.finish { frames.append($0) }
    #expect(done.levels?.completeWindowCount == 0)
    #expect(frames.count == 1)
    #expect(try frames[0].measurementResult(.rms).outcome == .unavailable(.insufficientData))
    let reference = try AnalysisScheduleProfile(
        inputFormat: profile.inputFormat, channels: .arithmeticMean,
        cpps: .murtonRecipePraat7(sourceSampleRate: 16000, declaredInputBandwidthHz: 8000))
    let empty = try PreparedAnalysisSchedule<Double>(
        profile: reference, origin: origin, mode: .finite, expectedSampleCount: 0)
    let emptyReport = try empty.finish { _ in
        Issue.record("Empty source emitted a fabricated frame")
    }
    #expect(emptyReport.cpps?.unavailability == .insufficientData)
    #expect(emptyReport.cpps?.meanDB == nil)
    #expect(emptyReport.observedSource.sampleCount == 0)
}

@Test func schedulingMeanHandlesFiniteExtremeChannelsWithoutOverflow() throws {
    let origin = try scheduleTestOrigin()
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 3, encoding: .float64),
        channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64, windowLength: 1, hopLength: 1,
            accumulation: .direct, weighting: .none))
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .finite, expectedSampleCount: 2,
        sourceTileCapacity: 1)
    let samples = [
        Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
        Double.greatestFiniteMagnitude, 1e308, 1, -1e308,
    ]
    var peaks: [Double] = []
    _ = try samples.withUnsafeBufferPointer {
        try worker.processInterleaved(
            $0,
            interval: SourceInterval(
                epoch: origin.source.epoch, startSample: 0, sampleCount: 2, sampleRate: 16000)
        ) { frame in
            if case .levels(let value) = frame.value, let peak = value.peakAmplitude.estimate?.value
            {
                peaks.append(peak)
            }
        }
    }
    #expect(peaks.count == 2)
    #expect(peaks.first == Double.greatestFiniteMagnitude)
    #expect(abs((peaks.last ?? 0) - 1.0 / 3) < 1e-15)
}

@Test func schedulingPlanarFloatMatchesInterleavedChannelSelection() throws {
    let count = 401
    let left = [Float](repeating: -0.75, count: count)
    let right = (0..<count).map { Float(0.2 * sin(Double($0) * 0.1)) }
    let interleaved = zip(left, right).flatMap { [$0, $1] }
    let levels = try LevelConfiguration(
        sampleRate: 16000, inputPrecision: .float32, windowLength: 64, hopLength: 32,
        accumulation: .compensatedSliding, weighting: .none)
    let origin = try scheduleTestOrigin()
    var baseline: [ScheduledFrame] = []
    for layout in [PCMLayout.interleaved, .planar] {
        let profile = try AnalysisScheduleProfile(
            inputFormat: PCMFormat(
                sampleRate: 16000, channelCount: 2, encoding: .float32, layout: layout),
            channels: PCMChannelSelection(channelIndex: 1), levels: levels)
        let worker = try PreparedAnalysisSchedule<Float>(
            profile: profile, origin: origin, mode: .finite,
            expectedSampleCount: Int64(count), sourceTileCapacity: 32)
        var frames: [ScheduledFrame] = []
        try left.withUnsafeBufferPointer { a in
            try right.withUnsafeBufferPointer { b in
                try interleaved.withUnsafeBufferPointer { packed in
                    var offset = 0
                    while offset < count {
                        let n = min(13, count - offset)
                        let interval = try SourceInterval(
                            epoch: origin.source.epoch, startSample: Int64(offset),
                            sampleCount: Int64(n), sampleRate: 16000)
                        if layout == .interleaved {
                            _ = try worker.processInterleaved(
                                UnsafeBufferPointer(
                                    rebasing: packed[(2 * offset)..<(2 * (offset + n))]),
                                interval: interval
                            ) { frames.append($0) }
                        } else {
                            let planes = [
                                UnsafeBufferPointer(rebasing: a[offset..<(offset + n)]),
                                UnsafeBufferPointer(rebasing: b[offset..<(offset + n)]),
                            ]
                            _ = try planes.withUnsafeBufferPointer {
                                try worker.processPlanar($0, interval: interval) {
                                    frames.append($0)
                                }
                            }
                        }
                        offset += n
                    }
                }
            }
        }
        _ = try worker.finish { frames.append($0) }
        if baseline.isEmpty {
            baseline = frames
        } else {
            #expect(frames.map(\.value) == baseline.map(\.value))
            #expect(frames.map(\.timing) == baseline.map(\.timing))
        }
    }
}

@Test func schedulingResetDropsEveryKernelHistoryAndRetainsOriginalGap() throws {
    let profile = try scheduleTestProfile()
    let origin = try scheduleTestOrigin()
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .continuous, sourceTileCapacity: 128)
    let bytes = worker.preparedBufferBytes
    let samples = [Double](repeating: 0.3, count: 400)  // 200 source frames.
    _ = try samples.withUnsafeBufferPointer {
        try worker.processInterleaved(
            $0,
            interval: SourceInterval(
                epoch: origin.source.epoch, startSample: 0, sampleCount: 200, sampleRate: 16000)
        ) { _ in }
    }
    let next = try AnalysisScheduleOrigin(
        source: SourceInterval(
            epoch: origin.source.epoch, startSample: 1000, sampleCount: 0, sampleRate: 16000),
        continuityEpoch: origin.continuityEpoch.successor(), hostStartNanoseconds: 2_000_000_000)
    let wrongGap = try SourceInterval(
        epoch: origin.source.epoch, startSample: 201, sampleCount: 799, sampleRate: 16000)
    #expect(throws: AnalysisScheduleError.invalidGap) {
        try worker.reset(origin: next, reason: .droppedAudio, missingSource: wrongGap)
    }
    #expect(worker.origin == origin && worker.receivedSampleCount == 200)
    let gap = try SourceInterval(
        epoch: origin.source.epoch, startSample: 200, sampleCount: 800, sampleRate: 16000)
    let reset = try worker.reset(origin: next, reason: .droppedAudio, missingSource: gap)
    #expect(reset.missingSource == gap)
    #expect(reset.observedSource.sampleCount == 200)
    #expect(reset.dispatchedSourceSamples == 128)
    #expect(reset.pendingSourceSamplesDiscarded == 72)
    #expect(worker.preparedBufferBytes == bytes)
    var actual: [ScheduledFrame] = []
    let interval = try SourceInterval(
        epoch: origin.source.epoch, startSample: 1000, sampleCount: 200, sampleRate: 16000)
    _ = try samples.withUnsafeBufferPointer {
        try worker.processInterleaved($0, interval: interval) { actual.append($0) }
    }
    let complete = try worker.finish { actual.append($0) }
    let independent = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: next, mode: .continuous, sourceTileCapacity: 128)
    var expected: [ScheduledFrame] = []
    _ = try samples.withUnsafeBufferPointer {
        try independent.processInterleaved($0, interval: interval) { expected.append($0) }
    }
    let independentComplete = try independent.finish { expected.append($0) }
    #expect(actual == expected)
    #expect(complete == independentComplete)
    #expect(complete.levels?.completeWindowCount == 0)
    #expect(complete.pitch?.framing.completeFrameCount == 0)
    #expect(actual.allSatisfy { $0.timing.source.startSample >= 1000 })
    #expect(complete.cpps?.unavailability == .insufficientData)
}
