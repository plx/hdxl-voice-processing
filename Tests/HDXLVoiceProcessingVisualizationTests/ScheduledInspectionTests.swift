import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingVisualization

@Suite struct ScheduledInspectionTests {
    @Test func sourceMappedCaptureUsesThePlottedKernelAndTail() throws {
        let context = AlgorithmInspectionTests.context
        var chosen: [ScheduledAlgorithm: (AlgorithmInspection, ScheduledFrame)] = [:]
        var failure: (any Error)?
        let fixture = try AcousticPlotFixtures { borrowed in
            guard borrowed.frameIndex == 3 else { return }
            do {
                let snapshot = try AlgorithmInspection.scheduled(borrowed, context: context)
                chosen[borrowed.frame.algorithm] = (snapshot, borrowed.frame)
                if case .pitch(let pitch) = borrowed.output, let recipe = borrowed.profile.pitch {
                    let raw = try AlgorithmInspection.pitch(pitch, recipe: recipe, context: context)
                    #expect(raw.profile == (try recipe.identity()))
                    #expect(raw.measurements.first?.profile == (try recipe.estimator.identity()))
                    var history = try InspectionHistory(
                        sampling: .selected(frame: 3), context: context, source: .init(raw.window),
                        profile: recipe.identity())
                    #expect(try history.capture(frame: borrowed.frameIndex) { _ in raw })
                }
            } catch { failure = error }
        }
        if let failure { throw failure }
        #expect(Set(chosen.keys) == [.yin, .cpps, .hnr])
        for (algorithm, metrics) in [
            (ScheduledAlgorithm.yin, [ScheduledMetric.fundamentalFrequency]),
            (.cpps, [.cpp, .cpps]), (.hnr, [.harmonicToNoiseRatio]),
        ] {
            let (snapshot, frame) = try #require(chosen[algorithm])
            #expect(fixture.frames.contains(frame))
            #expect(snapshot.profile == frame.schedule)
            #expect(snapshot.window == (try frame.export(metrics[0]).observationWindow))
            #expect(snapshot.dependency == frame.timing.source)
            #expect(snapshot.measurements == (try metrics.map(frame.measurementResult)))
            #expect(!snapshot.curves.isEmpty)
            #expect(
                snapshot.curves.allSatisfy {
                    $0.samples.source.epoch == fixture.source.epoch
                        && $0.samples.source.startSample >= fixture.source.startSample
                })
        }
    }

    @Test func changingPreviewSmoothingPreservesCenterAndExplainsDifferentDependencies() throws {
        let pcm = AlgorithmInspectionTests.tone(4_800, hz: 125)
        let input = try FrozenInspectionInput(
            samples: pcm, source: AlgorithmInspectionTests.source(pcm.count),
            context: AlgorithmInspectionTests.context)
        let cepstral = try CepstrogramConfiguration(
            sourceSampleRate: 16_000, hopSeconds: 0.01,
            declaredInputBandwidthHz: 8_000,
            conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
        func recipe(_ span: Double) throws -> FrozenInspectionRecipe {
            .cpps(
                try CPPSProfile(
                    cepstrogram: cepstral,
                    settings: .init(
                        timeWindowSeconds: span, prominence: .init(fitMethod: .leastSquares))),
                frame: 6)
        }
        let experiment = try FrozenInspectionExperiment(input: input, recipe: recipe(0))
        let comparison = try experiment.compare(recipe(0.06))
        #expect(comparison.original.window == comparison.changed.window)
        #expect(
            comparison.original.dependency.sampleCount < comparison.changed.dependency.sampleCount)
        #expect(comparison.settings.count == 1)
    }

    @Test func estimateExportsReportTheVisualizationBudgetError() throws {
        let recipe = try AlgorithmInspectionTests.pitch()
        let samples = AlgorithmInspectionTests.tone(recipe.requiredSampleCount, hz: 150)
        let source = try AlgorithmInspectionTests.source(samples.count)
        let tight = try VisualizationLimits(
            maximumMeasurements: 2, maximumFrameScalars: 1, maximumSegments: 128,
            maximumMetadataBytes: 32_000)
        let input = try FrozenInspectionInput(
            samples: samples, source: source, context: AlgorithmInspectionTests.context)
        let worker = try PreparedYIN<Double>(recipe)
        try samples.withUnsafeBufferPointer {
            try worker.analyze(
                $0, timing: .init(source: source, includedSampleCount: source.sampleCount),
                frameIndex: 0
            ) { output in
                #expect(throws: VisualizationError.capacityExceeded) {
                    try AlgorithmInspection.pitch(
                        output, recipe: recipe, context: input.context, limits: tight)
                }
            }
        }
    }
}
