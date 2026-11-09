import Foundation
import Testing

@testable import HDXLVoiceProcessing

func pulseContour(count: Int, frequency: Double = 500, values: [Double]? = nil) throws
    -> PulseF0Contour
{
    let duration = Double(count) / 4000
    let frames = max(1, count / 20)
    let step = min(0.005, duration)
    return try PulseF0Contour(
        sampleRate: 4000, sampleCount: count,
        firstCenterSeconds: duration / 2 - Double(frames - 1) * step / 2,
        stepSeconds: step, ceilingHz: 1000,
        frequenciesHz: values ?? Array(repeating: frequency, count: frames))
}

func pulseTiming(count: Int, excluded: Int = 0) throws -> AnalysisTiming {
    try AnalysisTiming(
        source: SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: Int64.max - Int64(count),
            sampleCount: Int64(count), sampleRate: 4000),
        includedSampleCount: Int64(count - excluded), sourceStartSeconds: 123.5)
}

func pulseWorker(
    count: Int = 400, attempts: Int = 1024, factor: Double = 1.3
) throws -> PreparedPulseTracker<Double> {
    try PreparedPulseTracker(
        configuration: PulseConfiguration(
            sampleRate: 4000, pitchCeilingHz: 1000, maximumAdjacentPeriodFactor: factor),
        maximumSampleCount: count, maximumF0FrameCount: max(1, count / 20),
        maximumTrackingAttempts: attempts)
}

func pulseCycleTrain(count: Int = 400) -> [Double] {
    let cycle: [Double] = [0, 0, 0.5, 1, 0.5, 0, 0, 0]
    return (0..<count).map { cycle[$0 % cycle.count] }
}

func pulseSnapshot(
    _ worker: PreparedPulseTracker<Double>, _ samples: [Double], contour: PulseF0Contour? = nil,
    exclusions: [Range<Int>] = []
) throws -> PulseSnapshot {
    let pitch = try contour ?? pulseContour(count: samples.count)
    let timing = try pulseTiming(
        count: samples.count, excluded: exclusions.reduce(0) { $0 + $1.count })
    var snapshot: PulseSnapshot?
    try samples.withUnsafeBufferPointer { input in
        try worker.analyze(input, contour: pitch, timing: timing, excludedSampleRanges: exclusions)
        {
            snapshot = try $0.snapshot(maximumRecordCount: 10000)
        }
    }
    return try #require(snapshot)
}

@Test func pulseTrackerProducesFractionalPeriodsAmplitudesAndCompleteAttemptHistory() throws {
    let worker = try pulseWorker()
    let result = try pulseSnapshot(worker, pulseCycleTrain())
    #expect(result.result.unavailability == nil)
    #expect(result.result.rawPulseCount >= 48 && result.result.rawPulseCount <= 52)
    #expect(result.result.eligiblePeriodCount > 40 && result.result.availableAmplitudeCount > 38)
    #expect(result.periods.count == result.landmarks.count - 1)
    #expect(result.periodPairs.count == result.periods.count - 1)
    #expect(result.amplitudes.count == result.landmarks.count)
    #expect(result.result.timing.source.startSample == Int64.max - 400)
    #expect(result.result.timing.effectiveDelaySeconds == 0.05)
    for period in result.periods where period.isEligible {
        #expect(abs(period.durationSeconds - 0.002) < 2e-16)
        #expect(period.rightPulseIndex == period.leftPulseIndex + 1)
    }
    let weight = pow(cos(Double.pi / 3.2), 4)
    let expectedAmplitude = sqrt((1 + 0.5 * weight) / (1 + 2 * weight))
    for amplitude in result.amplitudes where amplitude.isEligible {
        #expect(abs(try #require(amplitude.rmsAmplitude) - expectedAmplitude) < 2e-12)
    }
    for point in result.landmarks {
        if let attemptIndex = point.attemptIndex {
            let attempt = result.attempts[attemptIndex]
            #expect(
                attempt.acceptedByReferenceGates && attempt.proposedSeconds == point.timeSeconds)
            #expect(attempt.voicedIntervalID == point.voicedIntervalID)
        }
    }
    #expect(result.amplitudes.first?.rejections.contains(.insufficientCycles) == true)
    #expect(worker.executionStatistics.evaluatedLagCount > result.attempts.count)
}

@Test func pulseTrackerRetainsFailedStepsAndDoesNotBridgeMissingCycles() throws {
    let worker = try pulseWorker()
    var samples = pulseCycleTrain()
    for i in 160..<240 { samples[i] = 0 }
    let result = try pulseSnapshot(worker, samples)
    #expect(result.attempts.contains { !$0.acceptedByReferenceGates })
    #expect(
        result.periods.contains {
            $0.durationSeconds > 0.005 && $0.rejections.contains(.trackingFailure)
        })
    #expect(result.result.runCount >= 2)
    for period in result.periods where period.isEligible {
        #expect(period.durationSeconds < 0.0021)
        #expect(period.runID == result.landmarks[period.leftPulseIndex].runID)
    }
    #expect(result.periods.count == result.landmarks.count - 1)
}

@Test func pulseTrackerUnvoicedAndExcludedRegionsRemainVisibleWithoutStitching() throws {
    let worker = try pulseWorker()
    let samples = pulseCycleTrain()
    let full = try pulseSnapshot(worker, samples)
    let excluded = try pulseSnapshot(worker, samples, exclusions: [148..<152])
    #expect(full.landmarks.map(\.timeSeconds) == excluded.landmarks.map(\.timeSeconds))
    #expect(excluded.result.eligiblePeriodCount < full.result.eligiblePeriodCount)
    #expect(excluded.result.timing.excludedSampleCount == 4)
    for period in excluded.periods {
        let left = excluded.landmarks[period.leftPulseIndex].timeSeconds
        let right = excluded.landmarks[period.rightPulseIndex].timeSeconds
        if left < 152.0 / 4000 && right > 148.0 / 4000 {
            #expect(!period.isEligible && period.rejections.contains(.excludedSupport))
        }
    }
    var frequencies = Array(repeating: 500.0, count: 20)
    for i in 8..<12 { frequencies[i] = 0 }
    let gap = try pulseSnapshot(
        worker, samples, contour: pulseContour(count: 400, values: frequencies))
    #expect(gap.result.voicedIntervalCount == 2 && gap.result.runCount >= 2)
    #expect(gap.periods.contains { $0.rejections.contains(.differentRun) })
    for period in gap.periods where period.isEligible {
        #expect(
            gap.landmarks[period.leftPulseIndex].voicedIntervalID
                == gap.landmarks[period.rightPulseIndex].voicedIntervalID)
    }
}

@Test func pulseTrackerRatioRejectionDoesNotEraseOtherwiseValidPeriods() throws {
    var samples = Array(repeating: 0.0, count: 360)
    var center = 3
    var cycle = 0
    while center < samples.count {
        for i in max(0, center - 4)...min(samples.count - 1, center + 4) {
            samples[i] += 0.8 * exp(-0.5 * pow(Double(i - center), 2))
        }
        center += cycle % 2 == 0 ? 8 : 10
        cycle += 1
    }
    let contour = try pulseContour(count: 360, frequency: 450)
    let permissive = try pulseSnapshot(pulseWorker(count: 360), samples, contour: contour)
    let strict = try pulseSnapshot(pulseWorker(count: 360, factor: 1.1), samples, contour: contour)
    #expect(strict.landmarks.map(\.timeSeconds) == permissive.landmarks.map(\.timeSeconds))
    #expect(strict.periods == permissive.periods)
    #expect(strict.result.eligiblePeriodCount > 25)
    #expect(strict.result.eligiblePairCount < permissive.result.eligiblePairCount)
    #expect(strict.periodPairs.contains { $0.rejections.contains(.adjacentPeriodFactor) })
}

@Test func pulseTrackerDegenerateInputsNeverBecomeUsableCycleMeasurements() throws {
    let worker = try pulseWorker()
    for value in [0.0, 0.3, 1e-200] {
        let result = try pulseSnapshot(worker, Array(repeating: value, count: 400))
        #expect(
            result.result.eligiblePeriodCount == 0 && result.result.availableAmplitudeCount == 0)
        #expect(result.result.unavailability != nil)
        #expect(result.amplitudes.allSatisfy { $0.rmsAmplitude == nil })
    }
    let unvoiced = try pulseSnapshot(
        worker, pulseCycleTrain(),
        contour: pulseContour(count: 400, values: Array(repeating: 0, count: 20)))
    #expect(unvoiced.landmarks.isEmpty && unvoiced.attempts.isEmpty)
}

@Test func pulseTrackerPreservesQuietRepresentableCyclesAndAmplitudeScaling() throws {
    let worker = try pulseWorker()
    let values = pulseCycleTrain()
    let baseline = try pulseSnapshot(worker, values)
    for gain in [1e-100, 1e-200, 1e-300, -1e-300] {
        let output = try pulseSnapshot(worker, values.map { $0 * gain })
        #expect(output.result.eligiblePeriodCount == baseline.result.eligiblePeriodCount)
        #expect(output.result.availableAmplitudeCount == baseline.result.availableAmplitudeCount)
        #expect(output.landmarks.count == baseline.landmarks.count)
        for (a, b) in zip(output.landmarks, baseline.landmarks) {
            #expect(abs(a.timeSeconds - b.timeSeconds) < 2e-16)
            #expect(a.rejections == b.rejections)
        }
        for (a, b) in zip(output.amplitudes, baseline.amplitudes) where a.isEligible && b.isEligible
        {
            #expect(
                abs(try #require(a.rmsAmplitude) / abs(gain) - #require(b.rmsAmplitude)) < 2e-12)
        }
    }
}

@Test func pulseTrackerCapacityInvalidInputReentrancyAndCallbackFailureAreRecoverable() throws {
    let worker = try pulseWorker(attempts: 4)
    let samples = pulseCycleTrain()
    let contour = try pulseContour(count: 400)
    let timing = try pulseTiming(count: 400)
    var emitted = false
    samples.withUnsafeBufferPointer { input in
        _ = #expect(throws: PulseError.capacityExceeded) {
            try worker.analyze(input, contour: contour, timing: timing) { _ in emitted = true }
        }
    }
    #expect(!emitted && worker.executionStatistics.analyzedIntervalCount == 0)
    try worker.reset()
    let unvoiced = try pulseContour(count: 400, values: Array(repeating: 0, count: 20))
    enum DeliveryFailure: Error { case intentional }
    samples.withUnsafeBufferPointer { input in
        do {
            try worker.analyze(input, contour: unvoiced, timing: timing) { output in
                #expect(throws: PulseError.reentrantCall) { try worker.reset() }
                #expect(throws: PulseError.reentrantCall) {
                    try worker.analyze(input, contour: unvoiced, timing: timing) { _ in }
                }
                #expect(throws: ContractError.intermediateBudgetExceeded) {
                    try output.snapshot(maximumRecordCount: -1)
                }
                throw DeliveryFailure.intentional
            }
            Issue.record("Expected the delivery callback to throw")
        } catch DeliveryFailure.intentional {
            // A throwing delivery must release the worker's reentrancy guard.
        } catch {
            Issue.record(error)
        }
    }
    var corrupt = samples
    corrupt[12] = .nan
    corrupt.withUnsafeBufferPointer { input in
        _ = #expect(throws: PulseError.invalidInput) {
            try worker.analyze(input, contour: unvoiced, timing: timing) { _ in emitted = true }
        }
    }
    let recovered = try pulseSnapshot(worker, samples, contour: unvoiced)
    #expect(recovered.landmarks.isEmpty && worker.executionStatistics.analyzedIntervalCount == 2)
}

@Test func pulseResultStatusDistinguishesUnavailablePeriodsFromZeroAndRetainsUnits() throws {
    let worker = try pulseWorker()
    let voiced = pulseCycleTrain()
    let silence = try pulseSnapshot(worker, Array(repeating: 0, count: 400))
    let constant = try pulseSnapshot(worker, Array(repeating: 0.3, count: 400))
    let excluded = try pulseSnapshot(worker, voiced, exclusions: [0..<400])
    let unvoiced = try pulseSnapshot(
        worker, voiced, contour: pulseContour(count: 400, values: Array(repeating: 0, count: 20)))
    for (snapshot, reason): (PulseSnapshot, UnavailabilityReason) in [
        (silence, .silence), (constant, .lowConfidence),
        (excluded, .excluded), (unvoiced, .insufficientData),
    ] {
        #expect(snapshot.result.unavailability == reason)
        #expect(snapshot.result.eligiblePeriodCount == 0)
        #expect(snapshot.result.availableAmplitudeCount == 0)
        #expect(snapshot.amplitudes.allSatisfy { $0.rmsAmplitude == nil && !$0.isEligible })
        #expect(snapshot.result.timeUnit == .seconds)
        #expect(snapshot.result.amplitudeUnit == .normalizedAmplitude)
    }
    #expect(excluded.result.timing.includedSampleCount == 0)
    #expect(excluded.result.timing.excludedSampleCount == 400)
    #expect(try pulseSnapshot(worker, voiced).result.unavailability == nil)
}

@Test func pulseOwnedSnapshotCrossesTasksAfterScratchReuseAndRetainsClockProvenance() async throws {
    let worker = try pulseWorker()
    let pcm = pulseCycleTrain()
    let contour = try pulseContour(count: 400)
    let source = try pulseTiming(count: 400).source
    let timing = try AnalysisTiming(
        source: source, includedSampleCount: 400, sourceStartSeconds: 123.5,
        hostStartNanoseconds: 1_000_000_000, completedHostNanoseconds: 1_200_000_000,
        effectiveDelaySeconds: 0.08)
    var captured: PulseSnapshot?
    try pcm.withUnsafeBufferPointer {
        try worker.analyze($0, contour: contour, timing: timing) {
            captured = try $0.snapshot(maximumRecordCount: 10000)
        }
    }
    let retained = try #require(captured)
    let originalHash = retained.hashValue
    let originalTimes = retained.landmarks.map(\.timeSeconds)
    let originalAmplitudes = retained.amplitudes.compactMap(\.rmsAmplitude)
    try worker.reset()
    let shifted = (Array(pcm.dropFirst(2)) + pcm.prefix(2)).map { $0 * 0.25 }
    let replacement = try pulseSnapshot(worker, shifted)
    #expect(replacement.landmarks.map(\.timeSeconds) != originalTimes)
    #expect(replacement.amplitudes.compactMap(\.rmsAmplitude) != originalAmplitudes)
    let received = await Task.detached { retained }.value
    #expect(received.hashValue == originalHash)
    #expect(received.landmarks.map(\.timeSeconds) == originalTimes)
    #expect(received.amplitudes.compactMap(\.rmsAmplitude) == originalAmplitudes)
    #expect(received.result.timing == timing)
    #expect(received.result.timing.source.endSample == Int64.max)
    #expect(received.result.profile == (try worker.configuration.identity()))
    #expect(received.result.f0ContourIdentity == (try contour.identity()))
}
