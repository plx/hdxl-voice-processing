import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let cepstralEpoch = StreamEpoch(
    streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000033")!)

private func previewCepstralConfiguration(
    _ precision: AnalysisPrecision = .float64, hop: Double = 0.005
) throws -> CepstrogramConfiguration {
    try CepstrogramConfiguration(
        sourceSampleRate: 16_000, analysisSampleRate: 4000,
        inputPrecision: precision, pitchFloorHz: 100, hopSeconds: hop,
        declaredInputBandwidthHz: 8000,
        conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
}
private func previewCepstralSource(_ start: Int, _ count: Int, epoch: StreamEpoch = cepstralEpoch)
    throws -> SourceInterval
{
    try SourceInterval(
        epoch: epoch, startSample: Int64(start), sampleCount: Int64(count), sampleRate: 16_000)
}
private func capturePreviewCepstrum<S: BinaryFloatingPoint & Sendable>(
    _ samples: [S], precision: AnalysisPrecision,
    chunk: Int, block: Int = 256
) throws -> (rows: [PowerCepstrumFrame], completion: CepstrogramCompletion) {
    let configuration = try previewCepstralConfiguration(precision)
    let worker = try PreparedPreviewCepstrogram<S>(
        configuration: configuration, epoch: cepstralEpoch, outputBlockCapacity: block)
    let collector = try BoundedCepstrogram(
        configuration: configuration, maximumFrames: 100, maximumScalarCount: 30_000)
    let emit: (BorrowedPowerCepstrum<Double>) -> Void = { output in
        do { try collector.append(output) } catch { Issue.record(error) }
    }
    for start in stride(from: 0, to: samples.count, by: chunk) {
        let count = min(chunk, samples.count - start)
        try samples.withUnsafeBufferPointer {
            _ = try worker.process(
                UnsafeBufferPointer(rebasing: $0[start..<start + count]),
                interval: previewCepstralSource(start, count), emit: emit)
        }
    }
    let completion = try worker.finish(emit: emit)
    #expect(try worker.finish { _ in Issue.record("Repeated finish emitted") } == completion)
    return (collector.frames, completion)
}

@Test func cepstralPreviewIsChunkInvariantAndFloatInputUsesDoubleAnalysis() throws {
    let input = (0..<4000).map {
        Float(0.2 * sin(Double($0) * 0.13) + 0.07 * cos(Double($0) * 0.231))
    }
    let baseline = try capturePreviewCepstrum(
        input.map(Double.init), precision: .float64, chunk: input.count)
    #expect(baseline.completion.completeFrameCount == 39)
    #expect(baseline.completion.emittedFrameCount == 40)
    #expect(baseline.rows.first?.context.usesBoundaryExtension == true)
    #expect(baseline.rows.last?.unavailability == .insufficientData)
    for (chunk, block) in [(1, 31), (7, 256), (4096, 256)] {
        let result = try capturePreviewCepstrum(
            input, precision: .float32, chunk: chunk, block: block)
        #expect(result.completion == baseline.completion)
        #expect(result.rows.count == baseline.rows.count)
        for (a, b) in zip(result.rows, baseline.rows) {
            #expect(a.values == b.values && a.unavailability == b.unavailability)
            #expect(a.context.frameIndex == b.context.frameIndex)
            #expect(a.context.firstAnalysisSampleIndex == b.context.firstAnalysisSampleIndex)
            #expect(a.context.timing.source == b.context.timing.source)
            #expect(a.context.centerSecondsFromOrigin == b.context.centerSecondsFromOrigin)
            #expect(
                a.configuration.inputPrecision == .float32
                    && a.configuration.frame.precision == .float64)
            #expect(a.profile != b.profile)
            #expect(
                try JSONDecoder().decode(PowerCepstrumFrame.self, from: JSONEncoder().encode(a))
                    == a)
        }
    }
}

@Test func cepstralPreviewRejectsGapsAndNonfiniteChunksBeforeMutation() throws {
    let config = try previewCepstralConfiguration()
    let worker = try PreparedPreviewCepstrogram<Double>(configuration: config, epoch: cepstralEpoch)
    let half = [Double](repeating: 0.25, count: 800)
    try half.withUnsafeBufferPointer { input in
        #expect(throws: CepstrumError.unexpectedInterval) {
            try worker.process(input, interval: previewCepstralSource(1, half.count)) { _ in }
        }
        #expect(worker.receivedSampleCount == 0)
        try worker.process(input, interval: previewCepstralSource(0, half.count)) { _ in
            Issue.record("Short input emitted complete frame")
        }
    }
    var invalid = half
    invalid[799] = .nan
    #expect(throws: CepstrumError.nonfiniteInput) {
        try invalid.withUnsafeBufferPointer {
            try worker.process($0, interval: previewCepstralSource(800, 800)) { _ in }
        }
    }
    #expect(worker.receivedSampleCount == 800)
    let next = try cepstralEpoch.successor()
    try worker.reset(
        for: SourceDiscontinuity(
            previousEpoch: cepstralEpoch, nextEpoch: next, reason: .droppedAudio,
            missingSource: previewCepstralSource(800, 200)))
    _ = try half.withUnsafeBufferPointer {
        try worker.process($0, interval: previewCepstralSource(0, 800, epoch: next)) { _ in
            Issue.record("Separated short pieces were joined")
        }
    }
    var count = 0
    let result = try worker.finish { output in
        count += 1
        #expect(output.unavailability == .insufficientData)
        #expect(output.context.origin.epoch == next)
    }
    #expect(count == 1 && result.completeFrameCount == 0)
}

@Test func cepstralCancellationAtConvertedChunkEndPreservesBorrowedOutput() throws {
    let config = try previewCepstralConfiguration(.float32)
    let worker = try PreparedPreviewCepstrogram<Float>(configuration: config, epoch: cepstralEpoch)
    let signal = (0..<20_000).map { Float(sin(Double($0) * 0.13) * 0.25) }
    var count = 0
    let report = try signal.withUnsafeBufferPointer { input in
        try worker.process(input, interval: previewCepstralSource(0, signal.count)) { output in
            count += 1
            if output.context.frameIndex == 30 {
                let before = Array(output.stage(.powerCepstrum).values)
                #expect(throws: CepstrumError.reentrantCall) { try worker.finish { _ in } }
                worker.cancel()
                #expect(worker.scalarWorkspaceBytes == 0)
                #expect(Array(output.stage(.powerCepstrum).values) == before)
            }
        }
    }
    #expect(count == 31 && report.isCancelled && report.consumedSampleCount == 4096)
    #expect(worker.receivedSampleCount == 4096)
    #expect(throws: CepstrumError.invalidState) { try worker.finish { _ in } }
    worker.cancel()
}

@Test func cepstralIntervalGridAndShortInputRemainExplicit() throws {
    let config = try CepstrogramConfiguration(
        sourceSampleRate: 10_000, declaredInputBandwidthHz: 5000)
    for (length, expected) in [(999, 0), (1000, 1), (1001, 1), (1100, 5), (1101, 6)] {
        let source = try SourceInterval(
            epoch: cepstralEpoch, startSample: 100, sampleCount: Int64(length), sampleRate: 10_000)
        let worker = try PreparedIntervalCepstrogram<Double>(configuration: config, source: source)
        #expect(worker.layout.frameCount == expected)
        var rows = 0
        let zero = [Double](repeating: 0, count: length)
        #expect(throws: CepstrumError.insufficientData) { try worker.finish { _ in } }
        try zero.withUnsafeBufferPointer { try worker.append($0, interval: source) }
        let result = try worker.finish { output in
            rows += 1
            #expect(output.unavailability == (expected == 0 ? .insufficientData : .silence))
            #expect(output.context.timing.source == source)
            #expect(output.context.origin.startSample == 100)
        }
        #expect(rows == max(1, expected) && result.completeFrameCount == UInt64(expected))
        #expect(try worker.finish { _ in Issue.record("Repeated interval emitted") } == result)
    }
    let layout = try IntervalCepstrogramLayout(configuration: config, inputSampleCount: 2560)
    #expect(try layout.centerSeconds(frameIndex: 19) == 0.08800000000000001)
    #expect(try layout.firstAnalysisSampleIndex(frameIndex: 19) == 380)
}

@Test func cepstralWholeIntervalFloatResetAndCancellationPreserveSourceIdentity() throws {
    let config = try CepstrogramConfiguration(
        sourceSampleRate: 16_000, analysisSampleRate: 4000, inputPrecision: .float32,
        pitchFloorHz: 100, hopSeconds: 0.005, declaredInputBandwidthHz: 8000)
    let offset: Int64 = (1 << 54) + 7
    let source = try SourceInterval(
        epoch: cepstralEpoch, startSample: offset, sampleCount: 4800, sampleRate: 16_000)
    let worker = try PreparedIntervalCepstrogram<Float>(configuration: config, source: source)
    let signal = (0..<4800).map {
        Float(0.2 * sin(Double($0) * 0.13) + 0.03 * cos(Double($0) * 0.221))
    }
    var invalid = signal
    invalid[4799] = .infinity
    #expect(throws: CepstrumError.nonfiniteInput) {
        try invalid.withUnsafeBufferPointer { try worker.append($0, interval: source) }
    }
    #expect(worker.receivedSampleCount == 0)
    for start in stride(from: 0, to: signal.count, by: 31) {
        let count = min(31, signal.count - start)
        let chunk = try SourceInterval(
            epoch: source.epoch, startSample: offset + Int64(start),
            sampleCount: Int64(count), sampleRate: 16_000)
        try signal.withUnsafeBufferPointer {
            try worker.append(
                UnsafeBufferPointer(rebasing: $0[start..<start + count]), interval: chunk)
        }
    }
    var expected: [[Double]] = []
    let completion = try worker.finish { output in
        #expect(output.context.origin.startSample == offset)
        #expect(output.context.timing.source == source)
        #expect(output.configuration.precision == .float64)
        expected.append(Array(output.stage(.powerCepstrum).values))
    }
    #expect(completion.completeFrameCount == UInt64(worker.layout.frameCount))
    #expect(completion.unavailableFrameCount == 0)
    let next = try SourceInterval(
        epoch: cepstralEpoch.successor(), startSample: offset + 10_000,
        sampleCount: 4800, sampleRate: 16_000)
    try worker.reset(source: next)
    #expect(worker.receivedSampleCount == 0)
    try signal.withUnsafeBufferPointer { try worker.append($0, interval: next) }
    var delivered = 0
    let cancelled = try worker.finish { output in
        #expect(output.context.origin.epoch == next.epoch)
        #expect(output.context.timing.source == next)
        #expect(Array(output.stage(.powerCepstrum).values) == expected[delivered])
        delivered += 1
        #expect(throws: CepstrumError.reentrantCall) { try worker.reset(source: next) }
        if delivered == 2 {
            worker.cancel()
            #expect(worker.scalarWorkspaceBytes == 0)
            #expect(Array(output.stage(.powerCepstrum).values) == expected[1])
        }
    }
    #expect(delivered == 2 && cancelled.isCancelled && cancelled.emittedFrameCount == 2)
    #expect(worker.receivedSampleCount == 4800)
    #expect(throws: CepstrumError.invalidState) { try worker.reset(source: next) }
    #expect(throws: CepstrumError.invalidState) { try worker.finish { _ in } }
    worker.cancel()
}

@Test func cepstralPreviewArithmeticFailureCanResetWithoutStitching() throws {
    let config = try previewCepstralConfiguration()
    let worker = try PreparedPreviewCepstrogram<Double>(configuration: config, epoch: cepstralEpoch)
    let excessive = [Double](repeating: Double.greatestFiniteMagnitude, count: 4000)
    #expect(throws: (any Error).self) {
        try excessive.withUnsafeBufferPointer {
            try worker.process($0, interval: previewCepstralSource(0, excessive.count)) { _ in }
        }
    }
    #expect(throws: CepstrumError.invalidState) { try worker.finish { _ in } }
    let next = try cepstralEpoch.successor()
    try worker.reset(
        for: SourceDiscontinuity(
            previousEpoch: cepstralEpoch, nextEpoch: next, reason: .explicitReset))
    let signal = (0..<4000).map { 0.2 * sin(Double($0) * 0.13) + 0.03 * cos(Double($0) * 0.221) }
    let baseline = try capturePreviewCepstrum(signal, precision: .float64, chunk: 256)
    var rows = 0
    let receive: (BorrowedPowerCepstrum<Double>) -> Void = { output in
        #expect(output.context.origin.epoch == next)
        #expect(
            output.context.firstAnalysisSampleIndex
                == baseline.rows[rows].context.firstAnalysisSampleIndex)
        #expect(Array(output.stage(.powerCepstrum).values) == baseline.rows[rows].values)
        #expect(output.unavailability == baseline.rows[rows].unavailability)
        rows += 1
    }
    _ = try signal.withUnsafeBufferPointer {
        try worker.process(
            $0, interval: previewCepstralSource(0, signal.count, epoch: next), emit: receive)
    }
    try worker.finish(emit: receive)
    #expect(rows == baseline.rows.count)
}

private func checkPositiveSourceWithNoAnalysisSamples<S: BinaryFloatingPoint & Sendable>(
    _: S.Type, precision: AnalysisPrecision
) throws {
    let config = try CepstrogramConfiguration(
        sourceSampleRate: 48_000, inputPrecision: precision, hopSeconds: 0.005,
        declaredInputBandwidthHz: 24_000,
        conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
    let origin: Int64 = (1 << 54) + 11
    for count in 0...6 {
        let worker = try PreparedPreviewCepstrogram<S>(
            configuration: config, epoch: cepstralEpoch, startSample: origin)
        let source = try SourceInterval(
            epoch: cepstralEpoch, startSample: origin, sampleCount: Int64(count), sampleRate: 48_000
        )
        let samples = [S](repeating: 0.25, count: count)
        _ = try samples.withUnsafeBufferPointer {
            try worker.process($0, interval: source) { _ in Issue.record("Short PCM emitted early")
            }
        }
        var delivered = 0
        let result = try worker.finish { output in
            delivered += 1
            #expect(output.unavailability == .insufficientData)
            #expect(output.context.timing.source == source)
            #expect(output.context.timing.includedSampleCount == Int64(count))
            #expect(output.context.origin.startSample == origin)
            #expect(output.context.frameIndex == 0 && output.context.firstAnalysisSampleIndex == 0)
            #expect(output.context.suppliedAnalysisSampleCount == count * 10_000 / 48_000)
            if count < 5 {
                #expect(output.context.centerSecondsFromOrigin == source.durationSeconds / 2)
                #expect(output.context.timing.effectiveDelaySeconds == source.durationSeconds / 2)
                #expect(!output.context.usesBoundaryExtension)
            }
            for stage in CepstralStage.allCases {
                #expect(output.stage(stage).values.isEmpty)
                #expect(output.stage(stage).unavailability == .insufficientData)
            }
            #expect(throws: CepstrumError.reentrantCall) { try worker.finish { _ in } }
        }
        #expect(delivered == (count == 0 ? 0 : 1))
        #expect(result.source == source && result.completeFrameCount == 0)
        #expect(
            result.emittedFrameCount == UInt64(delivered)
                && result.unavailableFrameCount == UInt64(delivered))
        #expect(try worker.finish { _ in Issue.record("Repeated short result") } == result)
        try worker.reset(
            for: SourceDiscontinuity(
                previousEpoch: cepstralEpoch, nextEpoch: cepstralEpoch.successor(),
                reason: .explicitReset))
        let empty = try worker.finish { _ in Issue.record("Reset fabricated source support") }
        #expect(empty.source.sampleCount == 0 && empty.emittedFrameCount == 0)
    }
}

@Test func cepstralPositiveSourceBelowOneTargetSampleRemainsUnavailable() throws {
    try checkPositiveSourceWithNoAnalysisSamples(Float.self, precision: .float32)
    try checkPositiveSourceWithNoAnalysisSamples(Double.self, precision: .float64)
}

@Test func cepstralCancellationFromZeroTargetSampleResultIsTerminal() throws {
    let config = try CepstrogramConfiguration(
        sourceSampleRate: 48_000, declaredInputBandwidthHz: 24_000,
        conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
    let worker = try PreparedPreviewCepstrogram<Double>(configuration: config, epoch: cepstralEpoch)
    let source = try SourceInterval(
        epoch: cepstralEpoch, startSample: 0, sampleCount: 1, sampleRate: 48_000)
    _ = try [0.25].withUnsafeBufferPointer { try worker.process($0, interval: source) { _ in } }
    let result = try worker.finish { output in
        worker.cancel()
        #expect(worker.scalarWorkspaceBytes == 0)
        #expect(
            output.unavailability == .insufficientData && output.context.timing.source == source)
        #expect(output.stage(.powerCepstrum).values.isEmpty)
    }
    #expect(result.isCancelled && result.source == source)
    #expect(
        result.emittedFrameCount == 1 && result.unavailableFrameCount == 1
            && result.completeFrameCount == 0)
    #expect(worker.receivedSampleCount == 1)
    #expect(throws: CepstrumError.invalidState) { try worker.finish { _ in } }
}
