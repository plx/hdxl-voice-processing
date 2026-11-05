import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct YINCapture: Equatable {
    let raw: YINFrameResult
    let tracked: YINTrackedFrameResult?
    let candidates: [YINCandidate]
    let difference: [Double]
    let cmnd: [Double]
    init(_ output: BorrowedYINAnalysisOutput) {
        raw = output.raw.result
        tracked = output.tracked
        candidates = Array(output.raw.candidates)
        difference = Array(output.raw.values(.scaledSquaredDifference))
        cmnd = Array(output.raw.values(.cumulativeMeanNormalizedDifference))
    }
}

private func yinOrigin(
    _ profile: YINProfile, epoch: StreamEpoch, start: Int64 = 0,
    seconds: Double? = nil, host: UInt64? = nil
) throws -> AnalysisTiming {
    try AnalysisTiming(
        source: SourceInterval(
            epoch: epoch, startSample: start, sampleCount: 0,
            sampleRate: Double(profile.estimator.sampleRate)),
        includedSampleCount: 0, sourceStartSeconds: seconds, hostStartNanoseconds: host)
}

private func yinStream<Sample: BinaryFloatingPoint & Sendable>(
    _ samples: [Sample], profile: YINProfile, origin: AnalysisTiming, chunks: [Int]
) throws -> ([YINCapture], YINCompletion) {
    let worker = try PreparedYINAnalyzer<Sample>(profile: profile, origin: origin)
    var results: [YINCapture] = []
    var offset = 0
    var index = 0
    try samples.withUnsafeBufferPointer { buffer in
        while offset < buffer.count {
            let count = min(chunks[index % chunks.count], buffer.count - offset)
            let interval = try SourceInterval(
                epoch: origin.source.epoch, startSample: origin.source.startSample + Int64(offset),
                sampleCount: Int64(count), sampleRate: origin.source.sampleRate)
            let report = try worker.process(
                UnsafeBufferPointer(rebasing: buffer[offset..<offset + count]), interval: interval
            ) {
                results.append(YINCapture($0))
            }
            #expect(report.consumedSampleCount == count && !report.isCancelled)
            offset += count
            index += 1
        }
    }
    let finished = try worker.finish { results.append(YINCapture($0)) }
    let repeated = try worker.finish { _ in Issue.record("Repeated finish emitted") }
    #expect(finished == repeated)
    #expect(worker.nextInputSample == origin.source.startSample + Int64(samples.count))
    return (results, finished)
}

@Test func yinStreamingBatchAndChunksPreserveEveryRawAndTrackedField() throws {
    for rate in [16000, 44100, 48000] {
        for backend in YINDifferenceBackend.allCases {
            for precision in [AnalysisPrecision.float32, .float64] {
                for tracking in [false, true] {
                    let c = try YINConfiguration(
                        sampleRate: rate, inputPrecision: precision,
                        pitchFloorHz: rate == 48000 ? 25 : 50,
                        pitchCeilingHz: rate == 48000 ? 2000 : 700,
                        hopLength: Int((Double(rate) * 0.005).rounded()), differenceBackend: backend
                    )
                    let profile = YINProfile(
                        estimator: c, tracker: tracking ? try YINTrackerConfiguration() : nil)
                    let origin = try yinOrigin(
                        profile, epoch: StreamEpoch(streamID: UUID()), start: 123, seconds: 41.25,
                        host: 1_000_000_000)
                    let count = c.requiredSampleCount + 3 * c.hopLength + 7
                    let samples: [Double] = (0..<count).map {
                        let t = Double($0) / Double(rate)
                        return 0.4 * sin(2 * .pi * (137 * t + 8 * t * t)) + 0.1
                            * sin(2 * .pi * 274 * t)
                    }
                    let batch: ([YINCapture], YINCompletion)
                    let chunks: ([YINCapture], YINCompletion)
                    if precision == .float32 {
                        batch = try yinStream(
                            samples.map(Float.init), profile: profile, origin: origin,
                            chunks: [count])
                        chunks = try yinStream(
                            samples.map(Float.init), profile: profile, origin: origin,
                            chunks: [1, 7, 251, 2, 64, 509])
                    } else {
                        batch = try yinStream(
                            samples, profile: profile, origin: origin, chunks: [count])
                        chunks = try yinStream(
                            samples, profile: profile, origin: origin,
                            chunks: [1, 7, 251, 2, 64, 509])
                    }
                    #expect(batch.0 == chunks.0)
                    #expect(batch.1 == chunks.1)
                    #expect(batch.0.count == 5)
                    #expect(batch.1.framing.completeFrameCount == 4)
                    #expect(batch.1.framing.disposition == .unavailablePartial)
                    for frame in batch.0 {
                        #expect((frame.tracked != nil) == tracking)
                        #expect(
                            frame.raw.timing.sourceStartSeconds != nil
                                && frame.raw.timing.hostStartNanoseconds != nil)
                    }
                }
            }
        }
    }
}

@Test func yinStreamingGapDiscardsPendingPCMAndCandidateHistory() throws {
    let c = try YINConfiguration(sampleRate: 16000, hopLength: 80)
    let profile = YINProfile(estimator: c, tracker: try YINTrackerConfiguration())
    let epoch = StreamEpoch(streamID: UUID())
    let worker = try PreparedYINAnalyzer<Double>(profile: profile, epoch: epoch)
    let oldCount = c.requiredSampleCount + 20
    let old = (0..<oldCount).map { 0.4 * sin(2 * .pi * 100 * Double($0) / 16000) }
    var before: [YINCapture] = []
    try old.withUnsafeBufferPointer {
        try worker.process(
            $0,
            interval: SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: Int64(oldCount), sampleRate: 16000)
        ) {
            before.append(YINCapture($0))
        }
    }
    #expect(before.count == 1)
    let next = try epoch.successor()
    let gap = try SourceDiscontinuity(
        previousEpoch: epoch, nextEpoch: next, reason: .droppedAudio,
        missingSource: SourceInterval(
            epoch: epoch, startSample: Int64(oldCount), sampleCount: 37, sampleRate: 16000))
    let origin = try yinOrigin(profile, epoch: next, seconds: 90, host: 2_000_000_000)
    let preparedBytes = worker.preparedBufferBytes
    try worker.reset(for: gap, clockOrigin: origin)
    #expect(worker.nextInputSample == 0 && worker.preparedBufferBytes == preparedBytes)
    let samples = (0..<c.requiredSampleCount + 80).map {
        0.4 * sin(2 * .pi * 300 * Double($0) / 16000)
    }
    var after: [YINCapture] = []
    try samples.withUnsafeBufferPointer {
        try worker.process(
            $0,
            interval: SourceInterval(
                epoch: next, startSample: 0, sampleCount: Int64(samples.count), sampleRate: 16000)
        ) {
            after.append(YINCapture($0))
        }
    }
    let completion = try worker.finish { after.append(YINCapture($0)) }
    let fresh = try yinStream(samples, profile: profile, origin: origin, chunks: [samples.count])
    #expect(after == fresh.0 && completion == fresh.1)
    #expect(after[0].tracked?.dependencyTiming.source.startSample == 0)
    #expect(after[0].raw.timing.source.epoch == next)
    #expect(abs((after[0].raw.observation?.frequencyHz ?? 0) - 300) < 1)
}

@Test func yinStreamingCancellationKeepsCurrentBorrowAndStopsTheChunk() throws {
    let c = try YINConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let profile = YINProfile(estimator: c, tracker: try YINTrackerConfiguration())
    let epoch = StreamEpoch(streamID: UUID())
    let worker = try PreparedYINAnalyzer<Double>(profile: profile, epoch: epoch)
    let samples: [Double] = (0..<100).map { [1.0, 0, -1, 0][$0 % 4] }
    var emissions = 0
    let report = try samples.withUnsafeBufferPointer {
        try worker.process(
            $0,
            interval: SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: 100, sampleRate: 4000)
        ) { output in
            emissions += 1
            let expected = Array(output.raw.values(.scaledSquaredDifference))
            worker.cancel()
            worker.cancel()
            #expect(Array(output.raw.values(.scaledSquaredDifference)) == expected)
            #expect(output.raw.candidates.count == 2)
            #expect(output.tracked?.observation?.frequencyHz == 1000)
        }
    }
    #expect(emissions == 1 && report.emittedFrameCount == 1 && report.consumedSampleCount == 17)
    #expect(report.isCancelled && worker.nextInputSample == 17)
    #expect(worker.preparedBufferBytes == 0 && worker.estimatorStatistics == nil)
    #expect(throws: YINError.invalidState) { try worker.finish { _ in } }
    let next = try epoch.successor()
    try worker.reset(
        for: SourceDiscontinuity(previousEpoch: epoch, nextEpoch: next, reason: .explicitReset))
    #expect(worker.preparedBufferBytes > 0 && worker.nextInputSample == 0)
    try samples.withUnsafeBufferPointer {
        _ = try worker.process(
            UnsafeBufferPointer(rebasing: $0[..<16]),
            interval: SourceInterval(epoch: next, startSample: 0, sampleCount: 16, sampleRate: 4000)
        ) { _ in Issue.record("Partial emitted early") }
    }
    let end = try worker.finish { output in
        worker.cancel()
        #expect(output.raw.result.unavailability == .insufficientData)
        #expect(output.raw.candidates.isEmpty)
    }
    #expect(end.isCancelled && end.framing.disposition == .unavailablePartial)
    #expect(worker.preparedBufferBytes == 0)
}

@Test func yinStreamingClockValidationIsTransactionalAndUsesIntegerOffsets() throws {
    let c = try YINConfiguration(sampleRate: 44100, hopLength: 221)
    let profile = YINProfile(estimator: c, tracker: try YINTrackerConfiguration())
    let epoch = StreamEpoch(streamID: UUID())
    let count = c.requiredSampleCount + 2 * c.hopLength
    let start = Int64.max - Int64(count)
    let origin = try yinOrigin(
        profile, epoch: epoch, start: start, seconds: 123.5, host: 1_000_000_000)
    let worker = try PreparedYINAnalyzer<Double>(profile: profile, origin: origin)
    let samples = (0..<count).map { 0.4 * sin(2 * .pi * 137 * Double($0) / 44100) }
    let interval = try SourceInterval(
        epoch: epoch, startSample: start, sampleCount: Int64(count), sampleRate: 44100)
    #expect(throws: ContractError.invalidTiming) {
        try samples.withUnsafeBufferPointer {
            try worker.process($0, interval: interval, completedHostNanoseconds: 1_000_000_001) {
                _ in
            }
        }
    }
    #expect(worker.nextInputSample == start)
    var results: [YINCapture] = []
    try samples.withUnsafeBufferPointer {
        try worker.process($0, interval: interval, completedHostNanoseconds: 2_000_000_000) {
            results.append(YINCapture($0))
        }
    }
    #expect(worker.nextInputSample == Int64.max && results.count == 3)
    for (index, frame) in results.enumerated() {
        let displacement = index * c.hopLength
        #expect(frame.raw.timing.source.startSample == start + Int64(displacement))
        #expect(frame.raw.timing.sourceStartSeconds == 123.5 + Double(displacement) / 44100)
        let nanos = (UInt64(displacement) * 1_000_000_000 + 22050) / 44100
        #expect(frame.raw.timing.hostStartNanoseconds == 1_000_000_000 + nanos)
        #expect(frame.raw.timing.completedHostNanoseconds == 2_000_000_000)
        #expect(frame.tracked?.dependencyTiming.sourceStartSeconds == 123.5)
        #expect(frame.tracked?.dependencyTiming.hostStartNanoseconds == 1_000_000_000)
    }
    let overflowOrigin = try yinOrigin(
        profile, epoch: StreamEpoch(streamID: UUID()), host: UInt64.max - 1)
    let overflow = try PreparedYINAnalyzer<Double>(profile: profile, origin: overflowOrigin)
    #expect(throws: ContractError.invalidTiming) {
        try [0.0].withUnsafeBufferPointer {
            try overflow.process(
                $0,
                interval: SourceInterval(
                    epoch: overflow.epoch, startSample: 0, sampleCount: 1, sampleRate: 44100)
            ) { _ in }
        }
    }
    #expect(overflow.nextInputSample == 0)
}

@Test func yinStreamingReconfigurationAndReentrancyRespectControlBoundaries() throws {
    let c = try YINConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let profile = YINProfile(estimator: c, tracker: try YINTrackerConfiguration())
    let epoch = StreamEpoch(streamID: UUID())
    let worker = try PreparedYINAnalyzer<Double>(profile: profile, epoch: epoch)
    let next = try epoch.successor()
    let wrongPrecision = try YINConfiguration(
        sampleRate: 4000, inputPrecision: .float32,
        pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    #expect(throws: YINError.precisionMismatch) {
        try worker.reconfigure(to: YINProfile(estimator: wrongPrecision), epoch: next)
    }
    #expect(worker.profile == profile && worker.epoch == epoch)
    let source = try SourceInterval(epoch: epoch, startSample: 0, sampleCount: 17, sampleRate: 4000)
    let reset = try SourceDiscontinuity(
        previousEpoch: epoch, nextEpoch: next, reason: .explicitReset)
    var invalid = [Double](repeating: 0, count: 17)
    invalid[16] = .nan
    #expect(throws: YINError.invalidInput) {
        try invalid.withUnsafeBufferPointer { try worker.process($0, interval: source) { _ in } }
    }
    #expect(worker.nextInputSample == 0)
    try [Double](repeating: 0, count: 17).withUnsafeBufferPointer { buffer in
        try worker.process(buffer, interval: source) { _ in
            #expect(throws: YINError.reentrantCall) {
                try worker.process(buffer, interval: source) { _ in }
            }
            #expect(throws: YINError.reentrantCall) { try worker.finish { _ in } }
            #expect(throws: YINError.reentrantCall) { try worker.reset(for: reset) }
            #expect(throws: YINError.reentrantCall) {
                try worker.reconfigure(to: profile, epoch: next)
            }
        }
    }
    let replacement = YINProfile(
        estimator: try YINConfiguration(
            sampleRate: 4000,
            pitchFloorHz: 250, pitchCeilingHz: 1000, hopLength: 33, differenceBackend: .scalar,
            partialWindowPolicy: .discard))
    try worker.reconfigure(to: replacement, epoch: next)
    #expect(worker.identity != (try profile.identity()) && worker.nextInputSample == 0)
    let empty = try worker.finish { _ in Issue.record("Empty finish emitted") }
    #expect(empty.framing.disposition == .empty && empty.framing.observedSource.sampleCount == 0)
    let finalEpoch = try next.successor()
    try worker.reset(
        for: SourceDiscontinuity(previousEpoch: next, nextEpoch: finalEpoch, reason: .explicitReset)
    )
    var outputs: [YINCapture] = []
    try [Double](repeating: 0, count: 68).withUnsafeBufferPointer {
        try worker.process(
            $0,
            interval: SourceInterval(
                epoch: finalEpoch, startSample: 0, sampleCount: 68, sampleRate: 4000)
        ) { outputs.append(YINCapture($0)) }
    }
    let end = try worker.finish { _ in Issue.record("Discarded partial emitted") }
    #expect(outputs.count == 2 && outputs.allSatisfy { $0.tracked == nil })
    #expect(
        end.framing.disposition == .discardedPartial && end.framing.tailSource?.sampleCount == 2)
}
