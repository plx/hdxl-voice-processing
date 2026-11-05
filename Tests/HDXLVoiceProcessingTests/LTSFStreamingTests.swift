import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct LTSFCapture: Equatable {
    let flatness: [Double]
    let intensity: [Double]
    let intervals: [SpeechActivityInterval]
    let plan: MaskPlan
}

private func ltsfCapture(_ worker: PreparedLTSFDetector<Double>, _ samples: [Double], chunk: Int)
    throws -> LTSFCapture
{
    let source = worker.layout.source
    try samples.withUnsafeBufferPointer { pcm in
        for start in stride(from: 0, to: pcm.count, by: chunk) {
            let end = min(pcm.count, start + chunk)
            let part = try SourceInterval(
                epoch: source.epoch, startSample: source.startSample + Int64(start),
                sampleCount: Int64(end - start), sampleRate: source.sampleRate)
            try worker.append(UnsafeBufferPointer(rebasing: pcm[start..<end]), interval: part)
        }
    }
    var output: LTSFCapture?
    var failure: (any Error)?
    let completion = try worker.finish { borrowed in
        do {
            output = LTSFCapture(
                flatness: Array(borrowed.flatness), intensity: Array(borrowed.referenceIntensityDB),
                intervals: Array(borrowed.speechIntervals), plan: try borrowed.exportMaskPlan())
        } catch { failure = error }
    }
    if let failure { throw failure }
    #expect(try worker.finish { _ in Issue.record("Repeated LTSF finish emitted") } == completion)
    return try #require(output)
}

@Test func ltsfChunkingAndResetMatchIndependentRegionProcessing() throws {
    let rate = 16_000
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 123,
        sampleCount: 16_000, sampleRate: Double(rate))
    let config = try LTSFConfiguration(sampleRate: rate, declaredInputBandwidthHz: 8000)
    let samples = (0..<16_000).map { index in
        let t = Double(index) / Double(rate)
        return (t < 0.2 || t > 0.65 ? 0.001 : 0.3) * sin(2 * .pi * 173 * t)
    }
    let worker = try PreparedLTSFDetector<Double>(configuration: config, source: source)
    let baseline = try ltsfCapture(worker, samples, chunk: samples.count)
    for chunk in [1, 64, 137, 1024] {
        try worker.reset(source: source)
        #expect(try ltsfCapture(worker, samples, chunk: chunk) == baseline)
    }
    let next = try SourceInterval(
        epoch: source.epoch.successor(), startSample: 0, sampleCount: 16_000, sampleRate: 16_000)
    try worker.reset(source: next)
    let silence = Array(repeating: 0.0, count: 16_000)
    let afterReset = try ltsfCapture(worker, silence, chunk: 64)
    let fresh = try ltsfCapture(
        PreparedLTSFDetector(configuration: config, source: next), silence, chunk: 1024)
    #expect(afterReset == fresh)
    #expect(afterReset.flatness.allSatisfy { $0 == 0 })
    #expect(afterReset.intervals.count == 1)
    #expect(afterReset.intervals.first?.isSpeech == false)
    #expect(try MaskTimeline(afterReset.plan).coverage.selectedSampleCount == 0)
    #expect(afterReset.plan.effectiveDelaySeconds == 1)
    #expect(baseline.flatness != afterReset.flatness)
}

@Test func ltsfRollingHistorySurvivesZerosLargeDynamicRangeAndRebase() throws {
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 0,
        sampleCount: 16_000 * 12, sampleRate: 16_000)
    let config = try LTSFConfiguration(
        sampleRate: 16_000, declaredInputBandwidthHz: 8000,
        shortWindowSeconds: 0.001, relativeIntensityThresholdDB: nil)
    // Repeated transitions exercise exact-zero windows, tiny positive windows,
    // retirement of large powers and the 1024-frame compensated-sum rebuild.
    let samples = (0..<Int(source.sampleCount)).map { index in
        let block = (index / 1600) % 3
        let amplitude = block == 0 ? 0 : (block == 1 ? 1e-100 : 1.0)
        return amplitude * sin(2 * .pi * 173 * Double(index) / 16_000)
    }
    let worker = try PreparedLTSFDetector<Double>(configuration: config, source: source)
    let full = try ltsfCapture(worker, samples, chunk: samples.count)
    try worker.reset(source: source)
    #expect(try ltsfCapture(worker, samples, chunk: 137) == full)
    #expect(full.flatness.count == 1199)
    #expect(full.flatness.allSatisfy { $0.isFinite })
    #expect(full.intensity.isEmpty)
}

@Test func ltsfInsufficientInputAndCancelledBorrowNeverExposeStaleFeatures() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let config = try LTSFConfiguration(sampleRate: 16_000, declaredInputBandwidthHz: 8000)
    let short = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 960, sampleRate: 16_000)
    let shortWorker = try PreparedLTSFDetector<Double>(configuration: config, source: short)
    let shortOutput = try ltsfCapture(shortWorker, Array(repeating: 0.5, count: 960), chunk: 64)
    #expect(shortOutput.flatness.isEmpty)
    #expect(shortOutput.intervals.isEmpty)
    let report = try MaskTimeline(shortOutput.plan)
    #expect(report.coverage.sourceCoverage == 0)
    #expect(report.coverage.tags.first { $0.tag == .algorithmInsufficiency }?.sampleCount == 960)
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 16_000, sampleRate: 16_000)
    let worker = try PreparedLTSFDetector<Double>(configuration: config, source: source)
    #expect(throws: MaskError.insufficientData) { try worker.finish { _ in } }
    let values = Array(repeating: 0.5, count: 16_000)
    _ = try values.withUnsafeBufferPointer {
        let result = try worker.append($0, interval: source) { spectrum in
            let before = Array(spectrum.powers)
            #expect(throws: MaskError.reentrantCall) { try worker.reset(source: source) }
            worker.cancel()
            #expect(Array(spectrum.powers) == before)
            #expect(spectrum.powers[0] > 0)
        }
        #expect(result.isCancelled)
        #expect(result.analyzedFrameCount == 1)
        #expect(result.consumedSampleCount == 319)
    }
    #expect(worker.scalarWorkspaceBytes == 0)
    #expect(throws: MaskError.invalidState) { try worker.finish { _ in } }
}

@Test func ltsfIntervalCleanupAndIntensityInterpolationHaveAnalyticAnchors() throws {
    let intervals = ActivityIntervalBuffer(capacity: 5)
    try intervals.append(start: 0, end: 0.0625, speech: true)
    try intervals.append(start: 0.0625, end: 0.25, speech: false)
    try intervals.append(start: 0.25, end: 0.375, speech: true)
    try intervals.append(start: 0.375, end: 0.4375, speech: false)
    try intervals.append(start: 0.4375, end: 1, speech: true)
    intervals.clean(minimumSpeech: 0.125, minimumNonSpeech: 0.125)
    #expect(Array(intervals.values).map(\.startSeconds) == [0, 0.25])
    #expect(Array(intervals.values).map(\.endSeconds) == [0.25, 1])
    #expect(Array(intervals.values).map(\.isSpeech) == [false, true])
    let peak = [0.0, 4, 3].withUnsafeBufferPointer { interpolatedIntensityMaximum($0) }
    #expect(abs(peak - 4.225) < 1e-14)
    #expect([3.0, 3, 3].withUnsafeBufferPointer { interpolatedIntensityMaximum($0) } == 3)
}
