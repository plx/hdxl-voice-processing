import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let cppsEpoch = StreamEpoch(
    streamID: UUID(uuidString: "0F2B41C3-1035-4EE4-9535-000000000037")!)

private func cppsSignal<S: BinaryFloatingPoint>(_ type: S.Type, count: Int, rate: Double = 16_000)
    -> [S]
{
    var seed: UInt32 = 37
    return (0..<count).map { index in
        seed = 1_664_525 &* seed &+ 1_013_904_223
        let noise = Double(seed) / Double(UInt32.max) - 0.5
        let t = Double(index) / rate
        return S(0.2 * sin(2 * .pi * 167 * t) + 0.06 * sin(2 * .pi * 334 * t) + 0.02 * noise)
    }
}

private func cppsProfile(preview: Bool, precision: AnalysisPrecision = .float64) throws
    -> CPPSProfile
{
    try CPPSProfile(
        cepstrogram: CepstrogramConfiguration(
            sourceSampleRate: 16_000,
            inputPrecision: precision, hopSeconds: 0.002, declaredInputBandwidthHz: 8000,
            conditioningMethod: preview
                ? .streamingPreview(lobes: 16, cutoffFraction: 0.9)
                : .praat7WholeInterval(interpolationDepth: 50)), settings: .murtonRecipePraat7())
}

private func wholeCPPS<S: BinaryFloatingPoint & Sendable>(
    _ samples: [S], precision: AnalysisPrecision,
    chunk: Int
) throws -> ([CPPSFrameResult], CPPSCompletion) {
    let profile = try cppsProfile(preview: false, precision: precision)
    let source = try SourceInterval(
        epoch: cppsEpoch, startSample: (1 << 54) + 37,
        sampleCount: Int64(samples.count), sampleRate: 16_000)
    let worker = try PreparedIntervalCPPS<S>(profile: profile, source: source)
    try samples.withUnsafeBufferPointer { input in
        for start in stride(from: 0, to: input.count, by: chunk) {
            let end = min(input.count, start + chunk)
            try worker.append(
                UnsafeBufferPointer(rebasing: input[start..<end]),
                interval: SourceInterval(
                    epoch: source.epoch, startSample: source.startSample + Int64(start),
                    sampleCount: Int64(end - start), sampleRate: source.sampleRate))
        }
    }
    var results: [CPPSFrameResult] = []
    let completion = try worker.finish { output in
        #expect(output.result.context.timing.source == source)
        #expect(output.result.profile == (try? profile.identity()))
        results.append(output.result)
    }
    #expect(try worker.finish { _ in Issue.record("Repeated finish emitted") } == completion)
    return (results, completion)
}

@Test func cppsWholePCMChunksAndShortIntervals() throws {
    for count in [1, 1599, 1920] {
        let input = cppsSignal(Double.self, count: count)
        let tiny = try wholeCPPS(input, precision: .float64, chunk: 1)
        let batch = try wholeCPPS(input, precision: .float64, chunk: input.count)
        #expect(tiny.0 == batch.0)
        #expect(tiny.1 == batch.1)
        if count < 1600 {
            #expect(tiny.0.count == 1)
            #expect(tiny.1.meanDB == nil && tiny.1.unavailability == .insufficientData)
        } else {
            #expect(tiny.0.count == 11)
            #expect(tiny.1.availableFrameCount == 11 && tiny.1.meanDB != nil)
        }
    }
    let floats = cppsSignal(Float.self, count: 1920)
    #expect(
        try wholeCPPS(floats, precision: .float32, chunk: 17).0
            == wholeCPPS(floats, precision: .float32, chunk: floats.count).0)
}

private func previewCPPS(_ samples: [Double], worker: PreparedPreviewCPPS<Double>, chunk: Int)
    throws -> ([CPPSFrameResult], CPPSCompletion)
{
    var rows: [CPPSFrameResult] = []
    try samples.withUnsafeBufferPointer { input in
        for start in stride(from: 0, to: input.count, by: chunk) {
            let end = min(input.count, start + chunk)
            try worker.process(
                UnsafeBufferPointer(rebasing: input[start..<end]),
                interval: SourceInterval(
                    epoch: worker.origin.epoch,
                    startSample: worker.origin.startSample + Int64(start),
                    sampleCount: Int64(end - start),
                    sampleRate: worker.origin.sampleRate)
            ) { rows.append($0.result) }
        }
    }
    let completion = try worker.finish { rows.append($0.result) }
    return (rows, completion)
}

@Test func cppsPreviewChunkAlignmentTailAndGap() throws {
    let profile = try cppsProfile(preview: true)
    #expect(try profile.identity() != cppsProfile(preview: false).identity())
    let worker = try PreparedPreviewCPPS<Double>(profile: profile, epoch: cppsEpoch)
    let old = cppsSignal(Double.self, count: 2000)
    try old.withUnsafeBufferPointer { input in
        try worker.process(
            input,
            interval: SourceInterval(
                epoch: cppsEpoch, startSample: 0,
                sampleCount: 2000, sampleRate: 16_000)
        ) { _ in }
    }
    let next = try cppsEpoch.successor()
    try worker.reset(
        for: SourceDiscontinuity(
            previousEpoch: cppsEpoch, nextEpoch: next,
            reason: .droppedAudio,
            missingSource: SourceInterval(
                epoch: cppsEpoch, startSample: 2000,
                sampleCount: 320, sampleRate: 16_000)))
    let fresh = try PreparedPreviewCPPS<Double>(profile: profile, epoch: next)
    let samples = cppsSignal(Double.self, count: 2401)
    let tiny = try previewCPPS(samples, worker: worker, chunk: 1)
    let batch = try previewCPPS(samples, worker: fresh, chunk: samples.count)
    #expect(tiny.0.count == batch.0.count)
    #expect(tiny.1 == batch.1)
    for (a, b) in zip(tiny.0, batch.0) {
        #expect(a.observation == b.observation && a.unavailability == b.unavailability)
        #expect(a.context.timing.source == b.context.timing.source)
        #expect(a.context.centerSecondsFromOrigin == b.context.centerSecondsFromOrigin)
        #expect(a.context.origin.epoch == next)
    }
    #expect(tiny.0.dropLast().allSatisfy { $0.observation != nil })
    #expect(tiny.0.last?.unavailability == .insufficientData)
    #expect(tiny.0.last?.temporalSupportFrameCount == 0)
    #expect(tiny.1.meanDB == nil)
}
