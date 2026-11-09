import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func jitterPCMWorker<Sample: BinaryFloatingPoint & Sendable>(
    _ type: Sample.Type, rolling: Bool = false
) throws -> PreparedPCMJitter<Sample> {
    let precision: AnalysisPrecision = type == Float.self ? .float32 : .float64
    let configuration = try JitterConfiguration(
        sampleRate: 4000, inputPrecision: precision,
        applicability: rolling ? .exploratoryRolling : .sustainedPhonation,
        rollingWindowSampleCount: rolling ? 160 : nil)
    return try PreparedPCMJitter(
        configuration: configuration,
        pulseConfiguration: PulseConfiguration(
            sampleRate: 4000, inputPrecision: precision,
            pitchCeilingHz: 1000, support: rolling ? .independentlyAnchoredBlock : .completeInterval
        ),
        maximumSampleCount: 400, maximumF0FrameCount: 20, maximumTrackingAttempts: 1024)
}

private func checkJitterPCMConstant<Sample: BinaryFloatingPoint & Sendable>(_ type: Sample.Type)
    throws
{
    let worker = try jitterPCMWorker(type)
    let samples = pulseCycleTrain().map { Sample($0) }
    let contour = try pulseContour(count: samples.count)
    let timing = try pulseTiming(count: samples.count)
    try samples.withUnsafeBufferPointer { input in
        try worker.analyze(input, contour: contour, timing: timing) { output in
            let result = output.result
            #expect(result.coverage.acceptedPeriodCount > 40)
            #expect(result.coverage.acceptedPeriodCount == output.pulses.result.eligiblePeriodCount)
            #expect(result.coverage.acceptedPairCount == output.pulses.result.eligiblePairCount)
            #expect(result.inputProvenance.kind == .acousticPulses)
            #expect(result.inputProvenance.periodSourceProfile == output.pulses.result.profile)
            #expect(result.inputProvenance.f0ContourIdentity == (try contour.identity()))
            #expect(result.dependencyTiming.source == timing.source)
            #expect(result.dependencyTiming.sourceStartSeconds == 123.5)
            #expect(result.dependencyTiming.effectiveDelaySeconds == 0.05)
            for variant in JitterVariant.allCases {
                #expect(result.estimate(variant).status == .available)
                #expect(try #require(result.estimate(variant).value) < 1e-12)
            }
            #expect(output.periods.count == output.pulses.periods.count)
            let copied = try output.snapshotPeriods(maximumCount: 1000)
            #expect(copied.count == output.periods.count)
            #expect(throws: JitterError.capacityExceeded) {
                try output.snapshotPeriods(maximumCount: 0)
            }
        }
    }
}

@Test func jitterPCMConstantPeriodsWorkInBothInputPrecisions() throws {
    try checkJitterPCMConstant(Float.self)
    try checkJitterPCMConstant(Double.self)
}

@Test func jitterPCMExclusionsSilenceAndExploratoryQueryRetainTheirMeaning() throws {
    let worker = try jitterPCMWorker(Double.self)
    let samples = pulseCycleTrain()
    let contour = try pulseContour(count: samples.count)
    let masked = try pulseTiming(count: samples.count, excluded: 80)
    try samples.withUnsafeBufferPointer { input in
        try worker.analyze(
            input, contour: contour, timing: masked, excludedSampleRanges: [100..<180]
        ) { output in
            #expect(output.result.coverage.rejections.excluded > 0)
            #expect(output.result.dependencyTiming.includedSampleCount == 320)
            #expect(output.result.coverage.durationCoverage < 1)
            for period in output.periods where period.rejections.isEmpty {
                #expect(period.endSeconds <= 0.025 || period.startSeconds >= 0.045)
            }
        }
    }
    let silent = try Array(repeating: 0.0, count: 400).withUnsafeBufferPointer {
        try worker.analyze($0, contour: contour, timing: pulseTiming(count: 400))
    }
    for variant in JitterVariant.allCases {
        #expect(
            silent.estimate(variant).value == nil
                && silent.estimate(variant).unavailability == .silence)
    }
    let allExcluded = try samples.withUnsafeBufferPointer {
        try worker.analyze(
            $0, contour: contour, timing: pulseTiming(count: 400, excluded: 400),
            excludedSampleRanges: [0..<400])
    }
    #expect(
        allExcluded.local.unavailability == .excluded
            && allExcluded.coverage.acceptedPeriodCount == 0)
    let rolling = try jitterPCMWorker(Double.self, rolling: true)
    let preview = try samples.withUnsafeBufferPointer {
        try rolling.analyze($0, contour: contour, timing: pulseTiming(count: 400))
    }
    #expect(preview.applicability == .exploratoryRolling)
    #expect(preview.query.startSeconds == 0.1 - 0.04 && preview.query.endSeconds == 0.1)
    #expect(preview.coverage.acceptedPeriodCount < 25 && preview.coverage.acceptedPeriodCount > 10)
    if case .available(let estimate) = try preview.measurementResult(.local).outcome {
        #expect(estimate.warnings.contains(.exploratoryApplicability))
    } else {
        Issue.record("Expected an available exploratory constant-period estimate")
    }
}

@Test func jitterPCMProfileMismatchAndReentrancyCannotPublishPartialResults() throws {
    #expect(throws: JitterError.invalidConfiguration) {
        try PreparedPCMJitter<Double>(
            configuration: JitterConfiguration(sampleRate: 4000),
            pulseConfiguration: PulseConfiguration(
                sampleRate: 4000, maximumAdjacentPeriodFactor: 2),
            maximumSampleCount: 400, maximumF0FrameCount: 20, maximumTrackingAttempts: 1024)
    }
    #expect(throws: JitterError.invalidConfiguration) {
        try PreparedPCMJitter<Double>(
            configuration: JitterConfiguration(sampleRate: 4000),
            pulseConfiguration: PulseConfiguration(
                sampleRate: 4000, support: .independentlyAnchoredBlock),
            maximumSampleCount: 400, maximumF0FrameCount: 20, maximumTrackingAttempts: 1024)
    }
    let worker = try jitterPCMWorker(Double.self)
    let samples = pulseCycleTrain()
    let contour = try pulseContour(count: samples.count)
    let timing = try pulseTiming(count: samples.count)
    enum ConsumerFailure: Error { case intentional }
    try samples.withUnsafeBufferPointer { input in
        var consumerThrew = false
        do {
            try worker.analyze(input, contour: contour, timing: timing) { _ in
                #expect(throws: JitterError.reentrantCall) { try worker.reset() }
                #expect(throws: JitterError.reentrantCall) {
                    try worker.analyze(input, contour: contour, timing: timing)
                }
                throw ConsumerFailure.intentional
            }
        } catch ConsumerFailure.intentional {
            consumerThrew = true
        }
        #expect(consumerThrew)
        let recovered = try worker.analyze(input, contour: contour, timing: timing)
        #expect(recovered.local.status == .available)
    }
    try worker.reset()
    var invalid = samples
    invalid[399] = .nan
    var emitted = false
    #expect(throws: PulseError.invalidInput) {
        try invalid.withUnsafeBufferPointer {
            try worker.analyze($0, contour: contour, timing: timing) { _ in emitted = true }
        }
    }
    #expect(!emitted)
}

private struct JitterPCMFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let sampleRate, sampleCount: Int
        let inputPrecision: AnalysisPrecision
    }
    struct Reference: Decodable {
        struct Pitch: Decodable {
            let firstCenterSeconds, stepSeconds, ceilingHz: Double
            let frequenciesHz: [Double]
        }
        let inputSHA256: String
        let pitch: Pitch
    }
    let `case`: Case
    let reference: Reference
}

private struct JitterPCMIntegrationRow: Encodable {
    let name: String
    let inputSHA256: String
    let sourceContext: String
    let result: JitterAnalysisResult
    let rawPulseCount: Int
    let pulseEligiblePeriods: Int
}

private func jitterPCMIntegration<Sample: BinaryFloatingPoint & Sendable>(
    _ type: Sample.Type, fixture: JitterPCMFixture, samples: [Double], exploratory: Bool
) throws -> JitterPCMIntegrationRow {
    let item = fixture.case
    let pitch = fixture.reference.pitch
    let contour = try PulseF0Contour(
        sampleRate: item.sampleRate, sampleCount: samples.count,
        firstCenterSeconds: pitch.firstCenterSeconds, stepSeconds: pitch.stepSeconds,
        ceilingHz: pitch.ceilingHz, frequenciesHz: pitch.frequenciesHz)
    let configuration = try JitterConfiguration(
        sampleRate: item.sampleRate, inputPrecision: item.inputPrecision,
        applicability: exploratory ? .exploratoryRolling : .sustainedPhonation,
        rollingWindowSampleCount: exploratory ? item.sampleRate / 4 : nil)
    let worker = try PreparedPCMJitter<Sample>(
        configuration: configuration,
        pulseConfiguration: PulseConfiguration(
            sampleRate: item.sampleRate, inputPrecision: item.inputPrecision,
            pitchCeilingHz: pitch.ceilingHz),
        maximumSampleCount: samples.count, maximumF0FrameCount: pitch.frequenciesHz.count,
        maximumTrackingAttempts: 4096)
    let timing = try AnalysisTiming(
        source: SourceInterval(
            epoch: StreamEpoch(streamID: UUID()),
            startSample: Int64.max - Int64(samples.count), sampleCount: Int64(samples.count),
            sampleRate: Double(item.sampleRate)),
        includedSampleCount: Int64(samples.count), sourceStartSeconds: 20)
    var row: JitterPCMIntegrationRow?
    try samples.map { Sample($0) }.withUnsafeBufferPointer { input in
        try worker.analyze(input, contour: contour, timing: timing) { output in
            #expect(
                output.result.coverage.acceptedPeriodCount
                    <= output.pulses.result.eligiblePeriodCount)
            #expect(
                output.result.coverage.acceptedPairCount <= output.pulses.result.eligiblePairCount)
            #expect(
                output.result.coverage.durationCoverage >= 0
                    && output.result.coverage.durationCoverage <= 1)
            #expect(output.result.coverage.acceptedPeriodCount > 0, "\(item.name)")
            for variant in JitterVariant.allCases {
                let estimate = output.result.estimate(variant)
                if let value = estimate.value {
                    #expect(value.isFinite && value >= 0)
                } else {
                    #expect(estimate.status == .unavailable && estimate.unavailability != nil)
                }
            }
            if let rap = output.result.rap.value { #expect(output.result.ddp.value == 3 * rap) }
            row = JitterPCMIntegrationRow(
                name: item.name, inputSHA256: fixture.reference.inputSHA256,
                sourceContext: item.name.contains("speech-")
                    ? (item.name.contains("vowel")
                        ? "licensed sustained vowel; no diagnostic claim"
                        : "licensed speech; exploratory only")
                    : "original synthetic waveform",
                result: output.result, rawPulseCount: output.pulses.result.rawPulseCount,
                pulseEligiblePeriods: output.pulses.result.eligiblePeriodCount)
        }
    }
    return try #require(row)
}

@Test func jitterPCMIntegrationExercisesSyntheticLicensedVowelsAndExploratorySpeech() throws {
    let directory = try #require(
        Bundle.module.url(forResource: "Pulses", withExtension: nil, subdirectory: "Fixtures"))
    let names = [
        "gaussian-16000-150", "jitter-1pct", "jitter-12pct", "rising-f0",
        "speech-bl01-vowel-a", "speech-bl02-vowel-a", "speech-bl03-vowel-a",
        "speech-bl01-all-voiced", "speech-bl02-consonant-rich",
    ]
    var rows: [JitterPCMIntegrationRow] = []
    for name in names {
        for precision in [AnalysisPrecision.float32, .float64] {
            let fullName = name + "-" + precision.rawValue
            let fixture = try JSONDecoder().decode(
                JitterPCMFixture.self,
                from: Data(contentsOf: directory.appendingPathComponent(fullName + ".json")))
            let wave = try Data(contentsOf: directory.appendingPathComponent(fullName + ".wav"))
            let hash = SHA256.hash(data: wave).map { String(format: "%02x", $0) }.joined()
            #expect(hash == fixture.reference.inputSHA256)
            let pcm = try CorpusPCM(data: wave)
            #expect(
                pcm.sampleRate == fixture.case.sampleRate
                    && pcm.samples.count == fixture.case.sampleCount)
            let exploratory =
                name == "rising-f0" || (name.hasPrefix("speech-") && !name.contains("vowel"))
            let row =
                try precision == .float32
                ? jitterPCMIntegration(
                    Float.self, fixture: fixture, samples: pcm.samples, exploratory: exploratory)
                : jitterPCMIntegration(
                    Double.self, fixture: fixture, samples: pcm.samples, exploratory: exploratory)
            if name == "jitter-1pct" || name == "jitter-12pct" {
                // The original source repeats period offsets [-1, .5, 1, -.5, 0]
                // at 150 Hz. Its complete-cycle limits are local=j, RAP=.6j,
                // PPQ5=.6j and DDP=1.8j. A finite cropped acoustic sequence has
                // endpoint and tracking effects; these are broad behavior checks,
                // separate from the exact supplied-period reference comparisons.
                let amount = name == "jitter-1pct" ? 0.01 : 0.12
                for (variant, expected, tolerance) in [
                    (JitterVariant.local, amount, amount * 0.05),
                    (.absolute, amount / 150, amount / 3000),
                    (.rap, amount * 0.6, amount * 0.05),
                    (.ppq5, amount * 0.6, amount * 0.05),
                    (.ddp, amount * 1.8, amount * 0.15),
                ] {
                    let observed = try #require(row.result.estimate(variant).value)
                    #expect(abs(observed - expected) <= tolerance, "\(fullName) \(variant)")
                }
            }
            rows.append(row)
        }
    }
    #expect(rows.count == 18)
    if let path = ProcessInfo.processInfo.environment["HDXL_JITTER_PCM_REPORT"] {
        let destination = URL(filePath: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try canonicalContractJSON(rows).write(to: destination)
    }
}
