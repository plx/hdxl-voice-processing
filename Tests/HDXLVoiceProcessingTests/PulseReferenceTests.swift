import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct PulseReferenceCase: Decodable {
    let name: String
    let sampleRate, sampleCount: Int
    let inputPrecision: AnalysisPrecision
}

private struct PulseReferenceRecord: Decodable {
    struct Reference: Decodable {
        struct Pitch: Decodable {
            let firstCenterSeconds, stepSeconds, ceilingHz: Double
            let frequenciesHz: [Double]
        }
        struct Values: Decodable {
            struct Amplitude: Decodable {
                let pulseIndex: Int
                let rmsAmplitude: Double
            }
            let pulseTimesSeconds: [Double]
            let amplitudes: [Amplitude]
        }
        let inputSHA256: String
        let pitch: Pitch
        let data: Values
    }
    let `case`: PulseReferenceCase
    let reference: Reference

    func contour() throws -> PulseF0Contour {
        let pitch = reference.pitch
        return try PulseF0Contour(
            sampleRate: self.case.sampleRate, sampleCount: self.case.sampleCount,
            firstCenterSeconds: pitch.firstCenterSeconds, stepSeconds: pitch.stepSeconds,
            ceilingHz: pitch.ceilingHz, frequenciesHz: pitch.frequenciesHz)
    }

    func samples(in directory: URL) throws -> [Double] {
        let data = try Data(contentsOf: directory.appending(path: self.case.name + ".wav"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(hash == reference.inputSHA256)
        let pcm = try CorpusPCM(data: data)
        try #require(
            pcm.sampleRate == self.case.sampleRate && pcm.samples.count == self.case.sampleCount)
        return pcm.samples
    }
}

private func pulseReferenceDirectory(_ name: String) throws -> URL {
    let keys = [
        "Pulses": "HDXL_PULSE_REFERENCE_DIRECTORY",
        "PulseF0Stages": "HDXL_PULSE_F0_STAGE_DIRECTORY",
        "PulseMatchingStages": "HDXL_PULSE_MATCHING_STAGE_DIRECTORY",
    ]
    if let key = keys[name], let path = ProcessInfo.processInfo.environment[key] {
        try #require(!path.isEmpty, "Explicit pulse reference paths cannot be empty")
        return URL(filePath: path, directoryHint: .isDirectory)
    }
    return try #require(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

private struct PulseNativeAuditRow: Encodable {
    let name: String
    let inputSHA256: String
    let f0ContourIdentity: ProfileIdentity
    let nativeTimes, referenceTimes: [Double]
    let maximumPositionErrorSamples: Double
    let maximumAmplitudeBudgetFraction: Double
    let amplitudeComparisons, eligiblePeriods, eligiblePairs, rejectedAttempts: Int
    let exactConstantProof: Bool
    let profile: ProfileIdentity
}

private func pulseReferenceComparison<Sample: BinaryFloatingPoint & Sendable>(
    _ record: PulseReferenceRecord, samples: [Sample]
) throws -> PulseNativeAuditRow {
    let item = record.case
    let contour = try record.contour()
    let configuration = try PulseConfiguration(
        sampleRate: item.sampleRate, inputPrecision: item.inputPrecision,
        pitchCeilingHz: contour.ceilingHz)
    let worker = try PreparedPulseTracker<Sample>(
        configuration: configuration, maximumSampleCount: samples.count,
        maximumF0FrameCount: contour.frequenciesHz.count, maximumTrackingAttempts: 4096)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: Int64.max - Int64(samples.count),
        sampleCount: Int64(samples.count), sampleRate: Double(item.sampleRate))
    let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
    var result: PulseSnapshot?
    try samples.withUnsafeBufferPointer { input in
        try worker.analyze(input, contour: contour, timing: timing) {
            result = try $0.snapshot(maximumRecordCount: 30000)
        }
    }
    let output = try #require(result)
    let actual = output.landmarks.map(\.timeSeconds)
    let expected = record.reference.data.pulseTimesSeconds
    let constant = samples[0] != 0 && samples.allSatisfy { $0 == samples[0] }
    let error = zip(actual, expected).map { abs($0 - $1) * Double(item.sampleRate) }.max() ?? 0
    var amplitudeFraction = 0.0
    var amplitudeCount = 0
    if constant {
        #expect(!output.landmarks.isEmpty)
        #expect(
            output.result.eligiblePeriodCount == 0 && output.result.availableAmplitudeCount == 0)
        #expect(
            output.landmarks.allSatisfy { $0.rejections.contains(.degenerateWaveform) },
            "\(item.name)")
    } else {
        #expect(
            actual.count == expected.count,
            "\(item.name): native \(actual.count), reference \(expected.count)")
        #expect(error <= 1e-6, "\(item.name): position error \(error) samples")
        let amplitudes = Dictionary(
            uniqueKeysWithValues: record.reference.data.amplitudes.map {
                ($0.pulseIndex, $0.rmsAmplitude)
            })
        for amplitude in output.amplitudes where amplitude.isEligible {
            let reference = try #require(
                amplitudes[amplitude.pulseIndex], "\(item.name): native invented an amplitude")
            let value = try #require(amplitude.rmsAmplitude)
            let fraction = abs(value - reference) / (2e-12 + 1e-10 * abs(reference))
            amplitudeFraction = max(amplitudeFraction, fraction)
            amplitudeCount += 1
            #expect(
                fraction <= 1,
                "\(item.name): amplitude \(amplitude.pulseIndex), budget fraction \(fraction)")
        }
    }
    return PulseNativeAuditRow(
        name: item.name, inputSHA256: record.reference.inputSHA256,
        f0ContourIdentity: output.result.f0ContourIdentity, nativeTimes: actual,
        referenceTimes: expected,
        maximumPositionErrorSamples: error, maximumAmplitudeBudgetFraction: amplitudeFraction,
        amplitudeComparisons: amplitudeCount, eligiblePeriods: output.result.eligiblePeriodCount,
        eligiblePairs: output.result.eligiblePairCount,
        rejectedAttempts: output.attempts.filter { !$0.acceptedByReferenceGates }.count,
        exactConstantProof: constant, profile: output.result.profile)
}

@Test func pulseReferenceCatalogComparesEveryRawLandmarkAndAvailableAmplitude() throws {
    let directory = try pulseReferenceDirectory("Pulses")
    struct Manifest: Decodable { let catalog: [PulseReferenceCase] }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    try #require(manifest.catalog.count == 110)
    var rows: [PulseNativeAuditRow] = []
    for item in manifest.catalog {
        let record = try JSONDecoder().decode(
            PulseReferenceRecord.self,
            from: Data(contentsOf: directory.appending(path: item.name + ".json")))
        let samples = try record.samples(in: directory)
        do {
            switch item.inputPrecision {
            case .float32:
                rows.append(try pulseReferenceComparison(record, samples: samples.map(Float.init)))
            case .float64: rows.append(try pulseReferenceComparison(record, samples: samples))
            }
        } catch { Issue.record(error, "\(item.name)") }
    }
    #expect(rows.count == 110 && rows.filter(\.exactConstantProof).count == 2)
    if let path = ProcessInfo.processInfo.environment["HDXL_PULSE_REFERENCE_REPORT"] {
        try canonicalContractJSON(rows).write(to: URL(filePath: path), options: .atomic)
    }
}

@Test func pulseReferenceF0QueriesMatchAllExternalRepresentableBoundaries() throws {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let sampleRate, sampleCount: Int
            let pitch: PulseReferenceRecord.Reference.Pitch
        }
        struct Row: Decodable {
            let time: Double
            let external: Double?
        }
        let `case`: Case
        let oracle: [Row]
    }
    let directory = try pulseReferenceDirectory("PulseF0Stages")
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    .filter {
        $0.pathExtension == "json"
            && !["summary", "execution"].contains($0.deletingPathExtension().lastPathComponent)
    }
    var count = 0
    for file in files {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        let c = fixture.case
        let contour = try PulseF0Contour(
            sampleRate: c.sampleRate, sampleCount: c.sampleCount,
            firstCenterSeconds: c.pitch.firstCenterSeconds, stepSeconds: c.pitch.stepSeconds,
            ceilingHz: c.pitch.ceilingHz, frequenciesHz: c.pitch.frequenciesHz)
        for row in fixture.oracle {
            let observed = try contour.observation(atRelativeSeconds: row.time).frequencyHz
            #expect(
                (observed == nil) == (row.external == nil), "\(file.lastPathComponent): \(row.time)"
            )
            if let observed, let expected = row.external {
                #expect(abs(observed - expected) <= 1e-10)
            }
            count += 1
        }
    }
    #expect(files.count == 10 && count == 255)
}

@Test func pulseReferenceMatchingStagesConformToIndependentCompleteLagTables() throws {
    struct Fixture: Decodable {
        struct Bin: Decodable {
            let candidateFirstIndex, observedPairCount: Int
            let correlation: Double
        }
        let caseName: String
        let sampleRate: Int
        let inputPrecision: AnalysisPrecision
        let inputSamples: [Double]
        let anchorFirstIndex, anchorLastIndex: Int
        let anchorSeconds, referenceTimeSeconds: Double
        let curve: [Bin]
    }
    let directory = try pulseReferenceDirectory("PulseMatchingStages")
    let references = try pulseReferenceDirectory("Pulses")
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    .filter {
        $0.pathExtension == "json"
            && !["summary", "execution"].contains($0.deletingPathExtension().lastPathComponent)
    }
    var bins = 0
    for file in files {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        let record = try JSONDecoder().decode(
            PulseReferenceRecord.self,
            from: Data(contentsOf: references.appending(path: fixture.caseName + ".json")))
        let samples = try record.samples(in: references)
        let config = try PulseConfiguration(
            sampleRate: fixture.sampleRate, inputPrecision: fixture.inputPrecision,
            pitchCeilingHz: record.reference.pitch.ceilingHz)
        fixture.inputSamples.withUnsafeBufferPointer { input in
            for expected in fixture.curve {
                let observed = PulseSearchKernel.correlation(
                    input, anchorFirst: fixture.anchorFirstIndex,
                    anchorLast: fixture.anchorLastIndex,
                    candidateFirst: expected.candidateFirstIndex,
                    minimumRelativeVariation: config.minimumRelativeVariation)
                #expect(observed.pairCount == expected.observedPairCount)
                #expect(abs(observed.coefficient - expected.correlation) <= 2e-12)
                bins += 1
            }
        }
        let frequency = try #require(
            record.contour().observation(atRelativeSeconds: fixture.anchorSeconds).frequencyHz)
        let kernel = PulseSearchKernel(config)
        let match = try samples.withUnsafeBufferPointer {
            try kernel.match(
                $0, anchor: fixture.anchorSeconds, frequency: frequency,
                direction: fixture.referenceTimeSeconds < fixture.anchorSeconds
                    ? .backward : .forward)
        }
        let error =
            abs(match.timeSeconds - fixture.referenceTimeSeconds) * Double(fixture.sampleRate)
        #expect(error <= 2e-10, "\(file.lastPathComponent): \(error) samples")
        #expect(!match.usedRangeFallback)
    }
    #expect(files.count == 96 && bins > 1000)
}
