import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let framingEpoch = StreamEpoch(
    streamID: UUID(uuidString: "e4459d9a-7fa9-486d-92a3-997204431556")!)

private func framingConfiguration(
    length: Int = 4, hop: Int = 2, offset: Int = 0, rate: Double = 16_000,
    policy: PartialWindowPolicy = .emitUnavailable, precision: AnalysisPrecision = .float64
) throws -> FramingConfiguration {
    try FramingConfiguration(
        window: WindowSpecification(
            definition: .rectangular,
            sampleCount: length, sampleRate: rate, precision: precision), hopLength: hop,
        firstFrameOffsetSamples: offset, partialWindowPolicy: policy)
}

private struct CapturedFrame: Equatable {
    let samples: [Double]
    let support: PCMFrameSupport
}

private func captureFrames(
    _ samples: [Double], configuration: FramingConfiguration, partitions: [Int],
    epoch: StreamEpoch = framingEpoch, start: Int64 = 0
) throws -> ([CapturedFrame], FramingCompletion) {
    let framer = try PCMFramer<Double>(
        configuration: configuration, epoch: epoch, startSample: start)
    var frames: [CapturedFrame] = []
    func emit(_ values: UnsafeBufferPointer<Double>, _ support: PCMFrameSupport) {
        frames.append(CapturedFrame(samples: Array(values), support: support))
    }
    try samples.withUnsafeBufferPointer { buffer in
        var offset = 0
        var part = 0
        while offset < samples.count {
            let count = min(partitions[part % partitions.count], samples.count - offset)
            let interval = try SourceInterval(
                epoch: epoch, startSample: start + Int64(offset),
                sampleCount: Int64(count), sampleRate: configuration.window.sampleRate)
            let report = try framer.process(
                UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                interval: interval, emit: emit)
            #expect(report.consumedSampleCount == count)
            #expect(!report.isCancelled)
            offset += count
            part += 1
        }
    }
    let end = try framer.finish(emit: emit)
    #expect(try framer.finish { _, _ in Issue.record("Repeated finish emitted a frame") } == end)
    return (frames, end)
}

@Test func framingMatchesIndependentIntegerSlicesAcrossPartitions() throws {
    var seed: UInt64 = 42
    let random = (0..<71).map { _ -> Int in
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return 1 + Int((seed >> 32) % 37)
    }
    let partitions = [[10_000], [1], [17], [1, 43, 2, 9], random]
    let samples = (0..<239).map { Double($0) / 17 - 3 }
    for rate in [16_000.0, 44_100, 48_000] {
        for length in [1, 4, 17] {
            for hop in [1, 2, 7, 23] {
                for offset in [0, 3, 250] {
                    let config = try framingConfiguration(
                        length: length, hop: hop, offset: offset, rate: rate)
                    let expectedStarts = stride(
                        from: offset, through: samples.count - length, by: hop
                    ).map { $0 }
                    let expectedTail = offset + expectedStarts.count * hop
                    let full = try captureFrames(
                        samples, configuration: config, partitions: partitions[0], start: 100)
                    #expect(full.1.completeFrameCount == UInt64(expectedStarts.count))
                    #expect(full.1.observedSource.sampleCount == Int64(samples.count))
                    for (ordinal, start) in expectedStarts.enumerated() {
                        let frame = full.0[ordinal]
                        #expect(frame.samples == Array(samples[start..<(start + length)]))
                        #expect(frame.support.frameIndex == UInt64(ordinal))
                        #expect(frame.support.source.startSample == Int64(100 + start))
                        #expect(frame.support.source.endSample == Int64(100 + start + length))
                        #expect(frame.support.unavailability == nil)
                    }
                    if expectedTail < samples.count {
                        #expect(full.0.last?.samples == Array(samples[expectedTail...]))
                        #expect(full.0.last?.support.unavailability == .insufficientData)
                        #expect(full.1.disposition == .unavailablePartial)
                    } else {
                        #expect(full.1.tailSource == nil)
                    }
                    for partition in partitions.dropFirst() {
                        let chunked = try captureFrames(
                            samples, configuration: config, partitions: partition, start: 100)
                        #expect(chunked.0 == full.0)
                        #expect(chunked.1 == full.1)
                    }
                }
            }
        }
    }
}

@Test func framingImpulsesAtEveryBoundaryAndConstantsKeepExactSupport() throws {
    let config = try framingConfiguration(length: 5, hop: 3)
    for position in 0..<25 {
        var samples = [Double](repeating: 0, count: 25)
        samples[position] = 1
        let frames = try captureFrames(samples, configuration: config, partitions: [2, 1]).0
        for frame in frames {
            let start = Int(frame.support.source.startSample)
            #expect(frame.samples == Array(samples[start..<(start + frame.samples.count)]))
            #expect(
                frame.samples.reduce(0, +)
                    == (start..<(start + frame.samples.count) ~= position ? 1 : 0))
        }
    }
    let frames = try captureFrames(
        Array(repeating: 7.0, count: 23), configuration: config, partitions: [1]
    ).0
    #expect(frames.allSatisfy { $0.samples.allSatisfy { $0 == 7 } })
}

@Test func framingEmptySingletonTailAndDiscardAreExplicit() throws {
    for policy in [PartialWindowPolicy.discard, .emitUnavailable] {
        let config = try framingConfiguration(policy: policy)
        let empty = try captureFrames([], configuration: config, partitions: [1])
        #expect(empty.0.isEmpty)
        #expect(empty.1.disposition == .empty)
        for count in [1, 3, 4, 5, 6] {
            let result = try captureFrames(
                Array(repeating: 0, count: count), configuration: config, partitions: [1])
            #expect(result.1.observedSource.sampleCount == Int64(count))
            #expect(
                result.1.disposition
                    == (policy == .discard ? .discardedPartial : .unavailablePartial))
            #expect(result.1.tailSource?.sampleCount == Int64(count < 4 ? count : 2 + count % 2))
            if policy == .emitUnavailable {
                #expect(result.0.last?.support.unavailability == .insufficientData)
                #expect(result.0.last!.samples.count < 4)
            } else {
                #expect(result.0.allSatisfy { $0.support.unavailability == nil })
            }
        }
    }
    let single = try captureFrames(
        [4], configuration: framingConfiguration(length: 1, hop: 1), partitions: [1])
    #expect(single.0.count == 1)
    #expect(single.1.disposition == .complete)
    let skipped = try captureFrames(
        [4], configuration: framingConfiguration(offset: 2), partitions: [1])
    #expect(skipped.0.isEmpty)
    #expect(skipped.1.disposition == .noEligibleFrame)
}

@Test func framingGapResetNeverReusesPreviousSamples() throws {
    for partition in [[3], [1, 1, 1], [2, 1]] {
        let framer = try PCMFramer<Double>(
            configuration: framingConfiguration(), epoch: framingEpoch)
        let window = framer.preparedWindow
        var frames: [CapturedFrame] = []
        func process(_ values: [Double], start: Int64, epoch: StreamEpoch) throws {
            _ = try values.withUnsafeBufferPointer { input in
                try framer.process(
                    input,
                    interval: SourceInterval(
                        epoch: epoch, startSample: start,
                        sampleCount: Int64(values.count), sampleRate: 16_000)
                ) {
                    frames.append(CapturedFrame(samples: Array($0), support: $1))
                }
            }
        }
        var oldCount = 0
        for count in partition {
            try process(
                Array(repeating: 99, count: count), start: Int64(oldCount), epoch: framingEpoch)
            oldCount += count
        }
        #expect(throws: FramingError.unexpectedInterval) {
            try process([1, 2], start: Int64(oldCount + 3), epoch: framingEpoch)
        }
        let next = try framingEpoch.successor()
        let gap = try SourceDiscontinuity(
            previousEpoch: framingEpoch, nextEpoch: next, reason: .droppedAudio,
            missingSource: SourceInterval(
                epoch: framingEpoch, startSample: Int64(oldCount), sampleCount: 3,
                sampleRate: 16_000))
        try framer.reset(for: gap)
        #expect(framer.preparedWindow === window)
        #expect(framer.nextInputSample == 0)
        try process([1, 2], start: 0, epoch: next)
        #expect(frames.isEmpty)
        try process([3, 4], start: 2, epoch: next)
        #expect(frames.first?.samples == [1, 2, 3, 4])
        #expect(frames.first?.support.source.epoch == next)
        #expect(frames.first?.support.source.startSample == 0)
        let end = try framer.finish {
            frames.append(CapturedFrame(samples: Array($0), support: $1))
        }
        #expect(end.observedSource.sampleCount == 4)
        #expect(frames.last?.samples == [3, 4])
    }
}

@Test func framingValidationIsTransactionalAndLifecycleIsExplicit() throws {
    let config = try framingConfiguration()
    let framer = try PCMFramer<Double>(configuration: config, epoch: framingEpoch)
    let window = framer.preparedWindow
    let interval = try SourceInterval(
        epoch: framingEpoch, startSample: 0, sampleCount: 4, sampleRate: 16_000)
    for bad in [[1.0, 2, .nan, 4], [1, 2, 3, .infinity]] {
        #expect(throws: FramingError.nonfiniteSample) {
            try bad.withUnsafeBufferPointer {
                try framer.process($0, interval: interval) { _, _ in
                    Issue.record("invalid emission")
                }
            }
        }
        #expect(framer.nextInputSample == 0)
    }
    #expect(throws: FramingError.precisionMismatch) {
        try framer.reconfigure(
            to: framingConfiguration(precision: .float32), epoch: framingEpoch.successor())
    }
    #expect(framer.configuration == config)
    #expect(framer.preparedWindow === window)
    #expect(framer.epoch == framingEpoch)
    let values = [1.0, 2, 3, 4]
    var actual: [Double] = []
    _ = try values.withUnsafeBufferPointer { buffer in
        try framer.process(buffer, interval: interval) {
            actual = Array($0)
            _ = $1
        }
    }
    #expect(actual == values)
    _ = try framer.finish { _, _ in }
    #expect(throws: FramingError.invalidState) {
        try values.withUnsafeBufferPointer {
            try framer.process($0, interval: interval) { _, _ in }
        }
    }
    let next = try framingEpoch.successor()
    try framer.reconfigure(to: framingConfiguration(length: 2, hop: 2), epoch: next)
    #expect(framer.epoch == next)
    #expect(framer.configuration.window.sampleCount == 2)
    framer.cancel()
    framer.cancel()
    #expect(framer.preparedWindow == nil)
    #expect(throws: FramingError.invalidState) { try framer.finish { _, _ in } }
    try framer.reset(
        for: SourceDiscontinuity(
            previousEpoch: next, nextEpoch: next.successor(), reason: .explicitReset))
    #expect(framer.preparedWindow != nil)
    #expect(framer.nextInputSample == 0)
}

@Test func framingCancellationKeepsActiveBorrowAliveAndRejectsReentry() throws {
    let framer = try PCMFramer<Double>(configuration: framingConfiguration(), epoch: framingEpoch)
    weak var borrowedWindow = framer.preparedWindow
    let values = Array(0..<30).map(Double.init)
    let interval = try SourceInterval(
        epoch: framingEpoch, startSample: 0, sampleCount: 30, sampleRate: 16_000)
    let report = try values.withUnsafeBufferPointer { input in
        try framer.process(input, interval: interval) { buffer, _ in
            #expect(throws: FramingError.reentrantCall) {
                try framer.process(input, interval: interval) { _, _ in }
            }
            #expect(throws: FramingError.reentrantCall) { try framer.finish { _, _ in } }
            framer.cancel()
            #expect(Array(buffer) == [0, 1, 2, 3])
            #expect(framer.preparedWindow == nil)
            #expect(borrowedWindow != nil)
        }
    }
    #expect(report.consumedSampleCount == 4)
    #expect(report.emittedFrameCount == 1)
    #expect(report.isCancelled)
    #expect(borrowedWindow == nil)
}

@Test func framingCancellationDuringTailEmissionKeepsBorrowAlive() throws {
    let framer = try PCMFramer<Double>(configuration: framingConfiguration(), epoch: framingEpoch)
    weak var borrowedWindow = framer.preparedWindow
    _ = try [3.0, 4].withUnsafeBufferPointer {
        try framer.process(
            $0,
            interval: SourceInterval(
                epoch: framingEpoch, startSample: 0, sampleCount: 2, sampleRate: 16_000)
        ) { _, _ in }
    }
    let completion = try framer.finish { buffer, support in
        framer.cancel()
        #expect(Array(buffer) == [3, 4])
        #expect(support.unavailability == .insufficientData)
        #expect(borrowedWindow != nil)
    }
    #expect(completion.disposition == .unavailablePartial)
    #expect(borrowedWindow == nil)
}

@Test func framingRejectsMismatchedMetadataAndAcceptsEmptyNoOp() throws {
    let config = try framingConfiguration()
    let framer = try PCMFramer<Double>(configuration: config, epoch: framingEpoch)
    let input = [1.0, 2]
    let mismatches = [
        try SourceInterval(epoch: framingEpoch, startSample: 1, sampleCount: 2, sampleRate: 16_000),
        try SourceInterval(epoch: framingEpoch, startSample: 0, sampleCount: 2, sampleRate: 48_000),
        try SourceInterval(epoch: framingEpoch, startSample: 0, sampleCount: 1, sampleRate: 16_000),
        try SourceInterval(
            epoch: framingEpoch.successor(), startSample: 0, sampleCount: 2, sampleRate: 16_000),
    ]
    for interval in mismatches {
        #expect(throws: FramingError.unexpectedInterval) {
            try input.withUnsafeBufferPointer {
                try framer.process($0, interval: interval) { _, _ in
                    Issue.record("invalid emission")
                }
            }
        }
        #expect(framer.nextInputSample == 0)
    }
    let empty = UnsafeBufferPointer<Double>(start: nil, count: 0)
    let report = try framer.process(
        empty,
        interval: SourceInterval(
            epoch: framingEpoch, startSample: 0, sampleCount: 0, sampleRate: 16_000)
    ) { _, _ in Issue.record("empty emission") }
    #expect(report.consumedSampleCount == 0)
    #expect(report.emittedFrameCount == 0)
    #expect(try framer.finish { _, _ in }.disposition == .empty)
}

@Test func framingFloatAndHistoricalMaximumPreparedWindowPreserveSamples() throws {
    let config = try framingConfiguration(length: 65_536, hop: 65_536, precision: .float32)
    let framer = try PCMFramer<Float>(configuration: config, epoch: framingEpoch)
    let input = (0..<65_536).map { Float($0 % 256) / 128 }
    var frames = 0
    try input.withUnsafeBufferPointer { buffer in
        for start in stride(from: 0, to: input.count, by: 17) {
            let end = min(start + 17, input.count)
            try framer.process(
                UnsafeBufferPointer(rebasing: buffer[start..<end]),
                interval: SourceInterval(
                    epoch: framingEpoch, startSample: Int64(start), sampleCount: Int64(end - start),
                    sampleRate: 16_000)
            ) {
                samples, support in
                #expect(Array(samples) == input)
                #expect(support.source.sampleCount == 65_536)
                #expect(support.unavailability == nil)
                frames += 1
            }
        }
    }
    #expect(frames == 1)
    #expect(try framer.finish { _, _ in Issue.record("unexpected tail") }.disposition == .complete)
}

@Test func framingLongTimelinesAndLargeIndicesUseIntegerArithmetic() throws {
    for rate in [16_000.0, 44_100, 48_000] {
        let length = try SampleCountQuantization(seconds: 0.025, sampleRate: rate).sampleCount
        let hop = try SampleCountQuantization(seconds: 0.002, sampleRate: rate)
        let config = try framingConfiguration(length: length, hop: hop.sampleCount, rate: rate)
        let hour = Int64(rate) * 3600
        let count = try config.completeFrameCount(observedSampleCount: hour)
        #expect(count == UInt64((hour - Int64(length)) / Int64(hop.sampleCount) + 1))
        #expect(
            try config.frameStartSample(ordinal: count - 1) == Int64(count - 1)
                * Int64(hop.sampleCount))
        #expect(try config.frameStartSample(ordinal: count - 1) + Int64(length) <= hour)
        #expect(try config.frameStartSample(ordinal: count) + Int64(length) > hour)
        #expect(hop.sampleCount == (rate == 44_100 ? 88 : Int(rate / 500)))
        if rate == 44_100 { #expect(hop.errorSeconds < 0) }
    }
    let result = try captureFrames(
        [1, 2, 3, 4, 5, 6], configuration: framingConfiguration(),
        partitions: [1], start: Int64.max - 6)
    #expect(result.0[0].support.source.startSample == Int64.max - 6)
    #expect(result.0[1].support.source.endSample == Int64.max)
    #expect(result.1.observedSource.sampleCount == 6)
    #expect(result.0.last?.samples == [5, 6])
    #expect(throws: ContractError.arithmeticOverflow) {
        try framingConfiguration().frameStartSample(ordinal: .max)
    }
    #expect(throws: ContractError.arithmeticOverflow) {
        try PCMFramer<Double>(
            configuration: framingConfiguration(offset: 10), epoch: framingEpoch, startSample: .max)
    }
}

@Test func framingConfigurationAndQuantizationSerializeStrictly() throws {
    let configuration = try framingConfiguration(length: 1000, hop: 20, offset: 3, rate: 10_000)
    let encoded = try JSONEncoder().encode(configuration)
    #expect(try JSONDecoder().decode(FramingConfiguration.self, from: encoded) == configuration)
    #expect(
        try JSONDecoder().decode(FramingConfiguration.self, from: encoded).identity()
            == configuration.identity())
    let quantization = try SampleCountQuantization(seconds: 0.5, sampleRate: 3)
    #expect(quantization.sampleCount == 2)
    #expect(
        try SampleCountQuantization(seconds: 0.5, sampleRate: 3, rounding: .down).sampleCount == 1)
    #expect(
        try SampleCountQuantization(seconds: 0.4, sampleRate: 3, rounding: .up).sampleCount == 2)
    let quantized = try JSONEncoder().encode(quantization)
    #expect(try JSONDecoder().decode(SampleCountQuantization.self, from: quantized) == quantization)
    var object = try #require(JSONSerialization.jsonObject(with: quantized) as? [String: Any])
    object["sampleCount"] = 1
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            SampleCountQuantization.self, from: JSONSerialization.data(withJSONObject: object))
    }
    for seconds in [0, -1, .infinity, .nan, Double.leastNonzeroMagnitude] {
        #expect(throws: ContractError.invalidConfiguration) {
            try SampleCountQuantization(seconds: seconds, sampleRate: 1)
        }
    }
    #expect(throws: ContractError.invalidConfiguration) { try framingConfiguration(hop: 0) }
    #expect(throws: ContractError.invalidConfiguration) { try framingConfiguration(offset: -1) }
    #expect(throws: ContractError.invalidConfiguration) {
        try framingConfiguration(length: 131_073)
    }
}
