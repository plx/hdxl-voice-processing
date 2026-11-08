import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct PulseHistoryFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let sampleRate, sampleCount: Int
        let inputPrecision: AnalysisPrecision
        let minimumSeconds, maximumSeconds, maximumAdjacentFactor: Double
        let excludedSamples: [[Int]]
    }
    struct Pitch: Decodable {
        let firstCenterSeconds, stepSeconds, ceilingHz: Double
        let frequenciesHz: [Double]
    }
    struct Point: Decodable {
        let index, voicedIntervalID, stepIndex: Int
        let timeSeconds: Double
        let runID, attemptIndex: Int?
        let direction: String
        let rejections: [String]
    }
    struct Attempt: Decodable {
        let index, voicedIntervalID, stepIndex, observedPairCount: Int
        let firstRequiredSampleIndex, lastRequiredSampleIndex: Int
        let direction: String
        let fromSeconds, proposedSeconds, frequencyHz, amplitudeGatePeak, curvature: Double
        let correlation: Double?
        let selectedSyntheticCandidate, acceptedByReferenceGates, usedRangeFallback: Bool
        let rejections: [String]
    }
    struct Period: Decodable {
        let index, leftPulseIndex, rightPulseIndex: Int
        let durationSeconds: Double
        let runID: Int?
        let rejections: [String]
    }
    struct Pair: Decodable {
        let index, leftPeriodIndex, rightPeriodIndex: Int
        let ratio: Double
        let rejections: [String]
    }
    struct Amplitude: Decodable {
        let pulseIndex, observedSampleCount: Int
        let rmsAmplitude, supportStartSeconds, supportEndSeconds: Double?
        let rejections: [String]
    }
    struct Oracle: Decodable {
        let inputSamples: [Double]
        let pitch: Pitch
        let voicedIntervals: [[Double]]
        let landmarks: [Point]
        let attempts: [Attempt]
        let periods: [Period]
        let periodPairs: [Pair]
        let amplitudes: [Amplitude]
        let runCount: Int
    }
    struct Reference: Decodable { let inputSHA256: String }
    let `case`: Case
    let oracle: Oracle
    let reference: Reference
}

private let pulseHistoryReasons: [String: PulseRejections] = [
    "outsideAcquisition": .outsideAcquisition, "outsideVoicedInterval": .outsideVoicedInterval,
    "insufficientSupport": .insufficientSupport, "silence": .silence,
    "degenerateWaveform": .degenerateWaveform, "illConditionedPeak": .illConditionedPeak,
    "numericalFailure": .numericalFailure, "excludedSupport": .excludedSupport,
    "trackingFailure": .trackingFailure, "differentRun": .differentRun,
    "periodBelowMinimum": .periodBelowMinimum, "periodAboveMaximum": .periodAboveMaximum,
    "adjacentPeriodFactor": .adjacentPeriodFactor, "insufficientCycles": .insufficientCycles,
    "lowCorrelation": .lowCorrelation, "lowAmplitude": .lowAmplitude,
    "priorIntervalCollision": .priorIntervalCollision, "rangeFallback": .rangeFallback,
]

private func pulseHistoryCheckReasons(_ actual: PulseRejections, _ expected: [String]) throws {
    var value: PulseRejections = []
    for name in expected { value.formUnion(try #require(pulseHistoryReasons[name])) }
    #expect(actual == value, "Expected \(expected), received reason bits \(actual.rawValue)")
}

private func pulseHistoryCheckTime(_ actual: Double?, _ expected: Double?, rate: Int) throws {
    #expect((actual == nil) == (expected == nil))
    if let expected {
        let actual = try #require(actual)
        #expect(abs(actual - expected) * Double(rate) <= 2e-10)
    }
}

private func pulseHistoryCompare(_ output: PulseSnapshot, _ fixture: PulseHistoryFixture) throws {
    let oracle = fixture.oracle
    let rate = fixture.case.sampleRate
    try #require(output.landmarks.count == oracle.landmarks.count)
    try #require(output.attempts.count == oracle.attempts.count)
    try #require(output.periods.count == oracle.periods.count)
    try #require(output.periodPairs.count == oracle.periodPairs.count)
    try #require(output.amplitudes.count == oracle.amplitudes.count)
    #expect(output.result.rawPulseCount == oracle.landmarks.count)
    #expect(output.result.trackingAttemptCount == oracle.attempts.count)
    #expect(output.result.voicedIntervalCount == oracle.voicedIntervals.count)
    #expect(output.result.runCount == oracle.runCount)
    #expect(
        output.result.eligiblePulseCount == oracle.landmarks.filter { $0.rejections.isEmpty }.count)
    #expect(
        output.result.eligiblePeriodCount == oracle.periods.filter { $0.rejections.isEmpty }.count)
    #expect(
        output.result.eligiblePairCount == oracle.periodPairs.filter { $0.rejections.isEmpty }.count
    )
    #expect(
        output.result.availableAmplitudeCount
            == oracle.amplitudes.filter { $0.rmsAmplitude != nil }.count)
    for (a, e) in zip(output.landmarks, oracle.landmarks) {
        try pulseHistoryCheckTime(a.timeSeconds, e.timeSeconds, rate: rate)
        #expect(
            a.index == e.index && a.voicedIntervalID == e.voicedIntervalID && a.runID == e.runID)
        #expect(
            a.stepIndex == e.stepIndex && a.attemptIndex == e.attemptIndex
                && a.direction.rawValue == e.direction)
        try pulseHistoryCheckReasons(a.rejections, e.rejections)
    }
    for (a, e) in zip(output.attempts, oracle.attempts) {
        #expect(
            a.index == e.index && a.voicedIntervalID == e.voicedIntervalID
                && a.stepIndex == e.stepIndex)
        #expect(a.direction.rawValue == e.direction)
        try pulseHistoryCheckTime(a.fromSeconds, e.fromSeconds, rate: rate)
        try pulseHistoryCheckTime(a.proposedSeconds, e.proposedSeconds, rate: rate)
        #expect(abs(a.frequencyHz - e.frequencyHz) <= 1e-10)
        #expect((a.correlation == nil) == (e.correlation == nil))
        if let expected = e.correlation {
            #expect(abs(try #require(a.correlation) - expected) <= 2e-12)
        }
        #expect(
            abs(a.curvature - e.curvature) <= 2e-12 && a.amplitudeGatePeak == e.amplitudeGatePeak)
        #expect(a.observedPairCount == e.observedPairCount)
        #expect(
            a.firstRequiredSampleIndex == e.firstRequiredSampleIndex
                && a.lastRequiredSampleIndex == e.lastRequiredSampleIndex)
        #expect(a.selectedSyntheticCandidate == e.selectedSyntheticCandidate)
        #expect(
            a.acceptedByReferenceGates == e.acceptedByReferenceGates
                && a.usedRangeFallback == e.usedRangeFallback)
        try pulseHistoryCheckReasons(a.rejections, e.rejections)
    }
    for (a, e) in zip(output.periods, oracle.periods) {
        #expect(
            a.index == e.index && a.leftPulseIndex == e.leftPulseIndex
                && a.rightPulseIndex == e.rightPulseIndex)
        #expect(a.runID == e.runID && a.isEligible == e.rejections.isEmpty)
        try pulseHistoryCheckTime(a.durationSeconds, e.durationSeconds, rate: rate)
        try pulseHistoryCheckReasons(a.rejections, e.rejections)
    }
    for (a, e) in zip(output.periodPairs, oracle.periodPairs) {
        #expect(
            a.index == e.index && a.leftPeriodIndex == e.leftPeriodIndex
                && a.rightPeriodIndex == e.rightPeriodIndex)
        #expect(abs(a.ratio - e.ratio) <= 2e-12 && a.isEligible == e.rejections.isEmpty)
        try pulseHistoryCheckReasons(a.rejections, e.rejections)
    }
    for (a, e) in zip(output.amplitudes, oracle.amplitudes) {
        #expect(a.pulseIndex == e.pulseIndex && a.observedSampleCount == e.observedSampleCount)
        #expect((a.rmsAmplitude == nil) == (e.rmsAmplitude == nil))
        if let expected = e.rmsAmplitude {
            #expect(abs(try #require(a.rmsAmplitude) - expected) <= 2e-12 + 1e-10 * abs(expected))
        }
        try pulseHistoryCheckTime(a.supportStartSeconds, e.supportStartSeconds, rate: rate)
        try pulseHistoryCheckTime(a.supportEndSeconds, e.supportEndSeconds, rate: rate)
        try pulseHistoryCheckReasons(a.rejections, e.rejections)
    }
}

private func pulseHistoryRun<Sample: BinaryFloatingPoint & Sendable>(
    _ fixture: PulseHistoryFixture, samples: [Sample], chunked: Bool
) throws {
    let item = fixture.case
    let pitch = fixture.oracle.pitch
    let configuration = try PulseConfiguration(
        sampleRate: item.sampleRate, inputPrecision: item.inputPrecision,
        pitchCeilingHz: pitch.ceilingHz,
        minimumPeriodSeconds: item.minimumSeconds, maximumPeriodSeconds: item.maximumSeconds,
        maximumAdjacentPeriodFactor: item.maximumAdjacentFactor,
        support: chunked ? .independentlyAnchoredBlock : .completeInterval)
    let contour = try PulseF0Contour(
        sampleRate: item.sampleRate, sampleCount: samples.count,
        firstCenterSeconds: pitch.firstCenterSeconds,
        stepSeconds: pitch.stepSeconds, ceilingHz: pitch.ceilingHz,
        frequenciesHz: pitch.frequenciesHz)
    let exclusions = try item.excludedSamples.map { pair -> Range<Int> in
        try #require(pair.count == 2)
        return pair[0]..<pair[1]
    }
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: Int64.max - Int64(samples.count),
        sampleCount: Int64(samples.count), sampleRate: Double(item.sampleRate))
    let timing = try AnalysisTiming(
        source: source,
        includedSampleCount: source.sampleCount - Int64(exclusions.reduce(0) { $0 + $1.count }))
    var deliveries = 0
    func consume(_ output: BorrowedPulseOutput) throws {
        deliveries += 1
        #expect(output.result.timing.source == source)
        #expect(output.result.f0ContourIdentity == (try contour.identity()))
        #expect(output.result.profile == (try configuration.identity()))
        try pulseHistoryCompare(output.snapshot(maximumRecordCount: 30000), fixture)
    }
    if chunked {
        let stream = try PreparedPulseStream<Sample>(
            configuration: configuration, contour: contour, timing: timing,
            maximumTrackingAttempts: 4096, excludedSampleRanges: exclusions)
        let sizes = [1, 17, 64, 3, 511]
        try samples.withUnsafeBufferPointer { input in
            var offset = 0
            var turn = 0
            while offset < input.count {
                let end = min(input.count, offset + sizes[turn % sizes.count])
                let interval = try SourceInterval(
                    epoch: source.epoch, startSample: source.startSample + Int64(offset),
                    sampleCount: Int64(end - offset), sampleRate: source.sampleRate)
                try stream.append(
                    UnsafeBufferPointer(rebasing: input[offset..<end]), interval: interval)
                #expect(deliveries == 0)
                offset = end
                turn += 1
            }
        }
        try stream.finish(emit: consume)
    } else {
        let worker = try PreparedPulseTracker<Sample>(
            configuration: configuration, maximumSampleCount: samples.count,
            maximumF0FrameCount: pitch.frequenciesHz.count, maximumTrackingAttempts: 4096)
        try samples.withUnsafeBufferPointer {
            try worker.analyze(
                $0, contour: contour, timing: timing, excludedSampleRanges: exclusions,
                emit: consume)
        }
    }
    #expect(deliveries == 1)
}

@Test(arguments: [false, true])
func pulseHistoriesMatchIndependentGraphQualificationAndAllFailedSteps(chunked: Bool) throws {
    let directory: URL
    if let path = ProcessInfo.processInfo.environment["HDXL_PULSE_HISTORY_DIRECTORY"] {
        try #require(!path.isEmpty)
        directory = URL(filePath: path, directoryHint: .isDirectory)
    } else {
        directory = try #require(
            Bundle.module.url(
                forResource: "PulseHistories", withExtension: nil, subdirectory: "Fixtures"))
    }
    struct Manifest: Decodable { let catalog: [PulseHistoryFixture.Case] }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    try #require(manifest.catalog.count == 50)
    var attempts = 0
    var periods = 0
    var pairs = 0
    for item in manifest.catalog {
        let fixture = try JSONDecoder().decode(
            PulseHistoryFixture.self,
            from: Data(contentsOf: directory.appending(path: item.name + ".json")))
        let wave = try Data(contentsOf: directory.appending(path: item.name + ".wav"))
        let digest = SHA256.hash(data: wave).map { String(format: "%02x", $0) }.joined()
        try #require(digest == fixture.reference.inputSHA256)
        let pcm = try CorpusPCM(data: wave)
        try #require(
            pcm.sampleRate == item.sampleRate && pcm.samples == fixture.oracle.inputSamples
                && pcm.samples.count == item.sampleCount)
        do {
            switch item.inputPrecision {
            case .float32:
                try pulseHistoryRun(fixture, samples: pcm.samples.map(Float.init), chunked: chunked)
            case .float64: try pulseHistoryRun(fixture, samples: pcm.samples, chunked: chunked)
            }
        } catch { Issue.record(error, "\(item.name), chunked=\(chunked)") }
        attempts += fixture.oracle.attempts.count
        periods += fixture.oracle.periods.count
        pairs += fixture.oracle.periodPairs.count
    }
    print(
        "PULSE_HISTORY_CONFORMANCE chunked=\(chunked) cases=50 attempts=\(attempts) rawPeriods=\(periods) adjacentPairs=\(pairs)"
    )
}
