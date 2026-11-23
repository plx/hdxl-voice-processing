import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingVisualization

@Suite struct AlgorithmInspectionTests {
    static let context = InspectionContext(origin: .synthesizedDemonstration, configurationEpoch: 3)
    static func source(_ count: Int) throws -> SourceInterval {
        try SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: (1 << 54) + 1,
            sampleCount: Int64(count), sampleRate: 16_000)
    }
    static func pitch(_ threshold: Double = 0.1) throws -> YINConfiguration {
        try YINConfiguration(
            sampleRate: 16_000, pitchFloorHz: 60, pitchCeilingHz: 500,
            integrationLength: 400, hopLength: 160, threshold: threshold)
    }
    static func tone(_ count: Int, hz: Double, octave: Double = 0) -> [Double] {
        (0..<count).map { index in
            let phase = 2 * Double.pi * Double(index) * hz / 16_000
            return 0.2 * sin(phase) + octave * sin(2 * phase)
        }
    }

    @Test func pitchCurvesCandidatesAndSelectionComeFromBorrowedEstimator() throws {
        let config = try Self.pitch()
        let n = config.requiredSampleCount
        var random: UInt32 = 43
        let noise = (0..<n).map { _ -> Double in
            random = random &* 1_664_525 &+ 1_013_904_223
            return Double(random) / Double(UInt32.max) - 0.5
        }
        let cases = [
            Self.tone(n, hz: 150), Self.tone(n, hz: 65), Self.tone(n, hz: 110, octave: 0.7),
            noise, Array(repeating: 0, count: n), Self.tone(40, hz: 100),
        ]
        for samples in cases {
            let t = try Self.source(samples.count)
            let pitch = try PreparedYIN<Double>(config)
            var checked = false
            var failure: (any Error)?
            try samples.withUnsafeBufferPointer {
                try pitch.analyze($0, timing: .init(source: t, includedSampleCount: t.sampleCount))
                { out in
                    do {
                        let snapshot = try AlgorithmInspection.pitch(
                            out, recipe: config, context: Self.context)
                        #expect(snapshot.window == t)
                        #expect(snapshot.profile == out.result.profile)
                        #expect(snapshot.measurements == [try out.result.measurementResult()])
                        for stage in YINIntermediate.allCases {
                            let values = snapshot.curves.first {
                                $0.samples.stage.name == "yin-" + stage.rawValue
                            }?.samples.values
                            #expect((values ?? []) == Array(out.values(stage)))
                        }
                        #expect(snapshot.fields.count == 1 + out.candidates.count)
                        if let index = out.result.selectedCandidateIndex {
                            #expect(snapshot.fields[index + 1].value.contains("selected"))
                        }
                        checked = true
                    } catch { failure = error }
                }
            }
            if let failure { throw failure }
            #expect(checked)
        }
    }

    @Test func frozenParametersAreExactAndBaselineSurvivesRepeatedExperiments() throws {
        let config = try Self.pitch()
        let samples = Self.tone(config.requiredSampleCount, hz: 80, octave: 0.6)
        let input = try FrozenInspectionInput(
            samples: samples, source: Self.source(samples.count), context: Self.context)
        let experiment = try FrozenInspectionExperiment(input: input, recipe: .pitch(config))
        let changed = try experiment.compare(.pitch(Self.pitch(0.25)))
        #expect(changed.settings == [.init(path: "/threshold", original: "0.1", changed: "0.25")])
        #expect(changed.original.profile != changed.changed.profile)
        let repeatRun = try experiment.compare(.pitch(config))
        #expect(repeatRun.changed.curves == changed.original.curves)
        #expect(repeatRun.changed.measurements == experiment.original.measurements)
        #expect(repeatRun.settings.isEmpty)
    }

    @Test func cppAndSmoothedFitRetainActualLevelsAndTimeSupport() throws {
        let n = 4800
        let samples = Self.tone(n, hz: 140, octave: 0.25)
        let input = try FrozenInspectionInput(
            samples: samples, source: Self.source(n), context: Self.context)
        let transform = try CepstrogramConfiguration(
            sourceSampleRate: 16_000, hopSeconds: 0.01, declaredInputBandwidthHz: 8000)
        let settings = try CPPConfiguration(fitMethod: .leastSquares)
        let original = try FrozenInspectionExperiment(
            input: input, recipe: .cpp(cepstrogram: transform, prominence: settings, frame: 4))
        let frame = original.original
        #expect(frame.window.sampleCount < frame.dependency.sampleCount)
        #expect(frame.curves.count == 7)
        let different = try CPPConfiguration(pitchFloorHz: 80, fitMethod: .leastSquares)
        let comparison = try original.compare(
            .cpp(cepstrogram: transform, prominence: different, frame: 4))
        #expect(comparison.settings.map(\.path) == ["/settings/pitchFloorHz"])
        let recipe = try CPPSProfile(
            cepstrogram: transform,
            settings: CPPSConfiguration(timeWindowSeconds: 0.02, prominence: settings))
        let smoothed = try FrozenInspectionExperiment(input: input, recipe: .cpps(recipe, frame: 4))
            .original
        #expect(smoothed.measurements.first == frame.measurements.first)
        #expect(smoothed.curves.count == CPPSIntermediate.allCases.count)
        #expect(smoothed.window == frame.window)
        let analyzer = try PreparedIntervalCPPS<Double>(profile: recipe, source: input.source)
        try samples.withUnsafeBufferPointer { try analyzer.append($0, interval: input.source) }
        var checked = false
        _ = try analyzer.finish { out in
            guard out.result.context.frameIndex == 4 else { return }
            for (i, stage) in CPPSIntermediate.allCases.enumerated() {
                #expect(smoothed.curves[i].samples.values == Array(out.values(stage)))
            }
            #expect(
                smoothed.measurements.last?.outcome.estimate?.value
                    == out.result.observation?.prominenceDB)
            checked = true
        }
        #expect(checked)
    }

    @Test func disabledSelectionAndSampledHistoryRespectBudgetsAndEpochs() throws {
        let config = try Self.pitch()
        let samples = Self.tone(config.requiredSampleCount, hz: 150)
        let t = try Self.source(samples.count)
        let input = try FrozenInspectionInput(samples: samples, source: t, context: Self.context)
        let snap = try FrozenInspectionExperiment(input: input, recipe: .pitch(config)).original
        var disabled = try InspectionHistory(
            context: Self.context, source: VisualizationSource(t), profile: snap.profile)
        var calls = 0
        func make(_: VisualizationLimits) -> AlgorithmInspection {
            calls += 1
            return snap
        }
        #expect(try !disabled.capture(frame: 0, make: make))
        var selected = try InspectionHistory(
            sampling: .selected(frame: 7), context: Self.context, source: VisualizationSource(t),
            profile: snap.profile)
        #expect(try !selected.capture(frame: 6, make: make))
        #expect(calls == 0)
        #expect(try selected.capture(frame: 7, make: make))
        let limits = try VisualizationLimits(
            maximumMeasurements: 5, maximumFrameScalars: snap.scalarCount * 2,
            maximumSegments: snap.recordCount * 3, maximumMetadataBytes: snap.metadataBytes * 4)
        var live = try InspectionHistory(
            sampling: .sampled(every: 2, maximumFrames: 5), context: Self.context,
            source: VisualizationSource(t), profile: snap.profile, limits: limits)
        for i in 0..<12 { _ = try live.capture(frame: UInt64(i), make: make) }
        #expect(calls == 7)
        #expect(live.snapshots.count == 2)
        #expect(live.scalarCount == snap.scalarCount * 2)
        #expect(throws: VisualizationError.unorderedMeasurements) {
            try live.capture(frame: 10, make: make)
        }
        let next = InspectionContext(origin: .synthesizedDemonstration, configurationEpoch: 4)
        var newEpoch = try InspectionHistory(
            sampling: .selected(frame: 0), context: next,
            source: VisualizationSource(t), profile: snap.profile)
        #expect(throws: VisualizationError.incompatibleSource) {
            try newEpoch.capture(frame: 0, make: make)
        }
        #expect(newEpoch.snapshots.isEmpty)
    }
}
