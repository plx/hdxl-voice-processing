import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct ShimmerPCMReferenceFixture: Decodable {
    struct Case: Decodable {
        let name, pulseFixture: String
        let sampleRate, sampleCount: Int
        let inputPrecision: AnalysisPrecision
        let queryStartSeconds, queryEndSeconds: Double
        let minimumPeriodSeconds, maximumPeriodSeconds: Double
        let maximumAdjacentPeriodFactor, maximumAmplitudeFactor: Double
    }
    struct Contour: Decodable {
        let firstCenterSeconds, stepSeconds, ceilingHz: Double
        let frequenciesHz: [Double]
    }
    struct Reference: Decodable {
        struct Values: Decodable {
            struct Amplitude: Decodable {
                let pulseIndex: Int
                let timeSeconds, rmsAmplitude: Double
            }
            let pulseCount: Int
            let selectedPulseIndices: [Int]
            let amplitudeState: String
            let amplitudes: [Amplitude]
            let tierValues: [String: Double?]?
        }
        let data: Values
    }
    struct Audit: Decodable {
        struct Comparison: Decodable { let bounds: [String: Double]? }
        let equations: ShimmerFixture.Oracle
        let statisticalComparison: Comparison
    }
    struct PCM: Decodable { let artifactSHA256: String }
    let `case`: Case
    let f0Contour: Contour
    let inputPCM: PCM
    let reference: Reference
    let audit: Audit
}

private struct ShimmerPCMReferenceAudit: Encodable {
    let name, inputSHA256: String
    let configuration: ShimmerConfiguration
    let pulseConfiguration: PulseConfiguration
    let result: ShimmerAnalysisResult
    let nativeAmplitudes: [ShimmerAmplitudeInput]
    let upstreamAmplitudeRejections: [UInt32]
    let amplitudeComparisons: Int
    let maximumAmplitudeBudgetFraction: Double
    let directReferenceComparison: Bool
    let directComparisonReason: String
    let maximumStatisticsBudgetFraction: Double
}

private func shimmerPCMReferenceComparison<Sample: BinaryFloatingPoint & Sendable>(
    _ type: Sample.Type, fixture: ShimmerPCMReferenceFixture, samples: [Double]
) throws -> ShimmerPCMReferenceAudit {
    let item = fixture.case
    let pitch = fixture.f0Contour
    let contour = try PulseF0Contour(
        sampleRate: item.sampleRate, sampleCount: item.sampleCount,
        firstCenterSeconds: pitch.firstCenterSeconds, stepSeconds: pitch.stepSeconds,
        ceilingHz: pitch.ceilingHz, frequenciesHz: pitch.frequenciesHz)
    let configuration = try ShimmerConfiguration(
        sampleRate: item.sampleRate, inputPrecision: item.inputPrecision,
        minimumPeriodSeconds: item.minimumPeriodSeconds,
        maximumPeriodSeconds: item.maximumPeriodSeconds,
        maximumAdjacentPeriodFactor: item.maximumAdjacentPeriodFactor,
        maximumAmplitudeFactor: item.maximumAmplitudeFactor)
    let pulseConfiguration = try PulseConfiguration(
        sampleRate: item.sampleRate, inputPrecision: item.inputPrecision,
        pitchCeilingHz: pitch.ceilingHz, minimumPeriodSeconds: item.minimumPeriodSeconds,
        maximumPeriodSeconds: item.maximumPeriodSeconds,
        maximumAdjacentPeriodFactor: item.maximumAdjacentPeriodFactor)
    let worker = try PreparedPCMShimmer<Sample>(
        configuration: configuration, pulseConfiguration: pulseConfiguration,
        maximumSampleCount: item.sampleCount, maximumF0FrameCount: pitch.frequenciesHz.count,
        maximumTrackingAttempts: 4096)
    let timing = try AnalysisTiming(
        source: SourceInterval(
            epoch: StreamEpoch(streamID: UUID()),
            startSample: Int64.max - Int64(samples.count), sampleCount: Int64(samples.count),
            sampleRate: Double(item.sampleRate)),
        includedSampleCount: Int64(samples.count), sourceStartSeconds: 20)
    let query = try ShimmerQueryRange(
        startSeconds: item.queryStartSeconds, endSeconds: item.queryEndSeconds)
    var row: ShimmerPCMReferenceAudit?
    try samples.map { Sample($0) }.withUnsafeBufferPointer { input in
        try worker.analyze(input, contour: contour, timing: timing, query: query) { output in
            let amplitudes = try output.snapshotAmplitudes(maximumCount: 30000)
            let accepted = amplitudes.filter {
                $0.rejections.isEmpty && $0.amplitude != nil
                    && $0.timeSeconds >= query.startSeconds && $0.timeSeconds <= query.endSeconds
            }
            let external = fixture.reference.data.amplitudes
            let byIndex = Dictionary(uniqueKeysWithValues: external.map { ($0.pulseIndex, $0) })
            #expect(
                output.pulses.landmarks.count == fixture.reference.data.pulseCount, "\(item.name)")
            #expect(output.result.coverage.acceptedAmplitudeCount == accepted.count)
            var amplitudeFraction = 0.0
            var amplitudeError = 0.0
            for a in accepted {
                let expected = try #require(
                    byIndex[Int(a.sequenceIndex)], "\(item.name): invented RMS observation")
                let value = try #require(a.amplitude)
                let error = abs(value - expected.rmsAmplitude)
                let bound = 2e-12 + 1e-10 * abs(expected.rmsAmplitude)
                amplitudeError = max(amplitudeError, error)
                amplitudeFraction = max(amplitudeFraction, error / bound)
                #expect(error <= bound, "\(item.name): RMS \(a.sequenceIndex)")
                #expect(abs(a.timeSeconds - expected.timeSeconds) * Double(item.sampleRate) <= 1e-6)
            }

            // Compare raw reference tier mathematics through the public supplied-
            // amplitude API even when native tracking intentionally excludes cycles.
            let supplied = try external.enumerated().map {
                try ShimmerAmplitudeInput(
                    timeSeconds: $0.element.timeSeconds,
                    amplitude: $0.element.rmsAmplitude, sequenceIndex: UInt64($0.offset))
            }
            let statistics = try PreparedShimmer(
                configuration: configuration, maximumAmplitudeCount: max(1, supplied.count))
            let rawTier = try supplied.withUnsafeBufferPointer {
                try statistics.analyze($0, dependencyTiming: timing, query: query)
            }
            if let values = fixture.reference.data.tierValues {
                for variant in ShimmerVariant.allCases {
                    let expected = values[variant.rawValue] ?? nil
                    let actual = rawTier.estimate(variant).value
                    #expect(
                        (actual == nil) == (expected == nil), "\(item.name) raw tier \(variant)")
                    if let actual, let expected {
                        let bound = try #require(
                            fixture.audit.statisticalComparison.bounds?[variant.rawValue])
                        #expect(abs(actual - expected) <= bound, "\(item.name) raw tier \(variant)")
                    }
                }
            } else {
                #expect(fixture.reference.data.selectedPulseIndices.count < 3)
                for variant in ShimmerVariant.allCases {
                    #expect(output.result.estimate(variant).value == nil)
                }
            }

            // A combined scalar comparison is meaningful only for identical
            // populations and neighborhoods. Exclusions are retained in the
            // exported report, not hidden by a loose numerical tolerance.
            let samePopulation =
                accepted.map { Int($0.sequenceIndex) } == external.map(\.pulseIndex)
            let oneContinuousRun = zip(accepted, accepted.dropFirst()).allSatisfy {
                $0.runID == $1.runID && $0.sequenceIndex < .max
                    && $0.sequenceIndex + 1 == $1.sequenceIndex
            }
            let coverage = output.result.coverage
            let oracle = fixture.audit.equations
            let sameNeighborhoods =
                coverage.acceptedPairCount == oracle.pairStartIndices.count
                && coverage.acceptedAPQ3NeighborhoodCount == oracle.apq3WindowStartIndices.count
                && coverage.acceptedAPQ5NeighborhoodCount == oracle.apq5WindowStartIndices.count
                && coverage.acceptedAPQ11NeighborhoodCount == oracle.apq11WindowStartIndices.count
            let direct =
                fixture.reference.data.tierValues != nil && samePopulation && oneContinuousRun
                && sameNeighborhoods
            var statisticFraction = 0.0
            if direct, let values = fixture.reference.data.tierValues {
                for variant in ShimmerVariant.allCases {
                    let expected = values[variant.rawValue] ?? nil
                    let actual = output.result.estimate(variant).value
                    #expect(
                        (actual == nil) == (expected == nil), "\(item.name) combined \(variant)")
                    if let actual, let expected {
                        let arithmetic = try #require(
                            fixture.audit.statisticalComparison.bounds?[variant.rawValue])
                        let bound: Double
                        if variant == .db {
                            let minimum = try #require(external.map(\.rmsAmplitude).min())
                            try #require(minimum > amplitudeError)
                            bound =
                                arithmetic + 40 / log(10) * amplitudeError
                                / (minimum - amplitudeError)
                        } else {
                            let mean = try #require(oracle.meanAmplitude)
                            try #require(mean > amplitudeError)
                            // Central-deviation/local numerator error <= 2e;
                            // DDA scales that bound by three. Mean error <= e.
                            bound =
                                arithmetic + ((variant == .dda ? 6 : 2) + abs(expected))
                                * amplitudeError / (mean - amplitudeError)
                        }
                        let error = abs(actual - expected)
                        statisticFraction = max(statisticFraction, error / bound)
                        #expect(
                            error <= bound, "\(item.name) combined \(variant): \(error) > \(bound)")
                    }
                }
            }
            if item.pulseFixture.hasPrefix("gaussian-") {
                if item.queryStartSeconds > 0 {
                    #expect(direct, "\(item.name): interior anchor lost direct comparison")
                } else {
                    // The existing pulse contract requires complete matching
                    // support, beyond the raw reference's amplitude window.
                    // Its first interior amplitude inherits an unsupported
                    // leading tracking edge and must remain excluded.
                    let missing = Set(external.map(\.pulseIndex))
                        .subtracting(accepted.map { Int($0.sequenceIndex) })
                    #expect(missing == [1], "\(item.name)")
                    #expect(output.pulses.amplitudes[1].rejections.contains(.insufficientSupport))
                    #expect(amplitudes[1].rejections.contains(.insufficientSupport))
                    #expect(amplitudes[1].amplitude == nil)
                }
            }
            row = ShimmerPCMReferenceAudit(
                name: item.name, inputSHA256: fixture.inputPCM.artifactSHA256,
                configuration: configuration, pulseConfiguration: pulseConfiguration,
                result: output.result, nativeAmplitudes: amplitudes,
                upstreamAmplitudeRejections: output.pulses.amplitudes.map {
                    $0.rejections.rawValue
                },
                amplitudeComparisons: accepted.count,
                maximumAmplitudeBudgetFraction: amplitudeFraction,
                directReferenceComparison: direct,
                directComparisonReason: direct
                    ? "identical population and neighborhoods"
                    : fixture.reference.data.tierValues == nil
                        ? "reference not executed: insufficient pulses"
                        : !samePopulation
                            ? "native source reliability excludes additional amplitudes"
                            : !oneContinuousRun
                                ? "explicit native run or cycle gaps"
                                : "numerical edge eligibility differs",
                maximumStatisticsBudgetFraction: statisticFraction)
        }
    }
    return try #require(row)
}

@Test func shimmerPCMReferenceSeparatesExtractionFormulaAndNativeEligibilityEvidence() throws {
    struct Manifest: Decodable { let catalog: [ShimmerPCMReferenceFixture.Case] }
    let fixtures = try #require(
        Bundle.module.url(forResource: "ShimmerPCM", withExtension: nil, subdirectory: "Fixtures"))
    let waves = try #require(
        Bundle.module.url(forResource: "Pulses", withExtension: nil, subdirectory: "Fixtures"))
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
    #expect(manifest.catalog.count == 80)
    var rows: [ShimmerPCMReferenceAudit] = []
    for item in manifest.catalog {
        let fixture = try JSONDecoder().decode(
            ShimmerPCMReferenceFixture.self,
            from: Data(contentsOf: fixtures.appendingPathComponent(item.name + ".json")))
        let encoded = try Data(contentsOf: waves.appendingPathComponent(item.pulseFixture + ".wav"))
        let sha = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        try #require(sha == fixture.inputPCM.artifactSHA256)
        let pcm = try CorpusPCM(data: encoded)
        try #require(pcm.sampleRate == item.sampleRate && pcm.samples.count == item.sampleCount)
        let row =
            try item.inputPrecision == .float32
            ? shimmerPCMReferenceComparison(Float.self, fixture: fixture, samples: pcm.samples)
            : shimmerPCMReferenceComparison(Double.self, fixture: fixture, samples: pcm.samples)
        rows.append(row)
    }
    #expect(rows.count == 80)
    if let path = ProcessInfo.processInfo.environment["HDXL_SHIMMER_PCM_REPORT"] {
        let destination = URL(filePath: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try canonicalContractJSON(rows).write(to: destination)
    }
}
