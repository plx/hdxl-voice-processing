import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct YINReference: Decodable {
    struct Source: Decodable {
        let path: String?
        let startSample: Int?
    }
    struct Input: Decodable {
        let localPath: String?
        let sampleRate, sampleCount: Int
        let normalizedFloat64LESHA256, encodedInputSHA256: String
    }
    struct Candidate: Decodable {
        let integerLag: Int
        let periodSamples, unboundedPeriodSamples, frequencyHz, normalizedError, periodicity: Double
        let isLocalMinimum, isGlobalMinimum, isInRange, isThresholdQualified,
            isBoundaryCanonicalized: Bool
    }
    struct Frame: Decodable {
        let frameIndex, startSample, observedSampleCount, requiredSampleCount: Int
        let difference, cmnd: [Double]
        let candidates: [Candidate]
        let selectedCandidateIndex: Int?
        let status: YINVoicingStatus
        let reason: UnavailabilityReason?
        let normalizationPeak, rms: Double?
    }
    let name: String
    let source: Source
    let profile: YINConfiguration
    let input: Input
    let frames: [Frame]
}

private func yinInput(_ fixture: YINReference, directory: URL) throws -> [Double] {
    let samples: [Double]
    if let local = fixture.input.localPath {
        let data = try Data(contentsOf: directory.appending(path: local))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hash == fixture.input.encodedInputSHA256)
        try #require(data.count >= 56)
        func u16(_ i: Int) -> UInt16 {
            data.withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt16.self))
            }
        }
        func u32(_ i: Int) -> UInt32 {
            data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt32.self))
            }
        }
        func tag(_ i: Int) -> String { String(decoding: data[i..<i + 4], as: UTF8.self) }
        try #require(tag(0) == "RIFF" && tag(8) == "WAVE" && Int(u32(4)) == data.count - 8)
        try #require(tag(12) == "fmt " && u32(16) == 16 && u16(20) == 3 && u16(22) == 1)
        try #require(Int(u32(24)) == fixture.input.sampleRate && u32(28) == u32(24) * 8)
        try #require(u16(32) == 8 && u16(34) == 64 && tag(36) == "fact" && u32(40) == 4)
        try #require(Int(u32(44)) == fixture.input.sampleCount && tag(48) == "data")
        try #require(
            Int(u32(52)) == fixture.input.sampleCount * 8 && data.count == 56 + Int(u32(52)))
        samples = stride(from: 56, to: data.count, by: 8).map { offset in
            data.withUnsafeBytes {
                Double(
                    bitPattern: UInt64(
                        littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
            }
        }
    } else {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try #require(fixture.source.path)
        let start = try #require(fixture.source.startSample)
        let pcm = try CorpusPCM(data: Data(contentsOf: root.appending(path: source)))
        try #require(pcm.sampleRate == fixture.input.sampleRate)
        samples = Array(pcm.samples[start..<start + fixture.input.sampleCount])
    }
    let finite = samples.allSatisfy(\.isFinite)
    #expect(finite)
    var bytes = Data()
    for sample in samples {
        var bits = sample.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
    }
    #expect(
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            == fixture.input.normalizedFloat64LESHA256)
    return samples
}

private func yinCompare<Sample: BinaryFloatingPoint & Sendable>(
    _ fixture: YINReference, samples: [Sample], backend: YINDifferenceBackend
) throws -> [String: Any] {
    let original = fixture.profile
    let c = try YINConfiguration(
        sampleRate: original.sampleRate, inputPrecision: original.inputPrecision,
        pitchFloorHz: original.pitchFloorHz, pitchCeilingHz: original.pitchCeilingHz,
        integrationLength: original.integrationLength, hopLength: original.hopLength,
        threshold: original.threshold, silenceRMSThreshold: original.silenceRMSThreshold,
        differenceBackend: backend)
    let worker = try PreparedYIN<Sample>(c)
    let epoch = StreamEpoch(streamID: UUID())
    var maxDifference = 0.0
    var maxCMND = 0.0
    var maxPeriod = 0.0
    var maxHz = 0.0
    var cells = 0
    var candidateCount = 0
    for frame in fixture.frames {
        let source = try SourceInterval(
            epoch: epoch, startSample: Int64(frame.startSample),
            sampleCount: Int64(frame.observedSampleCount),
            sampleRate: Double(c.sampleRate))
        let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        try samples.withUnsafeBufferPointer { buffer in
            try worker.analyze(
                UnsafeBufferPointer(
                    rebasing: buffer[
                        frame.startSample..<frame.startSample + frame.observedSampleCount]),
                timing: timing, frameIndex: UInt64(frame.frameIndex)
            ) { output in
                let result = output.result
                #expect(
                    result.status == frame.status, "\(fixture.name)/\(backend)/\(frame.frameIndex)")
                #expect(result.unavailability == frame.reason)
                #expect(result.selectedCandidateIndex == frame.selectedCandidateIndex)
                #expect(result.timing.source == source)
                #expect(result.timing.effectiveDelaySeconds == c.algorithmicDelaySeconds)
                #expect(result.requiredSampleCount == frame.requiredSampleCount)
                #expect(result.normalizationPeak == frame.normalizationPeak)
                if let actual = result.rms, let expected = frame.rms {
                    #expect(abs(actual - expected) <= max(1e-300, abs(expected) * 1e-14))
                } else {
                    #expect(result.rms == frame.rms)
                }
                let d = output.values(.scaledSquaredDifference)
                let cmnd = output.values(.cumulativeMeanNormalizedDifference)
                #expect(d.count == frame.difference.count && cmnd.count == frame.cmnd.count)
                for (actual, expected) in zip(d, frame.difference) {
                    maxDifference = max(
                        maxDifference,
                        abs(actual - expected)
                            / (2e-10 * Double(c.integrationLength) + 1e-12 * abs(expected)))
                    cells += 1
                }
                for (actual, expected) in zip(cmnd, frame.cmnd) {
                    maxCMND = max(maxCMND, abs(actual - expected) / 1e-9)
                }
                #expect(output.candidates.count == frame.candidates.count)
                for (actual, expected) in zip(output.candidates, frame.candidates) {
                    #expect(
                        actual.integerLag == expected.integerLag,
                        "\(fixture.name)/\(backend)/\(frame.frameIndex)")
                    #expect(actual.isLocalMinimum == expected.isLocalMinimum)
                    #expect(actual.isGlobalMinimum == expected.isGlobalMinimum)
                    #expect(actual.isInRange == expected.isInRange)
                    #expect(actual.isThresholdQualified == expected.isThresholdQualified)
                    #expect(actual.isBoundaryCanonicalized == expected.isBoundaryCanonicalized)
                    maxPeriod = max(
                        maxPeriod, abs(actual.periodSamples - expected.periodSamples) / 2e-6,
                        abs(actual.unboundedPeriodSamples - expected.unboundedPeriodSamples) / 2e-6)
                    maxHz = max(maxHz, abs(actual.frequencyHz - expected.frequencyHz) / 0.001)
                    maxCMND = max(
                        maxCMND, abs(actual.normalizedError - expected.normalizedError) / 1e-9,
                        abs(actual.periodicity - expected.periodicity) / 1e-9)
                    candidateCount += 1
                }
            }
        }
    }
    #expect(maxDifference <= 1, "\(fixture.name)/\(backend): difference \(maxDifference)")
    #expect(maxCMND <= 1, "\(fixture.name)/\(backend): CMND \(maxCMND)")
    #expect(maxPeriod <= 1, "\(fixture.name)/\(backend): period \(maxPeriod)")
    #expect(maxHz <= 1, "\(fixture.name)/\(backend): Hz \(maxHz)")
    return [
        "name": fixture.name, "backend": backend.rawValue, "frameCount": fixture.frames.count,
        "inputPrecision": c.inputPrecision.rawValue, "nativeProfileSHA256": worker.identity.sha256,
        "inputSHA256": fixture.input.normalizedFloat64LESHA256, "comparedDifferenceSamples": cells,
        "comparedCandidates": candidateCount, "maximumDifferenceBudgetFraction": maxDifference,
        "maximumCMNDBudgetFraction": maxCMND, "maximumPeriodBudgetFraction": maxPeriod,
        "maximumFrequencyBudgetFraction": maxHz,
        "directlyRecomputedLags": worker.executionStatistics.directlyRecomputedLagCount,
        "scalarFallbackFrames": worker.executionStatistics.scalarFallbackFrameCount,
    ]
}

@Test func yinIndependentScalarAndFFTReferences() throws {
    let env = ProcessInfo.processInfo.environment
    let directory =
        try env["HDXL_YIN_REFERENCE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        ?? #require(
            Bundle.module.url(forResource: "YIN", withExtension: nil, subdirectory: "Fixtures"))
    struct Manifest: Decodable { let cases: [String] }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    #expect(manifest.cases.count == 54)
    var reports: [[String: Any]] = []
    for name in manifest.cases {
        let fixture = try JSONDecoder().decode(
            YINReference.self, from: Data(contentsOf: directory.appending(path: name + ".json")))
        let input = try yinInput(fixture, directory: directory)
        for backend in YINDifferenceBackend.allCases {
            if fixture.profile.inputPrecision == .float32 {
                reports.append(
                    try yinCompare(fixture, samples: input.map(Float.init), backend: backend))
            } else {
                reports.append(try yinCompare(fixture, samples: input, backend: backend))
            }
        }
    }
    #expect(reports.count == 108)
    if let path = env["HDXL_YIN_REFERENCE_REPORT"] {
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: path))
    }
}
