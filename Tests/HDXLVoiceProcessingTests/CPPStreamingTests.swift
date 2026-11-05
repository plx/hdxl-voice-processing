import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let cppEpoch = StreamEpoch(
    streamID: UUID(uuidString: "0F2B41C3-1035-4EE4-9535-000000000035")!)

private func cppNoise<S: BinaryFloatingPoint>(_ sample: S.Type, count: Int) -> [S] {
    var state: UInt32 = 35
    return (0..<count).map { _ in
        state = 1_664_525 &* state &+ 1_013_904_223
        return S((Double(state) - 2_147_483_648) / 21_474_836_480)
    }
}

private func cppConsume(
    _ input: BorrowedPowerCepstrum<Double>, consumer: PreparedCPP,
    into rows: inout [CPPFrameResult]
) {
    do {
        try consumer.analyze(input) { output in
            #expect(output.result.context == input.context)
            #expect(output.result.sourceProfile == input.profile)
            #expect(output.result.profile == consumer.identity)
            rows.append(output.result)
        }
    } catch { Issue.record(error) }
}

private func wholeCPP<S: BinaryFloatingPoint & Sendable>(
    _ sample: S.Type,
    precision: AnalysisPrecision, chunkSize: Int
) throws -> [CPPFrameResult] {
    let c = try CepstrogramConfiguration(
        sourceSampleRate: 16_000, inputPrecision: precision,
        declaredInputBandwidthHz: 8000)
    let start: Int64 = (1 << 54) + 35
    let input = cppNoise(sample, count: 3200)
    let source = try SourceInterval(
        epoch: cppEpoch, startSample: start,
        sampleCount: Int64(input.count), sampleRate: 16_000)
    let upstream = try PreparedIntervalCepstrogram<S>(configuration: c, source: source)
    let consumer = try PreparedCPP(
        CPPProfile(cepstrogram: c, settings: CPPConfiguration.murtonRecipePraat7()))
    let wrongConsumer = try PreparedCPP(
        CPPProfile(frame: c.frame, settings: CPPConfiguration.murtonRecipePraat7()))
    try input.withUnsafeBufferPointer { buffer in
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            let end = min(input.count, offset + chunkSize)
            let interval = try SourceInterval(
                epoch: cppEpoch, startSample: start + Int64(offset),
                sampleCount: Int64(end - offset), sampleRate: 16_000)
            try upstream.append(
                UnsafeBufferPointer(rebasing: buffer[offset..<end]), interval: interval)
        }
    }
    var rows: [CPPFrameResult] = []
    try upstream.finish { frame in
        #expect(throws: CPPError.profileMismatch) { try wrongConsumer.analyze(frame) { _ in } }
        cppConsume(frame, consumer: consumer, into: &rows)
    }
    #expect(!rows.isEmpty && rows.allSatisfy { $0.observation != nil })
    #expect(
        rows.allSatisfy {
            $0.context.origin.startSample == start && $0.context.timing.source == source
        })
    try upstream.finish { _ in Issue.record("Repeated finalization emitted") }
    return rows
}

@Test func cppConsumesLowPeriodicityPCMWithoutF0GateForBothPrecisions() throws {
    #expect(
        try wholeCPP(Float.self, precision: .float32, chunkSize: 63)
            == wholeCPP(Float.self, precision: .float32, chunkSize: 256))
    #expect(
        try wholeCPP(Double.self, precision: .float64, chunkSize: 63)
            == wholeCPP(Double.self, precision: .float64, chunkSize: 256))
}

private func previewCPP<S: BinaryFloatingPoint & Sendable>(
    _ input: [S],
    worker: PreparedPreviewCepstrogram<S>, consumer: PreparedCPP, chunkSize: Int
) throws -> [CPPFrameResult] {
    var rows: [CPPFrameResult] = []
    try input.withUnsafeBufferPointer { buffer in
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            let end = min(input.count, offset + chunkSize)
            let interval = try SourceInterval(
                epoch: worker.origin.epoch,
                startSample: worker.origin.startSample + Int64(offset),
                sampleCount: Int64(end - offset),
                sampleRate: worker.origin.sampleRate)
            try worker.process(
                UnsafeBufferPointer(rebasing: buffer[offset..<end]), interval: interval
            ) { frame in
                cppConsume(frame, consumer: consumer, into: &rows)
            }
        }
    }
    try worker.finish { frame in cppConsume(frame, consumer: consumer, into: &rows) }
    return rows
}

@Test func cppPreviewGapStartsIndependentInputAndPreservesTailStatus() throws {
    let c = try CepstrogramConfiguration(
        sourceSampleRate: 48_000, inputPrecision: .float32,
        hopSeconds: 0.005, declaredInputBandwidthHz: 24_000,
        conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
    let worker = try PreparedPreviewCepstrogram<Float>(configuration: c, epoch: cppEpoch)
    let consumer = try PreparedCPP(
        CPPProfile(cepstrogram: c, settings: CPPConfiguration.murtonRecipePraat7()))
    let old = cppNoise(Float.self, count: 2000)
    try old.withUnsafeBufferPointer { input in
        try worker.process(
            input,
            interval: SourceInterval(
                epoch: cppEpoch, startSample: 0,
                sampleCount: Int64(old.count), sampleRate: 48_000)
        ) { _ in Issue.record("Short old epoch emitted") }
    }
    let next = try cppEpoch.successor()
    let gap = try SourceDiscontinuity(
        previousEpoch: cppEpoch, nextEpoch: next, reason: .droppedAudio,
        missingSource: SourceInterval(
            epoch: cppEpoch, startSample: 2000,
            sampleCount: 300, sampleRate: 48_000))
    try worker.reset(for: gap)
    let fresh = try PreparedPreviewCepstrogram<Float>(configuration: c, epoch: next)
    let source = cppNoise(Float.self, count: 9601)
    let resetRows = try previewCPP(source, worker: worker, consumer: consumer, chunkSize: 63)
    let freshRows = try previewCPP(source, worker: fresh, consumer: consumer, chunkSize: 256)
    #expect(resetRows.count == freshRows.count && !resetRows.isEmpty)
    for (a, b) in zip(resetRows, freshRows) {
        #expect(a.observation == b.observation && a.unavailability == b.unavailability)
        #expect(a.context.origin == b.context.origin && a.context.origin.epoch == next)
        #expect(a.context.firstAnalysisSampleIndex == b.context.firstAnalysisSampleIndex)
        #expect(a.context.timing.source == b.context.timing.source)
    }
    #expect(resetRows.last?.unavailability == .insufficientData)
}

@Test func cppConsumerCancellationPreservesBothActiveBorrows() throws {
    let c = try CepstrogramConfiguration(
        sourceSampleRate: 16_000, inputPrecision: .float64,
        hopSeconds: 0.01, declaredInputBandwidthHz: 8000,
        conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
    let worker = try PreparedPreviewCepstrogram<Double>(configuration: c, epoch: cppEpoch)
    let consumer = try PreparedCPP(
        CPPProfile(cepstrogram: c, settings: CPPConfiguration.murtonRecipePraat7()))
    let input = cppNoise(Double.self, count: 4000)
    var observations = 0
    let report = try input.withUnsafeBufferPointer { buffer in
        try worker.process(
            buffer,
            interval: SourceInterval(
                epoch: cppEpoch, startSample: 0,
                sampleCount: Int64(input.count), sampleRate: 16_000)
        ) { frame in
            do {
                try consumer.analyze(frame) { cpp in
                    observations += 1
                    let cepstrum = Array(frame.stage(.powerCepstrum).values)
                    let background = Array(cpp.values(.backgroundDB))
                    worker.cancel()
                    #expect(Array(frame.stage(.powerCepstrum).values) == cepstrum)
                    #expect(Array(cpp.values(.backgroundDB)) == background)
                    #expect(cpp.result.observation != nil)
                }
            } catch { Issue.record(error) }
        }
    }
    #expect(observations == 1 && report.isCancelled)
    #expect(throws: CepstrumError.invalidState) { try worker.finish { _ in } }
}
