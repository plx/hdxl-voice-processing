import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct ShimmerPCMFixture: Decodable {
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

private struct ShimmerPCMIntegrationRow: Encodable {
    let name: String
    let inputSHA256: String
    let sourceContext: String
    let result: ShimmerAnalysisResult
    let rawPulseCount: Int
    let pulseEligibleAmplitudes: Int
}

private func shimmerPCMIntegration<Sample: BinaryFloatingPoint & Sendable>(
    _ type: Sample.Type, fixture: ShimmerPCMFixture, samples: [Double], exploratory: Bool
) throws -> ShimmerPCMIntegrationRow {
    let item = fixture.case
    let pitch = fixture.reference.pitch
    let contour = try PulseF0Contour(
        sampleRate: item.sampleRate, sampleCount: samples.count,
        firstCenterSeconds: pitch.firstCenterSeconds, stepSeconds: pitch.stepSeconds,
        ceilingHz: pitch.ceilingHz, frequenciesHz: pitch.frequenciesHz)
    let configuration = try ShimmerConfiguration(
        sampleRate: item.sampleRate, inputPrecision: item.inputPrecision,
        applicability: exploratory ? .exploratoryRolling : .sustainedPhonation,
        rollingWindowSampleCount: exploratory ? item.sampleRate / 4 : nil)
    let worker = try PreparedPCMShimmer<Sample>(
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
    var row: ShimmerPCMIntegrationRow?
    try samples.map { Sample($0) }.withUnsafeBufferPointer { input in
        try worker.analyze(input, contour: contour, timing: timing) { output in
            #expect(
                output.result.coverage.acceptedAmplitudeCount
                    <= output.pulses.result.availableAmplitudeCount)
            #expect(
                output.result.coverage.acceptedPairCount <= output.pulses.result.eligiblePairCount)
            #expect(
                output.result.coverage.durationCoverage >= 0
                    && output.result.coverage.durationCoverage <= 1)
            #expect(output.result.coverage.acceptedAmplitudeCount > 0, "\(item.name)")
            for variant in ShimmerVariant.allCases {
                let estimate = output.result.estimate(variant)
                if let value = estimate.value {
                    #expect(value.isFinite && value >= 0)
                } else {
                    #expect(estimate.status == .unavailable && estimate.unavailability != nil)
                }
            }
            if let apq3 = output.result.apq3.value { #expect(output.result.dda.value == 3 * apq3) }
            row = ShimmerPCMIntegrationRow(
                name: item.name, inputSHA256: fixture.reference.inputSHA256,
                sourceContext: item.name.contains("speech-")
                    ? (item.name.contains("vowel")
                        ? "licensed sustained vowel; no diagnostic claim"
                        : "licensed speech; exploratory only")
                    : "original synthetic waveform",
                result: output.result, rawPulseCount: output.pulses.result.rawPulseCount,
                pulseEligibleAmplitudes: output.pulses.result.availableAmplitudeCount)
        }
    }
    return try #require(row)
}

@Test func shimmerPCMIntegrationExercisesSyntheticLicensedVowelsAndExploratorySpeech() throws {
    let directory = try #require(
        Bundle.module.url(forResource: "Pulses", withExtension: nil, subdirectory: "Fixtures"))
    let names = [
        "gaussian-16000-150", "jitter-1pct", "jitter-12pct", "rising-f0",
        "modulated", "inverted", "filtered", "harmonic", "noisy-low", "noisy-high",
        "speech-bl01-vowel-a", "speech-bl02-vowel-a", "speech-bl03-vowel-a",
        "speech-bl01-all-voiced", "speech-bl02-consonant-rich", "speech-bl01-noisy",
        "speech-bl01-low-level", "speech-bl01-dropout",
    ]
    var rows: [ShimmerPCMIntegrationRow] = []
    for name in names {
        for precision in [AnalysisPrecision.float32, .float64] {
            let fullName = name + "-" + precision.rawValue
            let fixture = try JSONDecoder().decode(
                ShimmerPCMFixture.self,
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
                ? shimmerPCMIntegration(
                    Float.self, fixture: fixture, samples: pcm.samples, exploratory: exploratory)
                : shimmerPCMIntegration(
                    Double.self, fixture: fixture, samples: pcm.samples, exploratory: exploratory)
            rows.append(row)
        }
    }
    #expect(rows.count == 36)
    if let path = ProcessInfo.processInfo.environment["HDXL_SHIMMER_CORPUS_REPORT"] {
        let destination = URL(filePath: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try canonicalContractJSON(rows).write(to: destination)
    }
}
