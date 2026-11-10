import Foundation
import HDXLVoiceProcessing
import Testing

private let extendedFramingLength = 131_072

private func extendedFramingConfiguration(
    precision: AnalysisPrecision, policy: PartialWindowPolicy = .emitUnavailable
) throws -> FramingConfiguration {
    try FramingConfiguration(
        window: WindowSpecification(
            definition: .rectangular, sampleCount: extendedFramingLength,
            sampleRate: 192_000, precision: precision),
        hopLength: 32_771, partialWindowPolicy: policy)
}

private func checkExtendedFraming<Sample: BinaryFloatingPoint & Sendable>(
    _: Sample.Type, precision: AnalysisPrecision
) throws {
    let length = extendedFramingLength
    let configuration = try extendedFramingConfiguration(precision: precision)
    let hop = configuration.hopLength
    let input = (0..<(length + 2 * hop + 13)).map { Sample($0 % 8191 - 4095) / 8 }
    let expectedStarts = [0, hop, 2 * hop, 3 * hop]
    let epoch = StreamEpoch(streamID: UUID())
    // Exercise both ordinary time and the final representable input interval.
    for origin in [Int64(0), Int64.max - Int64(input.count)] {
        for chunks in [[input.count], [17], [1, 131_071, 43, 2, 257]] {
            let framer = try PCMFramer<Sample>(
                configuration: configuration, epoch: epoch, startSample: origin)
            let bytes = precision == .float32 ? 1_572_864 : 3_145_728
            #expect(framer.preparedBufferBytes == bytes)
            var supports: [PCMFrameSupport] = []
            func emit(_ values: UnsafeBufferPointer<Sample>, _ support: PCMFrameSupport) {
                let ordinal = supports.count
                guard ordinal < expectedStarts.count else {
                    Issue.record("Unexpected extra frame")
                    return
                }
                let start = expectedStarts[ordinal]
                let end = min(start + length, input.count)
                #expect(values.elementsEqual(input[start..<end]))
                #expect(support.frameIndex == UInt64(ordinal))
                #expect(support.source.startSample == origin + Int64(start))
                #expect(support.source.endSample == origin + Int64(end))
                #expect(support.nominalSampleCount == length)
                #expect(support.missingSampleCount == length - (end - start))
                #expect(support.unavailability == (ordinal == 3 ? .insufficientData : nil))
                supports.append(support)
            }
            try input.withUnsafeBufferPointer { buffer in
                var offset = 0
                var part = 0
                while offset < input.count {
                    let count = min(chunks[part % chunks.count], input.count - offset)
                    let report = try framer.process(
                        UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                        interval: SourceInterval(
                            epoch: epoch, startSample: origin + Int64(offset),
                            sampleCount: Int64(count), sampleRate: 192_000), emit: emit)
                    #expect(report.consumedSampleCount == count)
                    offset += count
                    part += 1
                }
            }
            let completion = try framer.finish(emit: emit)
            #expect(completion.completeFrameCount == 3)
            #expect(completion.disposition == .unavailablePartial)
            #expect(completion.observedSource.sampleCount == Int64(input.count))
            #expect(completion.tailSource == supports.last?.source)
            #expect(supports.count == 4)
            #expect(framer.preparedBufferBytes == bytes)
            #expect(try framer.finish { _, _ in Issue.record("Repeated tail") } == completion)
            framer.cancel()
            #expect(framer.preparedBufferBytes == 0)
        }
    }

    // A discontinuity must discard a nearly full previous frame, including at the new bound.
    let framer = try PCMFramer<Sample>(configuration: configuration, epoch: epoch)
    _ = try input.withUnsafeBufferPointer { buffer in
        try framer.process(
            UnsafeBufferPointer(rebasing: buffer[..<(length - 1)]),
            interval: SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: Int64(length - 1), sampleRate: 192_000)
        ) { _, _ in Issue.record("Premature full frame") }
    }
    let previousWindow = framer.preparedWindow
    let next = try epoch.successor()
    try framer.reset(
        for: SourceDiscontinuity(previousEpoch: epoch, nextEpoch: next, reason: .explicitReset))
    #expect(framer.preparedWindow === previousWindow)
    let replacement = [Sample](repeating: -7, count: length + 100)
    let report = try replacement.withUnsafeBufferPointer { buffer in
        try framer.process(
            buffer,
            interval: SourceInterval(
                epoch: next, startSample: 0, sampleCount: Int64(buffer.count), sampleRate: 192_000)
        ) { values, support in
            #expect(support.source.epoch == next)
            #expect(support.frameIndex == 0)
            #expect(support.source.startSample == 0)
            framer.cancel()
            // Cancellation releases the framer's ownership, but cannot invalidate this borrow.
            #expect(values.count == length)
            #expect(values.allSatisfy { $0 == -7 })
            #expect(framer.preparedBufferBytes == 0)
        }
    }
    #expect(report.consumedSampleCount == length)
    #expect(report.emittedFrameCount == 1)
    #expect(report.isCancelled)
    #expect(throws: FramingError.invalidState) { try framer.finish { _, _ in } }

    // Reset after cancellation prepares fresh storage; discard still exposes actual tail support.
    let last = try next.successor()
    try framer.reset(
        for: SourceDiscontinuity(previousEpoch: next, nextEpoch: last, reason: .explicitReset))
    #expect(framer.preparedWindow !== previousWindow)
    #expect(framer.preparedBufferBytes > 0)
    let discarded = try PCMFramer<Sample>(
        configuration: extendedFramingConfiguration(precision: precision, policy: .discard),
        epoch: last)
    for worker in [framer, discarded] {
        _ = try replacement.withUnsafeBufferPointer { buffer in
            try worker.process(
                UnsafeBufferPointer(rebasing: buffer[..<13]),
                interval: SourceInterval(
                    epoch: last, startSample: 0, sampleCount: 13, sampleRate: 192_000)
            ) { _, _ in Issue.record("Premature frame after reset") }
        }
    }
    var tails = 0
    let end = try framer.finish { values, support in
        #expect(values.elementsEqual(replacement[..<13]))
        #expect(support.source.startSample == 0)
        #expect(support.unavailability == .insufficientData)
        tails += 1
    }
    #expect(tails == 1)
    #expect(end.tailSource?.sampleCount == 13)
    let discardEnd = try discarded.finish { _, _ in Issue.record("Discarded tail emitted") }
    #expect(discardEnd.disposition == .discardedPartial)
    #expect(discardEnd.tailSource?.sampleCount == 13)
}

@Test func extendedFramingFloatPreservesMaximumOverlapAndLifecycle() throws {
    try checkExtendedFraming(Float.self, precision: .float32)
}

@Test func extendedFramingDoublePreservesMaximumOverlapAndLifecycle() throws {
    try checkExtendedFraming(Double.self, precision: .float64)
}

@Test func extendedFramingCodableBoundAndHistoricalIdentity() throws {
    #expect(WindowSpecification.maximumSampleCount == 131_072)
    for precision in [AnalysisPrecision.float32, .float64] {
        let configuration = try extendedFramingConfiguration(precision: precision)
        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(FramingConfiguration.self, from: encoded)
        #expect(decoded == configuration)
        #expect(try decoded.identity() == configuration.identity())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var window = try #require(object["window"] as? [String: Any])
        for count in [0, -1, 131_073, Int.max] {
            #expect(throws: ContractError.invalidConfiguration) {
                try WindowSpecification(
                    definition: .rectangular, sampleCount: count, sampleRate: 192_000,
                    precision: precision)
            }
            window["sampleCount"] = count
            object["window"] = window
            let invalid = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(FramingConfiguration.self, from: invalid)
            }
        }
    }
    // Literal canonical JSON/hash from the version-1 contract, independent of the new bound.
    let historical = try WindowSpecification(
        definition: .rectangular, sampleCount: 65_536, sampleRate: 16_000, precision: .float32)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    #expect(
        String(decoding: try encoder.encode(historical), as: UTF8.self)
            == #"{"definition":"rectangular","precision":"float32","sampleCount":65536,"sampleRate":16000}"#
    )
    #expect(
        try historical.identity().sha256
            == "b3200cfa43e2c8058cc1132db98049d14c532f25daf604a25fe50af8f88f769d")
}
