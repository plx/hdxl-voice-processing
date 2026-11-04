import CryptoKit
import Foundation
import HDXLVoiceProcessing
import Testing

private struct SyntheticFixture: Decodable {
    struct Artifact: Decodable {
        let file: String
        let sha256: String
        let byteCount: Int
        let normalizedFloat64LESHA256: String
    }
    struct Span: Decodable {
        let startSample: Int64
        let sampleCount: Int64
        let included: Bool
        let reason: String?
    }
    struct Expectation: Decodable {
        let measurement: MeasurementDescriptor?
        let outcome: MeasurementOutcome?
        let absoluteTolerance: Double?
    }
    let schemaVersion: Int
    let identifier: VersionedIdentifier
    let recipeIdentity: ProfileIdentity
    let format: PCMFormat
    let timing: AnalysisTiming
    let durationSeconds: Double
    let artifact: Artifact
    let selection: [Span]
    let expectations: [Expectation]
    let fixtureIdentity: String
}

private struct SyntheticCatalog: Decodable {
    struct Entry: Decodable {
        let id: String
        let manifest: String
        let fixtureIdentity: String
    }
    struct Coverage: Decodable {
        let planningID: String
        let analyticOrInvariant: [String]
        let difficultOrUndefined: [String]
    }
    let catalogIdentity: String
    let cases: [Entry]
    let coverage: [Coverage]
}

private func syntheticBytes(_ file: String) throws -> Data {
    let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: root.appending(path: "Synthetic/" + file))
}

private func syntheticHash(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private enum SyntheticFixtureError: Error { case mismatch }

private func syntheticValidate(_ json: Data, _ wave: Data) throws -> SyntheticFixture {
    let fixture = try JSONDecoder().decode(SyntheticFixture.self, from: json)
    guard fixture.schemaVersion == 1, fixture.identifier == fixture.recipeIdentity.identifier,
        fixture.format.encoding == .float64, fixture.format.channelCount == 1,
        fixture.format.sampleRate == fixture.timing.source.sampleRate,
        fixture.durationSeconds == fixture.timing.source.durationSeconds,
        wave.count == fixture.artifact.byteCount,
        wave.count == 56 + fixture.timing.source.sampleCount * 8,
        syntheticHash(wave) == fixture.artifact.sha256,
        syntheticHash(Data(wave.dropFirst(56))) == fixture.artifact.normalizedFloat64LESHA256
    else { throw SyntheticFixtureError.mismatch }
    var cursor: Int64 = 0
    var included: Int64 = 0
    for span in fixture.selection {
        guard span.startSample == cursor, span.sampleCount > 0,
            span.included ? span.reason == nil : span.reason == "deliberatelyMissing"
        else { throw SyntheticFixtureError.mismatch }
        cursor += span.sampleCount
        if span.included { included += span.sampleCount }
    }
    guard cursor == fixture.timing.source.sampleCount,
        included == fixture.timing.includedSampleCount
    else { throw SyntheticFixtureError.mismatch }
    return fixture
}

private func syntheticSamples(_ name: String) throws -> [Double] {
    let data = try syntheticBytes(name + ".wav")
    _ = try syntheticValidate(syntheticBytes(name + ".json"), data)
    return stride(from: 56, to: data.count, by: 8).map { offset in
        let bits = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        return Double(bitPattern: UInt64(littleEndian: bits))
    }
}

@Test func syntheticCatalogHasIndependentCoverageAndTypedContracts() throws {
    let catalog = try JSONDecoder().decode(
        SyntheticCatalog.self, from: syntheticBytes("catalog.json"))
    #expect(catalog.cases.count == 34)
    #expect(
        Set(catalog.coverage.map(\.planningID)) == Set((1...18).map { String(format: "A%02d", $0) })
    )
    #expect(
        catalog.coverage.allSatisfy {
            !$0.analyticOrInvariant.isEmpty && !$0.difficultOrUndefined.isEmpty
        })
    for entry in catalog.cases {
        let data = try syntheticBytes(entry.id + ".wav")
        let fixture = try syntheticValidate(syntheticBytes(entry.manifest), data)
        #expect(fixture.fixtureIdentity == entry.fixtureIdentity)
        #expect(fixture.identifier.name == entry.id)
        #expect(fixture.timing.sourceStartSeconds == 0)
        #expect(fixture.timing.hostStartNanoseconds == nil)
        #expect(fixture.timing.completedHostNanoseconds == nil)
        // Test the actual byte encoding, independently of the Python serializer.
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(Array(data[20..<24]) == [3, 0, 1, 0])  // IEEE float, mono
        #expect(Array(data[32..<36]) == [8, 0, 64, 0])  // block align, bits
        let rate = data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self))
        }
        #expect(Double(rate) == fixture.format.sampleRate)
        let samples = try syntheticSamples(entry.id)
        #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        for expected in fixture.expectations {
            guard let measurement = expected.measurement, let estimate = expected.outcome?.estimate
            else { continue }
            let value: Double
            switch measurement.kind {
            case .rms: value = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
            case .peakAmplitude: value = samples.map(abs).max() ?? 0
            default: continue
            }
            #expect(abs(value - estimate.value) <= (expected.absoluteTolerance ?? 0))
        }
    }
}

@Test func syntheticGainPolarityRateAndTimeIdentities() throws {
    let base = try syntheticSamples("bin-tone")
    let negative = try syntheticSamples("tone-inverted")
    let half = try syntheticSamples("tone-half-gain")
    let faster = try syntheticSamples("tone-double-rate")
    let slower = try syntheticSamples("tone-time-dilated")
    for i in base.indices {
        #expect(negative[i] == -base[i])
        #expect(half[i] == base[i] * 0.5)
        #expect(faster[2 * i] == base[i])
        #expect(slower[2 * i] == base[i])
    }
    #expect(try syntheticSamples("quarter-tone") == [0, 0.5, 0, -0.5, 0, 0.5, 0, -0.5])
    let poleImpulse = try syntheticSamples("known-pole-impulse")
    #expect(Array(poleImpulse.prefix(8)) == [0.625, 0, -0.15625, 0, 0.0390625, 0, -0.009765625, 0])
    #expect(try syntheticSamples("subnormal-dc").allSatisfy { $0 == Double.leastNonzeroMagnitude })
}

@Test func syntheticAlgebraMatchesDirectTransformAndDifferences() throws {
    struct Algebra: Decodable {
        struct Case: Decodable {
            let real: [Double]?
            let imaginary: [Double]?
            let differences: [Double]?
            let cmnd: [Double]?
        }
        let cases: [String: Case]
    }
    let algebra = try JSONDecoder().decode(Algebra.self, from: syntheticBytes("algebra.json"))
    let samples = try syntheticSamples("quarter-tone")
    let dft = try #require(algebra.cases["quarter-dft"])
    for k in samples.indices {
        let re = samples.indices.reduce(0.0) {
            $0 + samples[$1] * cos(-2 * .pi * Double(k * $1) / 8)
        }
        let im = samples.indices.reduce(0.0) {
            $0 + samples[$1] * sin(-2 * .pi * Double(k * $1) / 8)
        }
        #expect(abs(re - (try #require(dft.real))[k]) < 1e-14)
        #expect(abs(im - (try #require(dft.imaginary))[k]) < 1e-14)
    }
    let yin = try #require(algebra.cases["yin-difference"])
    var cumulative = 0.0
    for lag in 1...4 {
        let difference = (0..<4).reduce(0.0) { sum, n in
            let delta = samples[n] - samples[n + lag]
            return sum + delta * delta
        }
        cumulative += difference
        #expect(difference == (try #require(yin.differences))[lag - 1])
        #expect(
            abs(difference * Double(lag) / cumulative - (try #require(yin.cmnd))[lag - 1]) < 1e-14)
    }
}

@Test func syntheticSequenceOutcomesPreserveMissingAndUndefined() throws {
    struct Sequences: Decodable {
        struct Sequence: Decodable {
            struct Statistic: Decodable {
                struct Rational: Decodable {
                    let numerator: String
                    let denominator: String
                }
                let measurement: MeasurementDescriptor
                let outcome: MeasurementOutcome
                let exactRational: Rational?
                let eligibleWindowCount: Int
            }
            let statistics: [String: Statistic]
        }
        let cases: [String: Sequence]
    }
    let sequences = try JSONDecoder().decode(Sequences.self, from: syntheticBytes("sequences.json"))
    for sequence in sequences.cases.values {
        for metric in sequence.statistics.values {
            if let rational = metric.exactRational {
                let expected =
                    try #require(Double(rational.numerator))
                    / (try #require(Double(rational.denominator)))
                #expect(try #require(metric.outcome.estimate).value == expected)
            }
        }
    }
    let zero = try #require(sequences.cases["period-constant"]?.statistics["jitterLocal"])
    #expect(zero.outcome.estimate?.value == 0)
    #expect(
        sequences.cases["period-zero"]?.statistics["jitterLocal"]?.outcome
            == .unavailable(.invalidInput))
    #expect(
        sequences.cases["amplitude-silence"]?.statistics["shimmerLocal"]?.outcome
            == .unavailable(.silence))
    #expect(
        sequences.cases["period-short"]?.statistics["jitterLocal"]?.outcome
            == .unavailable(.insufficientData))
    let missing = try #require(sequences.cases["period-missing"]?.statistics["jitterLocal"])
    #expect(missing.eligibleWindowCount == 10)
    #expect(missing.outcome.estimate?.warnings == [.partialCoverage])
    let local = try #require(
        sequences.cases["amplitude-irregular"]?.statistics["shimmerLocal"]?.outcome.estimate)
    // Hand-derived: two .05 differences / 12; normalization mean 131/260.
    #expect(local.value == 13.0 / 786.0)
}

@Test func syntheticValidationRejectsArtifactAndCoverageDrift() throws {
    let bytes = try syntheticBytes("missing-intervals.json")
    let wave = try syntheticBytes("missing-intervals.wav")
    let fixture = try syntheticValidate(bytes, wave)
    #expect(fixture.timing.includedSampleCount == 1728)
    #expect(fixture.timing.excludedSampleCount == 320)
    #expect(throws: SyntheticFixtureError.self) { try syntheticValidate(bytes, wave.dropLast(8)) }
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var timing = try #require(object["timing"] as? [String: Any])
    timing["includedSampleCount"] = 1729
    object["timing"] = timing
    let changed = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: SyntheticFixtureError.self) { try syntheticValidate(changed, wave) }
}

@Test func syntheticNativeValidationPerformance() throws {
    guard ProcessInfo.processInfo.environment["HDXL_SYNTHETIC_PERFORMANCE"] == "1" else { return }
    let catalog = try JSONDecoder().decode(
        SyntheticCatalog.self, from: syntheticBytes("catalog.json"))
    let prepared = try catalog.cases.map { entry in
        (try syntheticBytes(entry.manifest), try syntheticBytes(entry.id + ".wav"))
    }
    for (json, wave) in prepared { _ = try syntheticValidate(json, wave) }
    let diagnostics = WorkerDiagnostics(mode: .detailed)
    let clock = ContinuousClock()
    var times: [Double] = []
    for index in 0..<10 {
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 22
        metadata.frameSequence = UInt64(index)
        let elapsed = try clock.measure {
            try diagnostics.withFrame(metadata) {
                try diagnostics.withInterval(.referenceValidation) {
                    for (json, wave) in prepared { _ = try syntheticValidate(json, wave) }
                }
            }
        }
        times.append(
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
    let report: [String: Any] = [
        "schemaVersion": 1, "workload": "synthetic-catalog-decode-contract-hash-validation",
        "catalogIdentity": catalog.catalogIdentity, "caseCount": prepared.count,
        "trialsSeconds": times, "algorithmPerformance": false,
        "timingBoundary":
            "preloaded JSON decode, contract, selection, and PCM hash validation; includes detailed signposts",
        "frameLength": NSNull(), "hopLength": NSNull(), "precision": "float64",
        "allocations": "unavailable; no audited allocator backend in test process",
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print("SYNTHETIC_VALIDATION " + String(decoding: data, as: UTF8.self))
}
