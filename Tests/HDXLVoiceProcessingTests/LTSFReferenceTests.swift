import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct LTSFReferenceFixture: Decodable {
    struct Profile: Decodable {
        let inputPrecision: AnalysisPrecision
        let hopSeconds: Double
        let shortWindowSeconds: Double
        let longWindowSeconds: Double
        let minimumFrequencyHz: Double
        let maximumFrequencyHz: Double
        let flatnessThreshold: Double
        let relativeIntensityThresholdDB: Double?
        let minimumSpeechSeconds: Double
        let minimumNonSpeechSeconds: Double
    }
    struct Source: Decodable { let path: String? }
    struct Input: Decodable {
        let sampleRate: Int
        let sampleCount: Int
        let localPath: String?
        let normalizedFloat64LESHA256: String
        let encodedReferenceInputSHA256: String
    }
    struct Axes: Decodable {
        let frameCount: Int
        let firstCenter: Double
        let frequencyBinCount: Int
        let firstFrequency: Double
        let frequencyStep: Double
        let hop: Double
    }
    struct Spectrum: Decodable {
        let frameIndex: Int
        let powers: [Double]
    }
    struct Interval: Decodable {
        let startSeconds: Double
        let endSeconds: Double
        let isSpeech: Bool
    }
    struct Tier: Decodable {
        let name: String
        let intervals: [Interval]
    }
    struct Budget: Decodable {
        let absolute: Double
        let relative: Double
    }
    struct Policy: Decodable {
        let spectrogramPower: Budget
        let temporalFlatness: Budget
        let referenceIntensityDB: Budget
        let intervalBoundarySeconds: Budget
    }
    let schemaVersion: Int
    let name: String
    let source: Source
    let input: Input
    let profile: Profile
    let axes: Axes
    let spectra: [Spectrum]
    let flatness: [Double]
    let referenceIntensityDB: [Double]
    let tiers: [Tier]
    let comparisonPolicy: Policy
}

/// Test-only reader for the exact finite mono Float64 RIFF emitted by Tools/Masks.
/// Existing corpus inputs continue through their separately constrained decoder.
private func maskReferenceDoubles(_ data: Data, rate: Int, count: Int) throws -> [Double] {
    try #require(count > 0 && count <= 1_200_000 && data.count == 56 + count * 8)
    func tag(_ offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }
    func u16(_ offset: Int) -> UInt16 {
        data.withUnsafeBytes {
            UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }
    func u32(_ offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
    try #require(tag(0) == "RIFF" && Int(u32(4)) + 8 == data.count && tag(8) == "WAVE")
    try #require(tag(12) == "fmt " && u32(16) == 16 && u16(20) == 3 && u16(22) == 1)
    try #require(Int(u32(24)) == rate && Int(u32(28)) == rate * 8 && u16(32) == 8 && u16(34) == 64)
    try #require(tag(36) == "fact" && u32(40) == 4 && Int(u32(44)) == count)
    try #require(tag(48) == "data" && Int(u32(52)) == count * 8)
    let samples: [Double] = data.withUnsafeBytes { bytes in
        (0..<count).map {
            Double(
                bitPattern: UInt64(
                    littleEndian: bytes.loadUnaligned(fromByteOffset: 56 + $0 * 8, as: UInt64.self))
            )
        }
    }
    try #require(samples.allSatisfy { $0.isFinite })
    return samples
}

private func checkLTSFReference<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, fixture f: LTSFReferenceFixture, samples: [Double]
) throws -> [String: Any] {
    let p = f.profile
    let config = try LTSFConfiguration(
        sampleRate: f.input.sampleRate, inputPrecision: p.inputPrecision,
        declaredInputBandwidthHz: Double(f.input.sampleRate) / 2, hopSeconds: p.hopSeconds,
        shortWindowSeconds: p.shortWindowSeconds, longWindowSeconds: p.longWindowSeconds,
        minimumFrequencyHz: p.minimumFrequencyHz, maximumFrequencyHz: p.maximumFrequencyHz,
        flatnessThreshold: p.flatnessThreshold,
        relativeIntensityThresholdDB: p.relativeIntensityThresholdDB,
        minimumSpeechSeconds: p.minimumSpeechSeconds,
        minimumNonSpeechSeconds: p.minimumNonSpeechSeconds)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 127,
        sampleCount: Int64(samples.count), sampleRate: Double(f.input.sampleRate))
    let worker = try PreparedLTSFDetector<S>(configuration: config, source: source)
    #expect(worker.layout.frameCount == f.axes.frameCount, "\(f.name): frame count")
    #expect(worker.layout.spectral.frequencyBinCount == f.axes.frequencyBinCount)
    #expect(worker.layout.spectral.frequencyStepHz == f.axes.frequencyStep)
    #expect(worker.layout.spectral.firstFrequencyHz == f.axes.firstFrequency)
    #expect(worker.layout.configuration.hopSeconds == f.axes.hop)
    #expect(try #require(worker.layout.firstCenterSeconds) == f.axes.firstCenter)
    let spectra = Dictionary(uniqueKeysWithValues: f.spectra.map { ($0.frameIndex, $0.powers) })
    var powerFraction = 0.0
    var comparedPowers = 0
    var observedSpectra = 0
    func fraction(_ actual: Double, _ expected: Double, _ budget: LTSFReferenceFixture.Budget)
        -> Double
    {
        abs(actual - expected) / (budget.absolute + budget.relative * abs(expected))
    }
    let pcm = samples.map(S.init)
    try pcm.withUnsafeBufferPointer { input in
        for start in stride(from: 0, to: input.count, by: 137) {
            let end = min(input.count, start + 137)
            let part = try SourceInterval(
                epoch: source.epoch, startSample: source.startSample + Int64(start),
                sampleCount: Int64(end - start), sampleRate: source.sampleRate)
            try worker.append(UnsafeBufferPointer(rebasing: input[start..<end]), interval: part) {
                output in
                if let expected = spectra[output.frameIndex] {
                    observedSpectra += 1
                    #expect(output.powers.count == expected.count)
                    for (actual, value) in zip(output.powers, expected) {
                        powerFraction = max(
                            powerFraction,
                            fraction(actual, value, f.comparisonPolicy.spectrogramPower))
                        comparedPowers += 1
                    }
                }
            }
        }
    }
    var flatnessFraction = 0.0
    var intensityFraction = 0.0
    var boundaryFraction = 0.0
    var selectedSamples: Int64 = 0
    var exportFailure: (any Error)?
    func compareIntervals(_ actual: UnsafeBufferPointer<SpeechActivityInterval>, tier: String) {
        let expected = f.tiers.first { $0.name == tier }?.intervals ?? []
        #expect(actual.count == expected.count, "\(f.name): \(tier) interval count")
        for (a, e) in zip(actual, expected) {
            #expect(a.isSpeech == e.isSpeech, "\(f.name): \(tier) label")
            boundaryFraction = max(
                boundaryFraction,
                fraction(a.startSeconds, e.startSeconds, f.comparisonPolicy.intervalBoundarySeconds)
            )
            boundaryFraction = max(
                boundaryFraction,
                fraction(a.endSeconds, e.endSeconds, f.comparisonPolicy.intervalBoundarySeconds))
        }
    }
    let completion = try worker.finish { output in
        #expect(output.unavailability == nil)
        #expect(output.flatness.count == f.flatness.count)
        #expect(output.referenceIntensityDB.count == f.referenceIntensityDB.count)
        for (actual, expected) in zip(output.flatness, f.flatness) {
            flatnessFraction = max(
                flatnessFraction, fraction(actual, expected, f.comparisonPolicy.temporalFlatness))
        }
        for (actual, expected) in zip(output.referenceIntensityDB, f.referenceIntensityDB) {
            intensityFraction = max(
                intensityFraction,
                fraction(actual, expected, f.comparisonPolicy.referenceIntensityDB))
        }
        compareIntervals(output.spectralIntervals, tier: "VAD")
        compareIntervals(output.intensityIntervals, tier: "silences")
        compareIntervals(
            output.speechIntervals, tier: p.relativeIntensityThresholdDB == nil ? "VAD" : "union")
        do {
            let timeline = try MaskTimeline(output.exportMaskPlan())
            selectedSamples = timeline.coverage.selectedSampleCount
            let expectedTier = f.tiers.first {
                $0.name == (p.relativeIntensityThresholdDB == nil ? "VAD" : "union")
            }!
            let expectedCount = expectedTier.intervals.filter(\.isSpeech).reduce(Int64(0)) {
                count, interval in
                let start = Int64(
                    (interval.startSeconds * source.sampleRate).rounded(.toNearestOrAwayFromZero))
                let end = Int64(
                    (interval.endSeconds * source.sampleRate).rounded(.toNearestOrAwayFromZero))
                return count + end - start
            }
            #expect(selectedSamples == expectedCount, "\(f.name): quantized selected coverage")
            #expect(timeline.coverage.eligibleSampleCount == source.sampleCount)
            #expect(timeline.plan.effectiveDelaySeconds == source.durationSeconds)
        } catch { exportFailure = error }
    }
    if let exportFailure { throw exportFailure }
    #expect(completion.frameCount == f.axes.frameCount)
    #expect(observedSpectra == f.spectra.count)
    #expect(powerFraction <= 1, "\(f.name): power uses \(powerFraction) budgets")
    #expect(flatnessFraction <= 1, "\(f.name): flatness uses \(flatnessFraction) budgets")
    #expect(intensityFraction <= 1, "\(f.name): intensity uses \(intensityFraction) budgets")
    #expect(boundaryFraction <= 1, "\(f.name): boundaries use \(boundaryFraction) budgets")
    return [
        "case": f.name, "inputPrecision": p.inputPrecision.rawValue,
        "frameCount": f.axes.frameCount,
        "comparedSpectra": observedSpectra, "comparedPowers": comparedPowers,
        "selectedSamples": selectedSamples,
        "sourceSamples": source.sampleCount, "profileSHA256": try config.identity().sha256,
        "maximumBudgetFractions": [
            "power": powerFraction, "flatness": flatnessFraction,
            "intensity": intensityFraction, "boundaries": boundaryFraction,
        ],
    ]
}

@Test func ltsfReferenceCatalogMatchesPinnedSpectraFlatnessAndIntervals() throws {
    struct Manifest: Decodable {
        struct Entry: Decodable {
            let name: String
            let file: String
            let sha256: String
        }
        let schemaVersion: Int
        let cases: [Entry]
    }
    let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let root =
        ProcessInfo.processInfo.environment["HDXL_MASK_REFERENCE_DIRECTORY"].map {
            URL(fileURLWithPath: $0)
        }
        ?? fixtures.appendingPathComponent("Masks")
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    #expect(manifest.schemaVersion == 1)
    #expect(!manifest.cases.isEmpty)
    var rows: [[String: Any]] = []
    for entry in manifest.cases {
        try #require(!entry.file.contains("/") && !entry.file.contains(".."))
        let bytes = try Data(contentsOf: root.appendingPathComponent(entry.file))
        #expect(VoiceCorpus.sha256(bytes) == entry.sha256)
        let f = try JSONDecoder().decode(LTSFReferenceFixture.self, from: bytes)
        #expect(f.schemaVersion == 1)
        #expect(f.name == entry.name)
        let samples: [Double]
        if let path = f.input.localPath {
            try #require(path.hasPrefix("inputs/") && !path.contains(".."))
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            #expect(VoiceCorpus.sha256(data) == f.input.encodedReferenceInputSHA256)
            samples = try maskReferenceDoubles(
                data, rate: f.input.sampleRate, count: f.input.sampleCount)
        } else {
            let path = try #require(f.source.path)
            let prefix = "Tests/HDXLVoiceProcessingTests/Fixtures/"
            try #require(path.hasPrefix(prefix) && !path.contains(".."))
            let input = fixtures.appendingPathComponent(String(path.dropFirst(prefix.count)))
            let data = try Data(contentsOf: input)
            if path.hasPrefix(prefix + "Synthetic/") {
                samples = try maskReferenceDoubles(
                    data, rate: f.input.sampleRate, count: f.input.sampleCount)
            } else {
                let pcm = try CorpusPCM(data: data)
                #expect(pcm.sampleRate == f.input.sampleRate)
                samples = pcm.samples
            }
        }
        #expect(samples.count == f.input.sampleCount)
        #expect(VoiceCorpus.pcmHash(samples) == f.input.normalizedFloat64LESHA256)
        if f.profile.inputPrecision == .float32 {
            rows.append(try checkLTSFReference(Float.self, fixture: f, samples: samples))
        } else {
            rows.append(try checkLTSFReference(Double.self, fixture: f, samples: samples))
        }
    }
    if let path = ProcessInfo.processInfo.environment["HDXL_MASK_REFERENCE_REPORT"] {
        let data = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 1, "comparisons": rows],
            options: [.sortedKeys, .prettyPrinted])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
