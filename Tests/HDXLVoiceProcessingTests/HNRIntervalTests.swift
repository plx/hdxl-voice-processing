import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func hnrWholeIntervalChunkingAggregatesAndResetPreserveCoverage() throws {
    let directory = try hnrFixtureDirectory("HNR")
    let record = try JSONDecoder().decode(
        HNRReferenceRecord.self,
        from: Data(contentsOf: directory.appending(path: "noisy-0.05-cc-float64.json")))
    let input = try hnrReferenceSamples(record, directory: directory)
    let c = try record.case.profile.native()
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 900,
        sampleCount: Int64(input.count), sampleRate: 16000)
    let timing = try AnalysisTiming(
        source: source, includedSampleCount: source.sampleCount,
        sourceStartSeconds: 70, hostStartNanoseconds: 1_000_000_000,
        completedHostNanoseconds: 2_000_000_000)
    let worker = try PreparedIntervalHNR<Double>(configuration: c, timing: timing)
    #expect(throws: HNRError.insufficientData) { try worker.finish { _ in } }
    let bad = Array(repeating: Double.nan, count: input.count)
    #expect(throws: HNRError.invalidInput) {
        try bad.withUnsafeBufferPointer { try worker.append($0, interval: source) }
    }
    #expect(worker.receivedSampleCount == 0)
    try input.withUnsafeBufferPointer { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = min(137, buffer.count - offset)
            let chunk = try SourceInterval(
                epoch: source.epoch, startSample: source.startSample + Int64(offset),
                sampleCount: Int64(count), sampleRate: source.sampleRate)
            try worker.append(
                UnsafeBufferPointer(rebasing: buffer[offset..<offset + count]), interval: chunk)
            offset += count
        }
    }
    var emitted = 0
    var expectedUnion = Set<Int>()
    let completion = try worker.finish { event in
        guard case .frame(let output) = event else {
            Issue.record("Complete input emitted a short frame")
            return
        }
        let index = emitted
        emitted += 1
        #expect(output.result.selectedObservation != nil)
        #expect(output.result.frameIndex == UInt64(index))
        #expect(output.result.dependencyTiming.source == source)
        expectedUnion.formUnion(output.result.layout.support)
        #expect(throws: HNRError.reentrantCall) { try worker.finish { _ in } }
        #expect(throws: HNRError.reentrantCall) { try worker.reset(timing: timing) }
        if let actual = output.result.selectedObservation?.referenceReportingDecibels,
            let expected = record.data.frames[index].valueDB
        {
            #expect(abs(actual - expected) < 1e-4)
        }
    }
    #expect(emitted == record.data.frames.count)
    #expect(completion.emittedSlotCount == emitted && completion.availableFrameCount == emitted)
    #expect(completion.unavailableFrameCount == 0 && completion.frameCoverage == 1)
    #expect(
        completion.finiteDecibelFrameCount == emitted && completion.reportingLimitFrameCount == 0)
    #expect(
        completion.observedSampleCount == expectedUnion.count && completion.observedCoverage < 1)
    let referenceMean = record.data.frames.compactMap(\.valueDB).reduce(0, +) / Double(emitted)
    #expect(abs(try #require(completion.referencePresentationMeanDB) - referenceMean) < 1e-4)
    #expect(completion.meanDB == completion.finiteUncappedMeanDB && completion.meanDB != nil)
    #expect(!completion.isCancelled && completion.unavailability == nil)
    #expect(try worker.finish { _ in Issue.record("Repeated finish emitted output") } == completion)
    #expect(throws: HNRError.invalidState) {
        try input.withUnsafeBufferPointer { try worker.append($0, interval: source) }
    }
    let next = try SourceInterval(
        epoch: source.epoch.successor(), startSample: 12345,
        sampleCount: source.sampleCount, sampleRate: source.sampleRate)
    let nextTiming = try AnalysisTiming(source: next, includedSampleCount: next.sampleCount)
    try worker.reset(timing: nextTiming)
    #expect(worker.receivedSampleCount == 0)
    #expect(throws: HNRError.unexpectedContext) {
        try input.withUnsafeBufferPointer { try worker.append($0, interval: source) }
    }
    try Array(repeating: 0.0, count: input.count).withUnsafeBufferPointer {
        try worker.append($0, interval: next)
    }
    let silent = try worker.finish { event in
        if case .frame(let output) = event {
            #expect(
                output.result.selectedObservation == nil && output.result.unavailability == .silence
            )
            #expect(output.result.dependencyTiming.source == next)
        }
    }
    #expect(
        silent.availableFrameCount == 0 && silent.meanDB == nil
            && silent.referencePresentationMeanDB == nil)
    #expect(silent.observedSampleCount == 0 && silent.unavailability == .silence)
}

@Test func hnrIntervalCancellationKeepsCurrentBorrowAndShortInputsExplicit() throws {
    for count in [0, 1, 31, 160] {
        let c = try HNRConfiguration(method: .autocorrelation, sampleRate: 16000)
        let source = try SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: 77,
            sampleCount: Int64(count), sampleRate: 16000)
        let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        let worker = try PreparedIntervalHNR<Double>(configuration: c, timing: timing)
        try Array(repeating: 0.0, count: count).withUnsafeBufferPointer {
            try worker.append($0, interval: source)
        }
        var callbacks = 0
        let completion = try worker.finish { event in
            callbacks += 1
            guard case .unavailable(let frame) = event else {
                Issue.record("Short support became complete")
                return
            }
            #expect(frame.reason == .insufficientData && frame.timing.source == source)
            do {
                let result = try frame.measurementResult()
                #expect(result.outcome == .unavailable(.insufficientData))
            } catch { Issue.record(error) }
        }
        #expect(
            callbacks == 1 && completion.completeGridFrameCount == 0
                && completion.emittedSlotCount == 1)
        #expect(completion.meanDB == nil && completion.unavailability == .insufficientData)
    }
    let c = try HNRConfiguration(
        method: .forwardCrossCorrelation, sampleRate: 4000,
        pitchFloorHz: 500, periodsPerWindow: 2, hopSeconds: 0.002)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 0, sampleCount: 400, sampleRate: 4000)
    let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
    let worker = try PreparedIntervalHNR<Double>(configuration: c, timing: timing)
    let values = (0..<400).map { sin(2 * Double.pi * Double($0) / 7) }
    try values.withUnsafeBufferPointer { try worker.append($0, interval: source) }
    var callbacks = 0
    let completion = try worker.finish { event in
        callbacks += 1
        guard case .frame(let output) = event else {
            Issue.record("Unexpected short support")
            return
        }
        let before = Array(output.correlation)
        worker.cancel()
        #expect(Array(output.correlation) == before)
        #expect(output.result.frameIndex == 0)
    }
    #expect(callbacks == 1 && completion.isCancelled && completion.emittedSlotCount == 1)
    #expect(completion.meanDB == nil && completion.unavailability == .cancelled)
    #expect(
        try worker.finish { _ in Issue.record("Cancelled finish repeated output") } == completion)
    try worker.reset(timing: timing)
    worker.cancel()
    #expect(throws: HNRError.invalidState) { try worker.finish { _ in } }
}
