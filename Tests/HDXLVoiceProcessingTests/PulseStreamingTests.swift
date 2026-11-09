import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func pulseChunk(_ timing: AnalysisTiming, first: Int, count: Int) throws -> SourceInterval {
    try SourceInterval(
        epoch: timing.source.epoch, startSample: timing.source.startSample + Int64(first),
        sampleCount: Int64(count), sampleRate: timing.source.sampleRate)
}

@Test func pulseStreamingChunkBoundariesPreserveKnownPeriodsAndDoNotPublishEarly() throws {
    let samples = pulseCycleTrain()
    let contour = try pulseContour(count: samples.count)
    let timing = try pulseTiming(count: samples.count)
    let config = try PulseConfiguration(
        sampleRate: 4000, pitchCeilingHz: 1000, support: .independentlyAnchoredBlock)
    let stream = try PreparedPulseStream<Double>(
        configuration: config, contour: contour, timing: timing, maximumTrackingAttempts: 1024)
    var expected: PulseSnapshot?
    let bytes = stream.preparedBufferBytes
    for size in [400, 1, 37, 199] {
        try stream.reset(contour: contour, timing: timing)
        var deliveries = 0
        try samples.withUnsafeBufferPointer { input in
            for start in stride(from: 0, to: input.count, by: size) {
                let end = min(input.count, start + size)
                try stream.append(
                    UnsafeBufferPointer(rebasing: input[start..<end]),
                    interval: pulseChunk(timing, first: start, count: end - start))
                #expect(stream.consumedSampleCount == end && stream.state == .accepting)
            }
        }
        let completion = try stream.finish {
            deliveries += 1
            let snapshot = try $0.snapshot(maximumRecordCount: 10000)
            if let expected { #expect(snapshot == expected) } else { expected = snapshot }
            for period in snapshot.periods where period.isEligible {
                #expect(abs(period.durationSeconds - 0.002) < 2e-16)
            }
            #expect(snapshot.result.eligiblePeriodCount > 40)
            #expect(snapshot.result.f0ContourIdentity == (try contour.identity()))
        }
        #expect(stream.state == .finished && stream.nextInputSample == Int64.max)
        #expect(completion.timing.effectiveDelaySeconds == 0.05)
        #expect(try stream.finish { _ in deliveries += 1 } == completion)
        #expect(deliveries == 1 && stream.preparedBufferBytes == bytes)
    }
}

@Test func pulseStreamingRejectsGapsOverlapsWrongEpochAndInvalidInputAtomically() throws {
    let values = pulseCycleTrain()
    let contour = try pulseContour(count: values.count)
    let timing = try pulseTiming(count: values.count)
    let config = try PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1000)
    let stream = try PreparedPulseStream<Double>(
        configuration: config, contour: contour, timing: timing, maximumTrackingAttempts: 1024)
    try values.withUnsafeBufferPointer { input in
        let first = UnsafeBufferPointer(rebasing: input[0..<100])
        try stream.append(first, interval: pulseChunk(timing, first: 0, count: 100))
        for interval in [
            try pulseChunk(timing, first: 101, count: 100),
            try pulseChunk(timing, first: 0, count: 100),
            try SourceInterval(
                epoch: StreamEpoch(streamID: UUID()), startSample: stream.nextInputSample,
                sampleCount: 100, sampleRate: 4000),
            try SourceInterval(
                epoch: timing.source.epoch, startSample: stream.nextInputSample, sampleCount: 100,
                sampleRate: 8000),
        ] {
            #expect(throws: PulseError.unexpectedContext) {
                try stream.append(first, interval: interval)
            }
            #expect(stream.consumedSampleCount == 100 && stream.state == .accepting)
        }
        #expect(throws: PulseError.insufficientData) {
            try stream.finish { _ in Issue.record("Partial publication") }
        }
        var invalid = Array(first)
        invalid[99] = .infinity
        invalid.withUnsafeBufferPointer { bad in
            _ = #expect(throws: PulseError.invalidInput) {
                try stream.append(bad, interval: pulseChunk(timing, first: 100, count: 100))
            }
        }
        #expect(stream.consumedSampleCount == 100)
        try stream.append(
            UnsafeBufferPointer(rebasing: input[100..<400]),
            interval: pulseChunk(timing, first: 100, count: 300))
        try stream.finish { #expect($0.result.eligiblePeriodCount > 40) }
        #expect(throws: PulseError.invalidState) {
            try stream.append(first, interval: pulseChunk(timing, first: 0, count: 100))
        }
    }
}

@Test func pulseStreamingCancellationResetAndThrowingDeliveryNeverJoinBlocks() throws {
    let samples = pulseCycleTrain()
    let contour = try pulseContour(count: samples.count)
    let timing = try pulseTiming(count: samples.count)
    let config = try PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1000)
    let stream = try PreparedPulseStream<Double>(
        configuration: config, contour: contour, timing: timing, maximumTrackingAttempts: 1024)
    try samples.withUnsafeBufferPointer { input in
        try stream.append(
            UnsafeBufferPointer(rebasing: input[0..<99]),
            interval: pulseChunk(timing, first: 0, count: 99))
    }
    try stream.cancel()
    try stream.cancel()
    #expect(stream.state == .cancelled && stream.consumedSampleCount == 0)
    #expect(throws: PulseError.invalidState) {
        try stream.finish { _ in Issue.record("Cancelled publication") }
    }
    try stream.reset(contour: contour, timing: timing)
    try samples.withUnsafeBufferPointer { try stream.append($0, interval: timing.source) }
    enum DeliveryError: Error { case intentional }
    do {
        try stream.finish { output in
            #expect(throws: PulseError.reentrantCall) { try stream.cancel() }
            #expect(throws: PulseError.reentrantCall) {
                try stream.reset(contour: contour, timing: timing)
            }
            #expect(throws: PulseError.reentrantCall) { try stream.finish { _ in } }
            #expect(output.result.eligiblePeriodCount > 40)
            throw DeliveryError.intentional
        }
        Issue.record("Expected delivery error")
    } catch DeliveryError.intentional {}
    #expect(stream.state == .failed)
    #expect(throws: PulseError.invalidState) { try stream.finish { _ in } }
    // A reset to a different epoch and all-unvoiced block must expose no old run.
    let nextTiming = try pulseTiming(count: 400)
    let nextContour = try pulseContour(count: 400, values: Array(repeating: 0, count: 20))
    try stream.reset(contour: nextContour, timing: nextTiming)
    try samples.withUnsafeBufferPointer { try stream.append($0, interval: nextTiming.source) }
    try stream.finish { output in
        #expect(output.landmarks.isEmpty && output.periods.isEmpty && output.result.runCount == 0)
        #expect(output.result.timing.source.epoch == nextTiming.source.epoch)
    }
}

@Test func pulseStreamingRetainsExclusionsAndValidatesResetBeforeChangingState() throws {
    let contour = try pulseContour(count: 400)
    let timing = try pulseTiming(count: 400, excluded: 4)
    let config = try PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1000)
    let stream = try PreparedPulseStream<Double>(
        configuration: config, contour: contour, timing: timing, maximumTrackingAttempts: 1024,
        excludedSampleRanges: [148..<152])
    #expect(throws: PulseError.unexpectedContext) {
        try stream.reset(contour: contour, timing: timing)
    }
    #expect(throws: PulseError.capacityExceeded) {
        try stream.reset(contour: pulseContour(count: 420), timing: pulseTiming(count: 420))
    }
    try pulseCycleTrain().withUnsafeBufferPointer { try stream.append($0, interval: timing.source) }
    try stream.finish { output in
        #expect(output.result.timing.excludedSampleCount == 4)
        #expect(output.periods.contains { $0.rejections.contains(.excludedSupport) })
        #expect(output.result.runCount >= 2)
    }
}
