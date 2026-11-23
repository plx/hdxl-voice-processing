import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingVisualization

@Suite struct AlgorithmInspectionFamilyTests {
    let context = AlgorithmInspectionTests.context
    static let fixture = Result { try AcousticPlotFixtures() }
    static let families = Result { try AcousticPlotFamilyFixtures(fixture.get()) }

    @Test func pulsePeriodsAndPerturbationPreserveRejectionsAndUnavailableVariants() throws {
        let f = try Self.families.get()
        let pulse = try AlgorithmInspection.pulses(
            f.pulses, recipe: .init(sampleRate: 16_000), context: context)
        for period in f.pulses.periods {
            let field = try #require(
                pulse.fields.first { $0.name.hasPrefix("Period \(period.index) ·") })
            #expect(field.value.contains("\(period.durationSeconds) s"))
            #expect(field.value.contains(period.isEligible ? "accepted" : "rejected"))
        }
        for (i, r) in f.jitter.enumerated() {
            let snap = try AlgorithmInspection.jitter(
                r, recipe: .init(sampleRate: 16_000), context: context)
            let other = f.shimmer[i]
            let shimmer = try AlgorithmInspection.shimmer(
                other, recipe: .init(sampleRate: 16_000), context: context)
            #expect(
                snap.measurements
                    == (try JitterVariant.allCases.map { try r.measurementResult($0) }))
            #expect(
                shimmer.measurements
                    == (try ShimmerVariant.allCases.map { try other.measurementResult($0) }))
            #expect(snap.querySeconds == r.query.startSeconds...r.query.endSeconds)
            let before = try SourceInterval(
                epoch: snap.window.epoch, startSample: snap.window.startSample - 1,
                sampleCount: 0, sampleRate: snap.window.sampleRate)
            #expect(!snap.intersects(.init(source: before)))
            if i == 1 {
                #expect(
                    snap.fields.contains { $0.name == "Rejection · excluded" && $0.value == "1" })
                #expect(
                    shimmer.fields.contains { $0.name == "Rejection · excluded" && $0.value == "1" }
                )
            }
            if i == 2 {
                #expect(snap.measurements.allSatisfy { $0.outcome.estimate == nil })
                #expect(shimmer.measurements.allSatisfy { $0.outcome.estimate == nil })
            }
        }
    }

    @Test func spectrumBandsPolesAndHarmonicCorrectionShareProductionValues() throws {
        let f = try Self.families.get()
        let spectral = try AlgorithmInspection.spectrum(f.spectrum, context: context)
        #expect(spectral.curves.first?.samples.values == f.spectrum.binPower)
        let shape = try AlgorithmInspection.spectralShape(f.shape, context: context)
        #expect(
            shape.measurements
                == (try SpectralShapeDescriptor.allCases.compactMap { try f.shape.measurement($0) })
        )
        #expect(shape.fields.contains { $0.name == "Numerator band energy" })
        let formants = try AlgorithmInspection.formants(f.formants, context: context)
        #expect(formants.curves.first?.samples.values == f.formants.diagnostics.coefficients)
        #expect(
            formants.fields.filter { $0.name.hasPrefix("Pole ") }.count
                == f.formants.candidates.count)
        let binding = try JSONDecoder().decode(
            SessionArchiveProfile.self, from: Data(formants.parameters.utf8))
        #expect(binding == f.formants.archiveProfile)
        #expect(try binding.identity() == formants.profile)
        let raw = try AlgorithmInspection.harmonics(f.harmonics.raw, context: context)
        let corrected = try AlgorithmInspection.correctedHarmonics(f.harmonics, context: context)
        #expect(corrected.measurements == [f.harmonics.raw.measurement, f.harmonics.measurement])
        #expect(raw.measurements == [f.harmonics.raw.measurement])
        #expect(
            corrected.fields.filter { $0.name.starts(with: "F") && $0.name.contains("bandwidth") }
                .count == f.harmonics.contributions.count)
        #expect(corrected.dependency == f.harmonics.dependencySupport)
    }

    @Test func hnrLagRunsContainOnlyDefinedProductionCells() throws {
        let f = try Self.fixture.get()
        for method in HNRMethod.allCases {
            let recipe = try HNRConfiguration(method: method, sampleRate: 16_000)
            let grid = try HNRIntervalLayout(configuration: recipe, sampleCount: f.pcm.count)
            let frame = try grid.frame(at: 0)
            let processor = try PreparedHNR<Double>(recipe)
            let t = try AnalysisTiming(source: f.source, includedSampleCount: f.source.sampleCount)
            var checked: Result<Void, any Error>?
            try f.pcm.withUnsafeBufferPointer { pcm in
                let normalization = try HNRNormalization(
                    pcm, timing: t, definition: recipe.normalization)
                try processor.analyze(
                    .init(rebasing: pcm[frame.support]), layout: frame, normalization: normalization
                ) { output in
                    checked = Result {
                        let snap = try AlgorithmInspection.harmonicity(output, context: context)
                        #expect(snap.scalarCount == output.correlationValidity.filter { $0 }.count)
                        for curve in snap.curves {
                            let data = curve.samples
                            let offset = Int(data.xOrigin)
                            let padding =
                                method == .forwardCrossCorrelation
                                && offset > frame.computedMaximumLag
                            #expect((data.stage.name == "hnr-interpolation-padding") == padding)
                            if padding { #expect(data.values.allSatisfy { $0 == 0 }) }
                            for i in data.values.indices {
                                #expect(output.correlationValidity[offset + i])
                                #expect(data.values[i] == output.correlation[offset + i])
                            }
                        }
                        #expect(snap.measurements == [try output.result.measurementResult()])
                        #expect(
                            snap.window == output.result.frameTiming.source
                                && snap.dependency == f.source)
                    }
                }
            }
            try #require(checked).get()
        }
    }

    #if os(macOS)
        @Test(arguments: ["flat-background", "near-tied-plateau", "dense-ripple"])
        func pinnedCepstralPeakAndTrendEdges(_ name: String) throws {
            struct Fixture: Decodable {
                struct Frame: Decodable {
                    let sampleRate: Int
                    let pitchFloorHz: Double
                }
                struct Row: Decodable {
                    struct Profile: Decodable {
                        let name: String
                        let pitchFloorHz, pitchCeilingHz, fitStartSeconds, fitEndSeconds: Double
                    }
                    struct Expected: Decodable {
                        let cppDB, peakQuefrencySeconds, slopeDBPerSecond, interceptDB: Double
                    }
                    let profile: Profile
                    let expected: Expected
                }
                let power: [Double]
                let results: [Row]
                let frameConfiguration: Frame
            }
            let url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("HDXLVoiceProcessingTests/Fixtures/CPP/" + name + ".json")
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            let row = try #require(fixture.results.first { $0.profile.name == "leastSquares-none" })
            let config = try PowerCepstrumConfiguration(
                sampleRate: fixture.frameConfiguration.sampleRate,
                pitchFloorHz: fixture.frameConfiguration.pitchFloorHz)
            let recipe = try CPPProfile(
                frame: config,
                settings: .init(
                    pitchFloorHz: row.profile.pitchFloorHz,
                    pitchCeilingHz: row.profile.pitchCeilingHz, interpolation: .none,
                    fitStartSeconds: row.profile.fitStartSeconds,
                    fitEndSeconds: row.profile.fitEndSeconds, fitMethod: .leastSquares))
            let processor = try PreparedCPP(recipe)
            let source = try SourceInterval(
                epoch: .init(streamID: UUID()), startSample: 0,
                sampleCount: Int64(config.frameLength), sampleRate: Double(config.sampleRate))
            let frame = try CepstralFrameContext(
                origin: .init(
                    epoch: source.epoch, startSample: 0, sampleCount: 0,
                    sampleRate: source.sampleRate),
                timing: .init(source: source, includedSampleCount: source.sampleCount),
                frameIndex: 0, firstAnalysisSampleIndex: 0,
                suppliedAnalysisSampleCount: config.frameLength,
                centerSecondsFromOrigin: source.durationSeconds / 2)
            var captured: Result<AlgorithmInspection, any Error>?
            try fixture.power.withUnsafeBufferPointer { power in
                try processor.analyzePowerCepstrum(power, context: frame) { output in
                    captured = Result { try .cpp(output, recipe: recipe, context: context) }
                }
            }
            let inspection = try #require(captured).get()
            let measured = try #require(inspection.measurements.first?.outcome.estimate?.value)
            #expect(abs(measured - row.expected.cppDB) < 1e-8)
            let peak = try #require(inspection.fields.first { $0.name == "Selected quefrency" })
            #expect(
                abs(
                    (try #require(Double(peak.value.dropLast(2))))
                        - row.expected.peakQuefrencySeconds) < 1e-12)
            let trend = try #require(
                inspection.curves.first { $0.samples.stage.name == "cpp-backgroundDB" }
            ).samples
            for i in trend.values.indices {
                let expected =
                    row.expected.interceptDB + row.expected.slopeDBPerSecond * Double(i)
                    * trend.xStep
                #expect(abs(trend.values[i] - expected) < 1e-8)
            }
        }
    #endif
}
