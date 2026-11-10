import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func swipeStreamOrigin(
    _ c: SWIPEPrimeConfiguration, epoch: StreamEpoch, start: Int64 = 0,
    seconds: Double? = nil, host: UInt64? = nil
) throws -> AnalysisTiming {
    try AnalysisTiming(
        source: SourceInterval(
            epoch: epoch, startSample: start, sampleCount: 0,
            sampleRate: Double(c.sampleRate)),
        includedSampleCount: 0, sourceStartSeconds: seconds, hostStartNanoseconds: host)
}

private struct SWIPEStreamCapture: Equatable {
    let result: SWIPEPrimeFrameResult
    let strengths: [Double?]
    init(_ output: BorrowedSWIPEPrimeOutput) {
        result = output.result
        strengths = Array(output.candidateStrengths)
    }
}

private func swipeStream<Sample: BinaryFloatingPoint & Sendable>(
    _ samples: [Sample], configuration: SWIPEPrimeConfiguration, origin: AnalysisTiming,
    chunks: [Int]
) throws -> ([SWIPEStreamCapture], SWIPEPrimeCompletion) {
    let worker = try PreparedSWIPEPrimeAnalyzer<Sample>(
        configuration: configuration, origin: origin)
    let preparedBytes = worker.preparedBufferBytes
    #expect(preparedBytes > 0 && preparedBytes < 64 * 1024 * 1024)
    var results: [SWIPEStreamCapture] = []
    var offset = 0
    var index = 0
    try samples.withUnsafeBufferPointer { input in
        while offset < input.count {
            let count = min(chunks[index % chunks.count], input.count - offset)
            let interval = try SourceInterval(
                epoch: worker.epoch, startSample: origin.source.startSample + Int64(offset),
                sampleCount: Int64(count), sampleRate: origin.source.sampleRate)
            let report = try worker.process(
                UnsafeBufferPointer(rebasing: input[offset..<offset + count]), interval: interval
            ) { results.append(SWIPEStreamCapture($0)) }
            #expect(report.consumedSampleCount == count && !report.isCancelled)
            #expect(worker.preparedBufferBytes == preparedBytes)
            offset += count
            index += 1
        }
    }
    let end = try worker.finish { results.append(SWIPEStreamCapture($0)) }
    #expect(try worker.finish { _ in Issue.record("Repeated finish emitted") } == end)
    #expect(worker.nextInputSample == origin.source.startSample + Int64(samples.count))
    #expect(worker.preparedBufferBytes == preparedBytes)
    worker.cancel()
    #expect(worker.preparedBufferBytes == 0 && worker.estimatorStatistics == nil)
    return (results, end)
}

private func checkMaximumSWIPEStreaming<Sample: BinaryFloatingPoint & Sendable>(
    _ sampleType: Sample.Type, precision: AnalysisPrecision
) throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 192000, inputPrecision: precision, pitchFloorHz: 20, pitchCeilingHz: 48000,
        hopLength: 1920, candidatesPerOctave: 192)
    #expect(c.requiredSampleCount == 131072)
    let origin = try swipeStreamOrigin(c, epoch: StreamEpoch(streamID: UUID()), start: 123)
    let samples = (0..<131072 + 1920 + 7).map { index -> Sample in
        let phase = 2 * Double.pi * 200 * Double(index) / 192000
        return Sample(0.4 * sin(phase) + 0.1 * sin(2 * phase))
    }
    let direct = try PreparedSWIPEPrime<Sample>(c)
    let streamed = try PreparedSWIPEPrimeAnalyzer<Sample>(configuration: c, origin: origin)
    #expect(
        streamed.preparedBufferBytes == direct.executionStatistics.preparedBufferBytes
            + 3 * 131072 * MemoryLayout<Sample>.stride)
    #expect(streamed.preparedBufferBytes < 64 * 1024 * 1024)
    streamed.cancel()
    #expect(streamed.preparedBufferBytes == 0)

    // Literal slices independently specify two full frames and the earliest
    // nonempty partial tail at the advertised maximum support.
    var expected: [SWIPEStreamCapture] = []
    try samples.withUnsafeBufferPointer { input in
        for (index, start) in [0, 1920, 3840].enumerated() {
            let end = min(start + 131072, input.count)
            let timing = try AnalysisTiming(
                source: SourceInterval(
                    epoch: origin.source.epoch, startSample: 123 + Int64(start),
                    sampleCount: Int64(end - start), sampleRate: 192000),
                includedSampleCount: Int64(end - start))
            try direct.analyze(
                UnsafeBufferPointer(rebasing: input[start..<end]), timing: timing,
                frameIndex: UInt64(index)
            ) { expected.append(SWIPEStreamCapture($0)) }
        }
    }
    let whole = try swipeStream(
        samples, configuration: c, origin: origin, chunks: [samples.count])
    let partitioned = try swipeStream(
        samples, configuration: c, origin: origin, chunks: [1, 17, 4093, 2, 8191])
    #expect(whole.0 == expected && partitioned.0 == expected)
    #expect(whole.1 == partitioned.1 && whole.1.framing.completeFrameCount == 2)
    #expect(whole.1.framing.disposition == .unavailablePartial)
    #expect(expected.count == 3)
    #expect(expected[0].result.status == .voiced && expected[1].result.status == .voiced)
    #expect(expected[2].result.status == .unavailable)
    #expect(expected[2].result.timing.source.startSample == 3963)
    #expect(expected[2].result.timing.source.sampleCount == 129159)
}

@Test func swipePrimeMaximumFloatStreamingPreservesDirectResultsAndBoundedStorage() throws {
    try checkMaximumSWIPEStreaming(Float.self, precision: .float32)
}

@Test func swipePrimeMaximumDoubleStreamingPreservesDirectResultsAndBoundedStorage() throws {
    try checkMaximumSWIPEStreaming(Double.self, precision: .float64)
}

@Test func swipePrimeStreamingChunksPreserveEveryCandidateAndClock() throws {
    for rate in [16000, 44100, 48000] {
        for precision in [AnalysisPrecision.float32, .float64] {
            let c = try SWIPEPrimeConfiguration(
                sampleRate: rate, inputPrecision: precision, pitchFloorHz: rate == 48000 ? 25 : 50,
                pitchCeilingHz: rate == 48000 ? 2000 : 700,
                hopLength: Int((Double(rate) * 0.005).rounded()))
            let origin = try swipeStreamOrigin(
                c, epoch: StreamEpoch(streamID: UUID()), start: 123, seconds: 41.25,
                host: 1_000_000_000)
            let count = c.requiredSampleCount + 3 * c.hopLength + 7
            let samples = (0..<count).map { index in
                let t = Double(index) / Double(rate)
                return 0.4 * sin(2 * .pi * (137 * t + 8 * t * t)) + 0.1 * sin(2 * .pi * 274 * t)
            }
            let batch: ([SWIPEStreamCapture], SWIPEPrimeCompletion)
            let chunked: ([SWIPEStreamCapture], SWIPEPrimeCompletion)
            if precision == .float32 {
                batch = try swipeStream(
                    samples.map(Float.init), configuration: c, origin: origin, chunks: [count])
                chunked = try swipeStream(
                    samples.map(Float.init), configuration: c, origin: origin,
                    chunks: [1, 7, 251, 2, 64, 509])
            } else {
                batch = try swipeStream(samples, configuration: c, origin: origin, chunks: [count])
                chunked = try swipeStream(
                    samples, configuration: c, origin: origin, chunks: [1, 7, 251, 2, 64, 509])
            }
            #expect(batch.0 == chunked.0 && batch.1 == chunked.1)
            #expect(batch.0.count == 5 && batch.1.framing.completeFrameCount == 4)
            #expect(batch.1.framing.disposition == .unavailablePartial)
            #expect(
                batch.0.allSatisfy {
                    $0.result.timing.sourceStartSeconds != nil
                        && $0.result.timing.hostStartNanoseconds != nil
                })
        }
    }
}

@Test func swipePrimeStreamingGapDiscardsPendingPCMAndReusesPreparedStorage() throws {
    let c = try SWIPEPrimeConfiguration(sampleRate: 16000, hopLength: 80)
    let epoch = StreamEpoch(streamID: UUID())
    let worker = try PreparedSWIPEPrimeAnalyzer<Double>(configuration: c, epoch: epoch)
    let oldCount = c.requiredSampleCount + 20
    let old = (0..<oldCount).map { 0.4 * sin(2 * .pi * 100 * Double($0) / 16000) }
    var before = 0
    try old.withUnsafeBufferPointer {
        _ = try worker.process(
            $0,
            interval: SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: Int64(oldCount), sampleRate: 16000)
        ) { _ in before += 1 }
    }
    #expect(before == 1)
    let next = try epoch.successor()
    let gap = try SourceDiscontinuity(
        previousEpoch: epoch, nextEpoch: next, reason: .droppedAudio,
        missingSource: SourceInterval(
            epoch: epoch, startSample: Int64(oldCount), sampleCount: 37, sampleRate: 16000))
    let origin = try swipeStreamOrigin(c, epoch: next, seconds: 90, host: 2_000_000_000)
    let bytes = worker.preparedBufferBytes
    try worker.reset(for: gap, clockOrigin: origin)
    #expect(worker.nextInputSample == 0 && worker.preparedBufferBytes == bytes)
    let samples = (0..<c.requiredSampleCount + 80).map {
        0.4 * sin(2 * .pi * 300 * Double($0) / 16000)
    }
    var after: [SWIPEStreamCapture] = []
    try samples.withUnsafeBufferPointer {
        _ = try worker.process(
            $0,
            interval: SourceInterval(
                epoch: next, startSample: 0, sampleCount: Int64(samples.count), sampleRate: 16000)
        ) { after.append(SWIPEStreamCapture($0)) }
    }
    let completion = try worker.finish { after.append(SWIPEStreamCapture($0)) }
    let fresh = try swipeStream(samples, configuration: c, origin: origin, chunks: [samples.count])
    #expect(after == fresh.0 && completion == fresh.1)
    #expect(after[0].result.timing.source.epoch == next && after[0].result.frameIndex == 0)
    #expect(abs((after[0].result.observation?.frequencyHz ?? 0) - 300) < 5)
}

@Test func swipePrimeStreamingCancellationKeepsBorrowAliveAndStopsConsumption() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let epoch = StreamEpoch(streamID: UUID())
    let worker = try PreparedSWIPEPrimeAnalyzer<Double>(configuration: c, epoch: epoch)
    let samples: [Double] = (0..<100).map { [1.0, 0, -1, 0][$0 % 4] }
    var emissions = 0
    let report = try samples.withUnsafeBufferPointer {
        try worker.process(
            $0,
            interval: SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: 100, sampleRate: 4000)
        ) { output in
            emissions += 1
            let expected = Array(output.candidateStrengths)
            let spectrum = Array(output.windows[0].magnitude)
            worker.cancel()
            worker.cancel()
            #expect(
                Array(output.candidateStrengths) == expected
                    && Array(output.windows[0].magnitude) == spectrum)
            #expect(output.result.observation != nil)
        }
    }
    #expect(
        emissions == 1 && report.emittedFrameCount == 1
            && report.consumedSampleCount == c.requiredSampleCount)
    #expect(report.isCancelled && worker.nextInputSample == Int64(c.requiredSampleCount))
    #expect(worker.preparedBufferBytes == 0 && worker.estimatorStatistics == nil)
    #expect(throws: SWIPEPrimeError.invalidState) { try worker.finish { _ in } }
    let next = try epoch.successor()
    try worker.reset(
        for: SourceDiscontinuity(previousEpoch: epoch, nextEpoch: next, reason: .explicitReset))
    #expect(worker.preparedBufferBytes > 0 && worker.nextInputSample == 0)
    let partial = c.requiredSampleCount - 1
    try samples.withUnsafeBufferPointer {
        _ = try worker.process(
            UnsafeBufferPointer(rebasing: $0[..<partial]),
            interval: SourceInterval(
                epoch: next, startSample: 0, sampleCount: Int64(partial), sampleRate: 4000)
        ) { _ in Issue.record("Partial emitted early") }
    }
    let end = try worker.finish { output in
        worker.cancel()
        #expect(output.result.unavailability == .insufficientData && output.windows.isEmpty)
    }
    #expect(
        end.isCancelled && end.framing.disposition == .unavailablePartial
            && worker.preparedBufferBytes == 0)
}

@Test func swipePrimeStreamingClockValidationIsTransactionalAtIntegerLimits() throws {
    let c = try SWIPEPrimeConfiguration(sampleRate: 44100, hopLength: 221)
    let epoch = StreamEpoch(streamID: UUID())
    let count = c.requiredSampleCount + 2 * c.hopLength
    let start = Int64.max - Int64(count)
    let origin = try swipeStreamOrigin(
        c, epoch: epoch, start: start, seconds: 123.5, host: 1_000_000_000)
    let worker = try PreparedSWIPEPrimeAnalyzer<Double>(configuration: c, origin: origin)
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
    var results: [SWIPEStreamCapture] = []
    try samples.withUnsafeBufferPointer {
        _ = try worker.process($0, interval: interval, completedHostNanoseconds: 2_000_000_000) {
            results.append(SWIPEStreamCapture($0))
        }
    }
    #expect(worker.nextInputSample == Int64.max && results.count == 3)
    for (index, frame) in results.enumerated() {
        let displacement = index * c.hopLength
        #expect(frame.result.timing.source.startSample == start + Int64(displacement))
        #expect(frame.result.timing.sourceStartSeconds == 123.5 + Double(displacement) / 44100)
        let nanos = (UInt64(displacement) * 1_000_000_000 + 22050) / 44100
        #expect(frame.result.timing.hostStartNanoseconds == 1_000_000_000 + nanos)
        #expect(frame.result.timing.completedHostNanoseconds == 2_000_000_000)
    }
    try worker.finish { output in #expect(output.result.timing.completedHostNanoseconds == nil) }
    let overflowOrigin = try swipeStreamOrigin(
        c, epoch: StreamEpoch(streamID: UUID()), host: UInt64.max - 1)
    let overflow = try PreparedSWIPEPrimeAnalyzer<Double>(configuration: c, origin: overflowOrigin)
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

@Test func swipePrimeStreamingReconfigurationReentrancyAndTailPolicies() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let epoch = StreamEpoch(streamID: UUID())
    let next = try epoch.successor()
    let worker = try PreparedSWIPEPrimeAnalyzer<Double>(configuration: c, epoch: epoch)
    let wrongPrecision = try SWIPEPrimeConfiguration(
        sampleRate: 4000, inputPrecision: .float32, pitchFloorHz: 500, pitchCeilingHz: 1000,
        hopLength: 4)
    #expect(throws: SWIPEPrimeError.precisionMismatch) {
        try worker.reconfigure(to: wrongPrecision, epoch: next)
    }
    #expect(worker.configuration == c && worker.epoch == epoch)
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: Int64(c.requiredSampleCount), sampleRate: 4000)
    let reset = try SourceDiscontinuity(
        previousEpoch: epoch, nextEpoch: next, reason: .explicitReset)
    var invalid = Array(repeating: 0.0, count: c.requiredSampleCount)
    invalid[invalid.count - 1] = .nan
    #expect(throws: SWIPEPrimeError.invalidInput) {
        try invalid.withUnsafeBufferPointer { try worker.process($0, interval: source) { _ in } }
    }
    #expect(worker.nextInputSample == 0)
    try Array(repeating: 0.0, count: c.requiredSampleCount).withUnsafeBufferPointer { buffer in
        _ = try worker.process(buffer, interval: source) { _ in
            #expect(throws: SWIPEPrimeError.reentrantCall) {
                try worker.process(buffer, interval: source) { _ in }
            }
            #expect(throws: SWIPEPrimeError.reentrantCall) { try worker.finish { _ in } }
            #expect(throws: SWIPEPrimeError.reentrantCall) { try worker.reset(for: reset) }
            #expect(throws: SWIPEPrimeError.reentrantCall) {
                try worker.reconfigure(to: c, epoch: next)
            }
        }
    }
    let replacement = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 250, pitchCeilingHz: 1000, hopLength: 33,
        partialWindowPolicy: .discard)
    try worker.reconfigure(to: replacement, epoch: next)
    #expect(worker.identity != (try c.identity()) && worker.nextInputSample == 0)
    let empty = try worker.finish { _ in Issue.record("Empty finish emitted") }
    #expect(empty.framing.disposition == .empty && empty.framing.observedSource.sampleCount == 0)
    #expect(throws: SWIPEPrimeError.invalidState) {
        try [Double]().withUnsafeBufferPointer {
            try worker.process(
                $0,
                interval: SourceInterval(
                    epoch: next, startSample: 0, sampleCount: 0, sampleRate: 4000)
            ) { _ in }
        }
    }
    let final = try next.successor()
    try worker.reset(
        for: SourceDiscontinuity(previousEpoch: next, nextEpoch: final, reason: .explicitReset))
    let count = replacement.requiredSampleCount + replacement.hopLength + 2
    var outputs = 0
    try Array(repeating: 0.0, count: count).withUnsafeBufferPointer {
        _ = try worker.process(
            $0,
            interval: SourceInterval(
                epoch: final, startSample: 0, sampleCount: Int64(count), sampleRate: 4000)
        ) { _ in outputs += 1 }
    }
    let end = try worker.finish { _ in Issue.record("Discarded partial emitted") }
    #expect(outputs == 2 && end.framing.disposition == .discardedPartial)
    #expect(
        end.framing.tailSource?.sampleCount
            == Int64(replacement.requiredSampleCount - replacement.hopLength + 2))
}
