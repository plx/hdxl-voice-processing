import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

struct SWIPEPrimeReferenceRecord: Decodable {
    struct Source: Decodable {
        let path: String?
        let startSample: Int?
    }
    struct Input: Decodable {
        let localPath: String?
        let sampleRate, sampleCount: Int
        let normalizedFloat64LESHA256, encodedInputSHA256: String
    }
    struct Policy: Decodable {
        let magnitudeAbsolutePerWindowSample, magnitudeRelative: Double
        let loudnessAbsolute, loudnessRelative, kernelAbsolute, strengthAbsolute,
            frequencyHzAbsolute: Double
    }
    struct Kernel: Decodable {
        let candidateIndex: Int
        let coefficients: [Double]
    }
    struct Window: Decodable {
        struct Strength: Decodable {
            let candidateIndex: Int
            let strength: Double?
        }
        let length, offset: Int
        let magnitude, loudness: [Double]
        let strengths: [Strength]
    }
    struct Frame: Decodable {
        let frameIndex, startSample, observedSampleCount, requiredSampleCount: Int
        let windows: [Window]
        let candidateStrengths: [Double?]
        let selectedCandidateIndex: Int?
        let frequencyHz, pitchStrength, discretePitchStrength, normalizationPeak, rms: Double?
        let isRefined: Bool
        let status: SWIPEPrimeVoicingStatus
        let reason: UnavailabilityReason?
    }
    let name, profileSHA256: String
    let source: Source
    let input: Input
    let comparisonPolicy: Policy
    let profile: SWIPEPrimeConfiguration
    let kernelProbes: [Kernel]
    let frames: [Frame]

    func samples(directory: URL) throws -> [Double] {
        let samples: [Double]
        if let local = input.localPath {
            let data = try Data(contentsOf: directory.appending(path: local))
            #expect(VoiceCorpus.sha256(data) == input.encodedInputSHA256)
            try #require(data.count == 56 + input.sampleCount * 8)
            func word(_ offset: Int) -> UInt32 {
                data.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                }
            }
            func tag(_ offset: Int) -> String {
                String(decoding: data[offset..<offset + 4], as: UTF8.self)
            }
            try #require(tag(0) == "RIFF" && Int(word(4)) + 8 == data.count && tag(8) == "WAVE")
            try #require(tag(12) == "fmt " && word(16) == 16 && word(20) == 0x0001_0003)
            try #require(Int(word(24)) == input.sampleRate && word(28) == word(24) * 8)
            try #require(word(32) == 0x0040_0008 && tag(36) == "fact" && word(40) == 4)
            try #require(
                Int(word(44)) == input.sampleCount && tag(48) == "data"
                    && Int(word(52)) == input.sampleCount * 8)
            samples = stride(from: 56, to: data.count, by: 8).map { offset in
                data.withUnsafeBytes {
                    Double(
                        bitPattern: UInt64(
                            littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    )
                }
            }
        } else {
            let path = try #require(source.path)
            let prefix = "Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/"
            try #require(path.hasPrefix(prefix))
            let pcm = try CorpusPCM(data: VoiceCorpus.bytes(String(path.dropFirst(prefix.count))))
            let start = try #require(source.startSample)
            try #require(
                pcm.sampleRate == input.sampleRate && start >= 0
                    && start + input.sampleCount <= pcm.samples.count)
            samples = Array(pcm.samples[start..<start + input.sampleCount])
        }
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(VoiceCorpus.pcmHash(samples) == input.normalizedFloat64LESHA256)
        return samples
    }
}

struct SWIPEPrimeComparisonCounts {
    var magnitudeCells = 0, loudnessCells = 0, kernelCells = 0, strengthCells = 0
    var maximumMagnitudeFraction = 0.0, maximumLoudnessFraction = 0.0, maximumKernelFraction = 0.0
    var maximumStrengthFraction = 0.0, maximumFrequencyFraction = 0.0
}

private func swipePrimeCompareVector(
    _ actual: UnsafeBufferPointer<Double>, _ expected: [Double], absolute: Double,
    relative: Double = 0, label: String
) throws -> Double {
    try #require(actual.count == expected.count, "\(label) count")
    var maximum = 0.0
    for index in actual.indices {
        let value = actual[index]
        if !value.isFinite {
            maximum = .infinity
            break
        }
        let fraction = abs(value - expected[index]) / (absolute + relative * abs(expected[index]))
        maximum = max(maximum, fraction)
    }
    #expect(maximum <= 1, "\(label): maximum budget fraction \(maximum)")
    return maximum
}

private func swipePrimeCompareOptional(
    _ actual: Double?, _ expected: Double?, absolute: Double, relative: Double = 0, label: String
) -> Double {
    switch (actual, expected) {
    case (nil, nil): return 0
    case (.some(let value), .some(let reference)):
        let fraction =
            value.isFinite
            ? abs(value - reference) / (absolute + relative * abs(reference)) : .infinity
        #expect(
            fraction <= 1,
            "\(label): \(String(describing: actual)) versus \(String(describing: expected))")
        return fraction
    default:
        Issue.record("\(label): numerical zero and missing values must remain distinct")
        return .infinity
    }
}

func swipePrimeCompareFrame(
    _ output: BorrowedSWIPEPrimeOutput, expected: SWIPEPrimeReferenceRecord.Frame,
    fixture: SWIPEPrimeReferenceRecord, counts: inout SWIPEPrimeComparisonCounts
) throws {
    let actual = output.result
    let observation = actual.observation
    let policy = fixture.comparisonPolicy
    let label = "\(fixture.name) frame \(expected.frameIndex)"
    #expect(actual.profile.sha256 == fixture.profileSHA256)
    #expect(actual.frameIndex == UInt64(expected.frameIndex))
    #expect(actual.timing.source.startSample == Int64(expected.startSample))
    #expect(actual.timing.source.sampleCount == Int64(expected.observedSampleCount))
    #expect(actual.timing.includedSampleCount == Int64(expected.observedSampleCount))
    #expect(actual.requiredSampleCount == expected.requiredSampleCount)
    #expect(actual.timing.effectiveDelaySeconds == fixture.profile.algorithmicDelaySeconds)
    #expect(actual.status == expected.status, "\(label) voicing")
    #expect(actual.qualityReason == expected.reason, "\(label) reason")
    #expect(actual.selectedCandidateIndex == expected.selectedCandidateIndex, "\(label) selection")
    #expect((observation?.isRefined ?? false) == expected.isRefined, "\(label) refinement")
    counts.maximumFrequencyFraction = max(
        counts.maximumFrequencyFraction,
        swipePrimeCompareOptional(
            observation?.frequencyHz, expected.frequencyHz,
            absolute: policy.frequencyHzAbsolute, label: label + " frequency"))
    for (value, reference) in [
        (observation?.pitchStrength, expected.pitchStrength),
        (observation?.discretePitchStrength, expected.discretePitchStrength),
    ] {
        counts.maximumStrengthFraction = max(
            counts.maximumStrengthFraction,
            swipePrimeCompareOptional(
                value, reference, absolute: policy.strengthAbsolute,
                label: label + " selected strength"))
    }
    _ = swipePrimeCompareOptional(
        actual.normalizationPeak, expected.normalizationPeak,
        absolute: Double.leastNonzeroMagnitude, label: label + " input peak")
    _ = swipePrimeCompareOptional(
        actual.rms, expected.rms, absolute: Double.leastNonzeroMagnitude,
        relative: 2e-14, label: label + " RMS")
    let measurement = try actual.measurementResult()
    if case .available(let estimate) = measurement.outcome {
        #expect(estimate.confidence == nil)
        #expect(estimate.warnings == (actual.status == .uncertain ? [.lowConfidence] : []))
        #expect(actual.unavailability == nil)
    } else {
        #expect(actual.unavailability != nil)
    }
    try #require(output.candidateStrengths.count == expected.candidateStrengths.count)
    for index in expected.candidateStrengths.indices {
        counts.maximumStrengthFraction = max(
            counts.maximumStrengthFraction,
            swipePrimeCompareOptional(
                output.candidateStrengths[index], expected.candidateStrengths[index],
                absolute: policy.strengthAbsolute, label: label + " blended candidate \(index)"))
    }
    counts.strengthCells += expected.candidateStrengths.count
    try #require(output.windows.count == expected.windows.count)
    for (window, reference) in zip(output.windows, expected.windows) {
        #expect(window.length == reference.length && window.offset == reference.offset)
        counts.maximumMagnitudeFraction = max(
            counts.maximumMagnitudeFraction,
            try swipePrimeCompareVector(
                window.magnitude, reference.magnitude,
                absolute: policy.magnitudeAbsolutePerWindowSample * Double(window.length),
                relative: policy.magnitudeRelative, label: label + " magnitude N=\(window.length)"))
        counts.maximumLoudnessFraction = max(
            counts.maximumLoudnessFraction,
            try swipePrimeCompareVector(
                window.loudness, reference.loudness, absolute: policy.loudnessAbsolute,
                relative: policy.loudnessRelative, label: label + " loudness N=\(window.length)"))
        counts.magnitudeCells += reference.magnitude.count
        counts.loudnessCells += reference.loudness.count
        #expect(Array(window.candidateIndices) == reference.strengths.map(\.candidateIndex))
        try #require(window.candidateStrengths.count == expected.candidateStrengths.count)
        var current = 0
        for candidate in window.candidateStrengths.indices {
            let value = window.candidateStrengths[candidate]
            if current < reference.strengths.count,
                reference.strengths[current].candidateIndex == candidate
            {
                counts.maximumStrengthFraction = max(
                    counts.maximumStrengthFraction,
                    swipePrimeCompareOptional(
                        value, reference.strengths[current].strength,
                        absolute: policy.strengthAbsolute, label: label + " window strength"))
                current += 1
                counts.strengthCells += 1
            } else {
                #expect(value == nil)
            }
        }
    }
    if expected.observedSampleCount == expected.requiredSampleCount {
        for probe in fixture.kernelProbes {
            counts.maximumKernelFraction = max(
                counts.maximumKernelFraction,
                try swipePrimeCompareVector(
                    output.kernel(candidateIndex: probe.candidateIndex), probe.coefficients,
                    absolute: policy.kernelAbsolute,
                    label: label + " kernel \(probe.candidateIndex)"))
            counts.kernelCells += probe.coefficients.count
        }
    } else {
        #expect(output.candidateFrequenciesHz.isEmpty && output.erbFrequenciesHz.isEmpty)
        #expect(throws: ContractError.invalidValue) { try output.kernel(candidateIndex: 0) }
    }
}

private func swipePrimeCompareReference<Sample: BinaryFloatingPoint & Sendable>(
    _ fixture: SWIPEPrimeReferenceRecord, samples: [Sample]
) throws -> [String: Any] {
    let worker = try PreparedSWIPEPrime<Sample>(fixture.profile)
    let epoch = StreamEpoch(streamID: UUID())
    var counts = SWIPEPrimeComparisonCounts()
    var capturedError: (any Error)?
    try samples.withUnsafeBufferPointer { input in
        for frame in fixture.frames {
            let timing = try AnalysisTiming(
                source: SourceInterval(
                    epoch: epoch, startSample: Int64(frame.startSample),
                    sampleCount: Int64(frame.observedSampleCount),
                    sampleRate: Double(fixture.profile.sampleRate)),
                includedSampleCount: Int64(frame.observedSampleCount))
            try worker.analyze(
                UnsafeBufferPointer(
                    rebasing: input[
                        frame.startSample..<frame.startSample + frame.observedSampleCount]),
                timing: timing, frameIndex: UInt64(frame.frameIndex)
            ) { output in
                do {
                    try swipePrimeCompareFrame(
                        output, expected: frame, fixture: fixture, counts: &counts)
                } catch { capturedError = error }
            }
            if let capturedError { throw capturedError }
        }
    }
    #expect(
        worker.executionStatistics.analyzedFrameCount
            == fixture.frames.filter { $0.observedSampleCount == $0.requiredSampleCount }.count)
    // The same independently expected intermediates must survive both batch and
    // irregular chunk delivery, including exactly the retained partial tail.
    for chunks in [[max(1, samples.count)], [1, 17, 509, 2, 251, 64]] {
        try swipePrimeCompareStreamReference(fixture, samples: samples, chunks: chunks)
    }
    return [
        "name": fixture.name, "frameCount": fixture.frames.count,
        "profileSHA256": fixture.profileSHA256,
        "inputSHA256": fixture.input.normalizedFloat64LESHA256,
        "precision": fixture.profile.inputPrecision.rawValue,
        "magnitudeCells": counts.magnitudeCells, "loudnessCells": counts.loudnessCells,
        "kernelCells": counts.kernelCells, "strengthCells": counts.strengthCells,
        "maximumMagnitudeBudgetFraction": counts.maximumMagnitudeFraction,
        "maximumLoudnessBudgetFraction": counts.maximumLoudnessFraction,
        "maximumKernelBudgetFraction": counts.maximumKernelFraction,
        "maximumStrengthBudgetFraction": counts.maximumStrengthFraction,
        "maximumFrequencyBudgetFraction": counts.maximumFrequencyFraction,
        "preparedBufferBytes": worker.executionStatistics.preparedBufferBytes,
        "streamDeliveryVariants": 2,
        "streamFramesCompared": 2 * fixture.frames.count,
    ]
}

private func swipePrimeCompareStreamReference<Sample: BinaryFloatingPoint & Sendable>(
    _ fixture: SWIPEPrimeReferenceRecord, samples: [Sample], chunks: [Int]
) throws {
    let worker = try PreparedSWIPEPrimeAnalyzer<Sample>(
        configuration: fixture.profile, epoch: StreamEpoch(streamID: UUID()))
    var frameIndex = 0
    var offset = 0
    var chunkIndex = 0
    var counts = SWIPEPrimeComparisonCounts()
    var capturedError: (any Error)?
    func receive(_ output: BorrowedSWIPEPrimeOutput) {
        do {
            try #require(frameIndex < fixture.frames.count, "Unexpected stream frame")
            try swipePrimeCompareFrame(
                output, expected: fixture.frames[frameIndex], fixture: fixture, counts: &counts)
            frameIndex += 1
        } catch { capturedError = error }
    }
    try samples.withUnsafeBufferPointer { input in
        while offset < input.count {
            let count = min(chunks[chunkIndex % chunks.count], input.count - offset)
            let source = try SourceInterval(
                epoch: worker.epoch, startSample: Int64(offset), sampleCount: Int64(count),
                sampleRate: Double(fixture.profile.sampleRate))
            let report = try worker.process(
                UnsafeBufferPointer(rebasing: input[offset..<offset + count]), interval: source,
                emit: receive)
            #expect(report.consumedSampleCount == count && !report.isCancelled)
            if let capturedError { throw capturedError }
            offset += count
            chunkIndex += 1
        }
    }
    let end = try worker.finish(emit: receive)
    if let capturedError { throw capturedError }
    #expect(frameIndex == fixture.frames.count && !end.isCancelled)
    #expect(end.framing.observedSource.sampleCount == Int64(samples.count))
    #expect(
        end.framing.completeFrameCount
            == fixture.frames.filter { $0.observedSampleCount == $0.requiredSampleCount }.count)
    #expect(
        try worker.finish { _ in Issue.record("Repeated finish emitted reference frame") } == end)
}

@Test func swipePrimeAllIndependentNativeStageReferences() throws {
    let env = ProcessInfo.processInfo.environment
    let directory =
        try env["HDXL_SWIPE_REFERENCE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        ?? #require(
            Bundle.module.url(forResource: "SWIPE", withExtension: nil, subdirectory: "Fixtures"))
    struct Manifest: Decodable {
        let cases: [String]
        let files: [String: String]
    }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    #expect(manifest.cases.count == 74)
    var reports: [[String: Any]] = []
    for name in manifest.cases {
        let data = try Data(contentsOf: directory.appending(path: name + ".json"))
        #expect(VoiceCorpus.sha256(data) == manifest.files[name + ".json"])
        let fixture = try JSONDecoder().decode(SWIPEPrimeReferenceRecord.self, from: data)
        let input = try fixture.samples(directory: directory)
        if fixture.profile.inputPrecision == .float32 {
            reports.append(try swipePrimeCompareReference(fixture, samples: input.map(Float.init)))
        } else {
            reports.append(try swipePrimeCompareReference(fixture, samples: input))
        }
    }
    if let path = env["HDXL_SWIPE_REFERENCE_REPORT"] {
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: path))
    }
}
