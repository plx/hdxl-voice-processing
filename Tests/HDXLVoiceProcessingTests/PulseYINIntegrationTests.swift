import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct PulseYINFixture: Decodable {
    struct Frame: Decodable {
        let frameIndex, startSample, observedSampleCount: Int
        let status: YINVoicingStatus
        let reason: UnavailabilityReason?
        let frequencyHz: Double
    }
    struct Pitch: Decodable {
        let firstCenterSeconds, stepSeconds, ceilingHz: Double
        let frequenciesHz: [Double]
    }
    struct Source: Decodable {
        let profile: YINConfiguration
        let samples: [Double]
        let pitch: Pitch
        let frames: [Frame]
    }
    struct External: Decodable {
        struct Output: Decodable {
            struct Amplitude: Decodable {
                let pulseIndex: Int
                let rmsAmplitude: Double
            }
            let pulseTimesSeconds: [Double]
            let amplitudes: [Amplitude]
        }
        let inputSHA256: String
        let data: Output
    }
    let name: String
    let source: Source
    let external: External
}

private func pulseYINRun<Sample: BinaryFloatingPoint & Sendable>(
    _ fixture: PulseYINFixture, samples: [Sample], backend: YINDifferenceBackend,
    chunked: Bool, epoch: StreamEpoch
) throws -> (PulseSnapshot, Double) {
    let original = fixture.source.profile
    let configuration = try YINConfiguration(
        sampleRate: original.sampleRate, inputPrecision: original.inputPrecision,
        pitchFloorHz: original.pitchFloorHz, pitchCeilingHz: original.pitchCeilingHz,
        integrationLength: original.integrationLength, hopLength: original.hopLength,
        threshold: original.threshold, silenceRMSThreshold: original.silenceRMSThreshold,
        differenceBackend: backend)
    let profile = YINProfile(estimator: configuration)
    let worker = try PreparedYINAnalyzer<Sample>(profile: profile, epoch: epoch)
    var frequencies: [Double] = []
    var maximumF0Error = 0.0
    var partialFrames = 0
    func collect(_ output: BorrowedYINAnalysisOutput) {
        let raw = output.raw.result
        #expect(output.tracked == nil)
        if raw.timing.source.sampleCount != Int64(raw.requiredSampleCount) {
            partialFrames += 1
            #expect(raw.status == .unavailable && raw.unavailability == .insufficientData)
            return
        }
        do {
            let i = frequencies.count
            try #require(i < fixture.source.frames.count)
            let expected = fixture.source.frames[i]
            #expect(raw.frameIndex == UInt64(expected.frameIndex))
            #expect(raw.timing.source.startSample == Int64(expected.startSample))
            #expect(raw.timing.source.sampleCount == Int64(expected.observedSampleCount))
            #expect(raw.status == expected.status && raw.unavailability == expected.reason)
            // This explicitly chosen recipe does not force uncertain estimates voiced.
            let frequency = raw.status == .voiced ? try #require(raw.observation).frequencyHz : 0
            maximumF0Error = max(maximumF0Error, abs(frequency - expected.frequencyHz))
            #expect(abs(frequency - expected.frequencyHz) <= 0.001)
            frequencies.append(frequency)
        } catch { Issue.record(error, "\(fixture.name)/\(backend)/YIN frame") }
    }
    try samples.withUnsafeBufferPointer { input in
        var offset = 0
        let sizes = chunked ? [13, 1, 17, 256] : [input.count]
        var turn = 0
        while offset < input.count {
            let end = min(input.count, offset + sizes[turn % sizes.count])
            let interval = try SourceInterval(
                epoch: epoch, startSample: Int64(offset), sampleCount: Int64(end - offset),
                sampleRate: Double(configuration.sampleRate))
            try worker.process(
                UnsafeBufferPointer(rebasing: input[offset..<end]), interval: interval,
                emit: collect)
            offset = end
            turn += 1
        }
    }
    try worker.finish(emit: collect)
    #expect(partialFrames == 1)
    try #require(frequencies.count == fixture.source.frames.count)
    let contour = try PulseF0Contour(
        sampleRate: configuration.sampleRate, sampleCount: samples.count,
        firstCenterSeconds: Double(configuration.requiredSampleCount)
            / (2 * Double(configuration.sampleRate)),
        stepSeconds: Double(configuration.hopLength) / Double(configuration.sampleRate),
        ceilingHz: configuration.pitchCeilingHz, frequenciesHz: frequencies,
        sourceProfile: profile.identity())
    #expect(contour.firstCenterSeconds == fixture.source.pitch.firstCenterSeconds)
    #expect(contour.stepSeconds == fixture.source.pitch.stepSeconds)
    #expect(try contour.observation(atRelativeSeconds: 0).unavailability == .outsideContour)
    let pulseConfiguration = try PulseConfiguration(
        sampleRate: configuration.sampleRate, inputPrecision: configuration.inputPrecision,
        pitchFloorHz: configuration.pitchFloorHz, pitchCeilingHz: configuration.pitchCeilingHz)
    let pulseWorker = try PreparedPulseTracker<Sample>(
        configuration: pulseConfiguration, maximumSampleCount: samples.count,
        maximumF0FrameCount: frequencies.count, maximumTrackingAttempts: 4096)
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: Int64(samples.count),
        sampleRate: Double(configuration.sampleRate))
    var snapshot: PulseSnapshot?
    try samples.withUnsafeBufferPointer {
        try pulseWorker.analyze(
            $0, contour: contour,
            timing: AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        ) {
            snapshot = try $0.snapshot(maximumRecordCount: 30_000)
        }
    }
    let result = try #require(snapshot)
    #expect(result.result.f0SourceProfile == (try profile.identity()))
    #expect(result.result.f0ContourIdentity == (try contour.identity()))
    #expect(result.result.timing.source == source)
    if frequencies.allSatisfy({ $0 == 0 }) {
        #expect(result.landmarks.isEmpty && result.periods.isEmpty && result.amplitudes.isEmpty)
        #expect(result.result.unavailability != nil)
    }
    return (result, maximumF0Error)
}

@Test func pulseYINIntegrationKeepsPitchErrorSeparateAndChunkingInvariant() throws {
    let directory: URL
    if let path = ProcessInfo.processInfo.environment["HDXL_PULSE_YIN_DIRECTORY"] {
        try #require(!path.isEmpty)
        directory = URL(filePath: path, directoryHint: .isDirectory)
    } else {
        directory = try #require(
            Bundle.module.url(forResource: "PulseYIN", withExtension: nil, subdirectory: "Fixtures")
        )
    }
    struct Manifest: Decodable { let cases: [String] }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    try #require(manifest.cases.count == 16)
    var audit: [[String: Any]] = []
    for name in manifest.cases {
        let fixture = try JSONDecoder().decode(
            PulseYINFixture.self, from: Data(contentsOf: directory.appending(path: name + ".json")))
        let data = try Data(contentsOf: directory.appending(path: name + ".wav"))
        #expect(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                == fixture.external.inputSHA256)
        let pcm = try CorpusPCM(data: data)
        try #require(
            pcm.samples == fixture.source.samples
                && pcm.sampleRate == fixture.source.profile.sampleRate)
        for backend in YINDifferenceBackend.allCases {
            let epoch = StreamEpoch(streamID: UUID())
            func run(_ chunked: Bool) throws -> (PulseSnapshot, Double) {
                switch fixture.source.profile.inputPrecision {
                case .float32:
                    try pulseYINRun(
                        fixture, samples: pcm.samples.map(Float.init), backend: backend,
                        chunked: chunked, epoch: epoch)
                case .float64:
                    try pulseYINRun(
                        fixture, samples: pcm.samples, backend: backend, chunked: chunked,
                        epoch: epoch)
                }
            }
            let (direct, f0Error) = try run(false)
            let (chunked, chunkedF0Error) = try run(true)
            #expect(direct == chunked && f0Error == chunkedF0Error)
            try #require(
                direct.landmarks.count == fixture.external.data.pulseTimesSeconds.count,
                "\(name)/\(backend)")
            var positionError = 0.0
            for (a, b) in zip(direct.landmarks, fixture.external.data.pulseTimesSeconds) {
                positionError = max(positionError, abs(a.timeSeconds - b) * Double(pcm.sampleRate))
            }
            #expect(positionError <= 1e-6, "\(name)/\(backend): separate end-to-end position error")
            var amplitudeFraction = 0.0
            var amplitudeCount = 0
            for observation in direct.amplitudes {
                guard let actual = observation.rmsAmplitude else { continue }
                let expected = try #require(
                    fixture.external.data.amplitudes.first {
                        $0.pulseIndex == observation.pulseIndex
                    }
                ).rmsAmplitude
                amplitudeFraction = max(
                    amplitudeFraction, abs(actual - expected) / (2e-12 + 1e-10 * abs(expected)))
                amplitudeCount += 1
            }
            #expect(
                amplitudeFraction <= 1, "\(name)/\(backend): separate end-to-end amplitude error")
            audit.append([
                "name": name, "backend": backend.rawValue,
                "fullYINFrames": fixture.source.frames.count,
                "maximumF0ErrorHz": f0Error, "maximumPulseErrorSamples": positionError,
                "rawPulseCount": direct.landmarks.count,
                "eligiblePeriods": direct.result.eligiblePeriodCount,
                "amplitudeComparisons": amplitudeCount,
                "maximumAmplitudeBudgetFraction": amplitudeFraction,
            ])
        }
    }
    if let path = ProcessInfo.processInfo.environment["HDXL_PULSE_YIN_REPORT"] {
        try #require(!path.isEmpty)
        try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "scope":
                    "Native YIN-to-pulse integration compared with independent YIN and external pulses; not oracle-F0 parity or physical accuracy",
                "results": audit,
            ], options: [.sortedKeys, .prettyPrinted]
        ).write(to: URL(filePath: path))
    }
    print("PULSE_YIN_INTEGRATION cases=16 backends=2 chunkPatterns=2")
}
