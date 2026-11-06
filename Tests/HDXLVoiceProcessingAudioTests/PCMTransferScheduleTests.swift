import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingAudio

private func transferScheduleParity<Sample: BinaryFloatingPoint & Sendable>(
    _: Sample.Type, layout: PCMLayout
) throws {
    let count = 6601
    let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000240")!)
    let format = try PCMFormat(
        sampleRate: 44100, channelCount: 2,
        encoding: Sample.self == Float.self ? .float32 : .float64, layout: layout)
    let precision: AnalysisPrecision = Sample.self == Float.self ? .float32 : .float64
    let profile = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: 44100, inputPrecision: precision,
            windowLength: 800, hopLength: 441, accumulation: .compensatedSliding, weighting: .none),
        pitch: YINProfile(
            estimator: YINConfiguration(
                sampleRate: 44100, inputPrecision: precision,
                pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 441)),
        cpps: CPPSProfile(
            cepstrogram: CepstrogramConfiguration(
                sourceSampleRate: 44100,
                inputPrecision: precision, hopSeconds: 0.01, declaredInputBandwidthHz: 22050,
                conditioningMethod: .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
            settings: CPPSConfiguration(
                timeWindowSeconds: 0.02,
                prominence: CPPConfiguration(fitMethod: .leastSquares))))
    let start: Int64 = (1 << 54) + 51
    let source = try SourceInterval(
        epoch: epoch, startSample: start, sampleCount: 0, sampleRate: 44100)
    let origin = try AnalysisScheduleOrigin(
        source: source, continuityEpoch: epoch,
        sourceStartSeconds: 3, wallClockStartUnixSeconds: 100)
    let anchored = try AnalysisScheduleOrigin(
        source: source, continuityEpoch: epoch,
        sourceStartSeconds: 3, hostStartNanoseconds: 123_456_789, wallClockStartUnixSeconds: 100)
    let queue = PCMTransfer(
        configuration: try PCMTransferConfiguration(
            format: format,
            epoch: epoch, channelMap: [17, 4], maximumFramesPerChunk: 300, slotCount: 2))
    let worker = try PreparedPCMTransferSchedule<Sample>(
        transfer: queue, profile: profile, origin: origin, sourceTileCapacity: 128)
    let direct = try PreparedAnalysisSchedule<Sample>(
        profile: profile, origin: anchored,
        mode: .continuous, sourceTileCapacity: 128)
    let left: [Sample] = (0..<count).map {
        Sample(0.2 * sin(2 * .pi * 125 * Double($0) / 44100))
    }
    let right = left.map { $0 * 0.5 }
    var frames: [ScheduledFrame] = []
    var completion: AnalysisScheduleCompletion?
    func receive(_ event: PCMTransferScheduleEvent) {
        switch event {
        case .frame(let value):
            #expect(value.channelMap == [17, 4])
            frames.append(value.frame)
        case .regionCompleted(let value): completion = value
        default: Issue.record("Unexpected discontinuity")
        }
    }
    let memory = worker.preparedBufferBytes
    let chunks = [1, 17, 299, 3, 128, 71]
    var offset = 0
    var chunk = 0
    while offset < count {
        let n = min(chunks[chunk % chunks.count], count - offset)
        let host = try #require(try anchored.hostNanoseconds(atAnalysisSample: Int64(offset)))
        let offered: PCMTransferOfferResult
        if layout == .interleaved {
            let input = (offset..<(offset + n)).flatMap { [left[$0], right[$0]] }
            offered = input.withUnsafeBytes {
                queue.offerInterleaved(
                    $0, frameCount: UInt32(n), sourceStartSample: start + Int64(offset),
                    configurationToken: queue.configuration.captureToken, hostStartNanoseconds: host
                )
            }
        } else {
            offered = Array(left[offset..<(offset + n)]).withUnsafeBytes { l in
                Array(right[offset..<(offset + n)]).withUnsafeBytes { r in
                    [l, r].withUnsafeBufferPointer {
                        queue.offerPlanar(
                            $0, frameCount: UInt32(n), sourceStartSample: start + Int64(offset),
                            configurationToken: queue.configuration.captureToken,
                            hostStartNanoseconds: host)
                    }
                }
            }
        }
        #expect(offered == .accepted(sequence: UInt64(chunk)))
        let report = try worker.drain(maximumEvents: 1, emit: receive)
        #expect(report.deliveredEvents == 1)
        #expect(report.consumedSourceSamples == n)
        #expect(!report.reachedEnd)
        offset += n
        chunk += 1
    }
    queue.close()
    #expect(try worker.drain(maximumEvents: 1, emit: receive).reachedEnd)
    #expect(try worker.drain(emit: { _ in Issue.record("Repeated finalization") }).reachedEnd)
    #expect(worker.preparedBufferBytes == memory)
    var expected: [ScheduledFrame] = []
    let whole = try SourceInterval(
        epoch: epoch, startSample: start, sampleCount: Int64(count), sampleRate: 44100)
    if layout == .interleaved {
        _ = try (0..<count).flatMap { [left[$0], right[$0]] }.withUnsafeBufferPointer {
            try direct.processInterleaved($0, interval: whole) { expected.append($0) }
        }
    } else {
        _ = try left.withUnsafeBufferPointer { l in
            try right.withUnsafeBufferPointer { r in
                try [l, r].withUnsafeBufferPointer {
                    try direct.processPlanar($0, interval: whole) { expected.append($0) }
                }
            }
        }
    }
    let expectedCompletion = try direct.finish { expected.append($0) }
    #expect(
        expected.contains {
            if case .cpps(let value) = $0.value { return value.observation != nil }
            return false
        })
    #expect(frames == expected)
    #expect(completion == expectedCompletion)
}

@Test func schedulingTransferMatchesMemoryForBothPrecisionsAndLayouts() throws {
    for layout in [PCMLayout.interleaved, .planar] {
        try transferScheduleParity(Float.self, layout: layout)
        try transferScheduleParity(Double.self, layout: layout)
    }
}

private func transferGapSchedule() throws -> (PCMTransfer, PreparedPCMTransferSchedule<Double>) {
    let epoch = StreamEpoch(streamID: UUID())
    let format = try PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64)
    let queue = PCMTransfer(
        configuration: try PCMTransferConfiguration(
            format: format,
            epoch: epoch, maximumFramesPerChunk: 4, slotCount: 2))
    let profile = try AnalysisScheduleProfile(
        inputFormat: format, channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64,
            windowLength: 4, hopLength: 4, accumulation: .compensatedSliding, weighting: .none))
    let origin = try AnalysisScheduleOrigin(
        source: SourceInterval(
            epoch: epoch,
            startSample: 0, sampleCount: 0, sampleRate: 16000), continuityEpoch: epoch)
    return (
        queue,
        try PreparedPCMTransferSchedule(
            transfer: queue,
            profile: profile, origin: origin, sourceTileCapacity: 2)
    )
}

private func scheduleOffer(_ queue: PCMTransfer, start: Int64, count: Int = 2)
    -> PCMTransferOfferResult
{
    Array(repeating: 0.25, count: count).withUnsafeBytes {
        queue.offerInterleaved(
            $0, frameCount: UInt32(count), sourceStartSample: start,
            configurationToken: queue.configuration.captureToken)
    }
}

@Test func schedulingTransferKnownAndTerminalGapsStayObservable() throws {
    let (queue, worker) = try transferGapSchedule()
    #expect(scheduleOffer(queue, start: 0) == .accepted(sequence: 0))
    #expect(scheduleOffer(queue, start: 2) == .accepted(sequence: 1))
    #expect(scheduleOffer(queue, start: 4) == .droppedCapacity)
    var events: [PCMTransferScheduleEvent] = []
    #expect(try worker.drain(maximumEvents: 1) { events.append($0) }.deliveredEvents == 1)
    #expect(scheduleOffer(queue, start: 6) == .accepted(sequence: 3))
    _ = try worker.drain(maximumEvents: 4) { events.append($0) }
    #expect(scheduleOffer(queue, start: 8) == .accepted(sequence: 4))
    #expect(scheduleOffer(queue, start: 10) == .accepted(sequence: 5))
    #expect(scheduleOffer(queue, start: 12) == .droppedCapacity)
    queue.close()
    #expect(try worker.drain { events.append($0) }.reachedEnd)
    let gaps = events.compactMap { if case .gap(let value) = $0 { value } else { nil } }
    let resets = events.compactMap { if case .reset(let value) = $0 { value } else { nil } }
    let regions = events.compactMap {
        if case .regionCompleted(let value) = $0 { value } else { nil }
    }
    #expect(gaps.count == 2)
    #expect(gaps[0].missingSource?.startSample == 4)
    #expect(gaps[0].missingSource?.endSample == 6)
    #expect(gaps[1].missingSource?.startSample == 12)
    #expect(gaps[1].missingSource?.endSample == 14)
    #expect(resets.count == 1)
    #expect(resets.first?.missingSource?.sampleCount == 2)
    #expect(resets.first?.nextOrigin.continuityEpoch.sequence == 1)
    #expect(regions.map(\.observedSource.startSample) == [0, 6])
    #expect(regions.map(\.observedSource.sampleCount) == [4, 6])
}

@Test func schedulingTransferUnknownGapCancellationAndBadInputRemainIsolated() throws {
    let (queue, worker) = try transferGapSchedule()
    #expect(scheduleOffer(queue, start: 10, count: 1) == .accepted(sequence: 0))
    _ = try worker.drain { _ in }
    // A backwards source jump has unknown lost extent, never a negative interval.
    #expect(scheduleOffer(queue, start: 5, count: 1) == .accepted(sequence: 1))
    var gap: PCMTransferGap?
    _ = try worker.drain {
        if case .gap(let value) = $0 { gap = value }
    }
    #expect(try #require(gap).missingSource == nil)
    #expect(scheduleOffer(queue, start: 6, count: 4) == .accepted(sequence: 2))
    let report = try worker.drain { event in
        if case .frame = event {
            #expect(throws: AnalysisScheduleError.reentrantCall) { try worker.drain { _ in } }
            worker.cancel()
        }
    }
    #expect(report.isCancelled)
    #expect(!queue.snapshot().isClosed)
    #expect(try worker.drain { _ in Issue.record("Cancelled worker emitted") }.isCancelled)
    queue.close()

    let (badQueue, badWorker) = try transferGapSchedule()
    let offered = [Double.nan].withUnsafeBytes {
        badQueue.offerInterleaved(
            $0, frameCount: 1, sourceStartSample: 0,
            configurationToken: badQueue.configuration.captureToken)
    }
    #expect(offered == .accepted(sequence: 0))
    #expect(throws: AnalysisScheduleError.invalidInput) { try badWorker.drain { _ in } }
    #expect(throws: AnalysisScheduleError.invalidState) { try badWorker.drain { _ in } }
    badQueue.close()
    let (goodQueue, goodWorker) = try transferGapSchedule()
    #expect(scheduleOffer(goodQueue, start: 0) == .accepted(sequence: 0))
    goodQueue.close()
    #expect(try goodWorker.drain { _ in }.reachedEnd)
}
