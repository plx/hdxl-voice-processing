import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingVisualization

@Suite struct AcousticPlotPrimaryTests {
    static let fixture = Result { try AcousticPlotFixtures() }

    @Test func sourceClockAndPrimaryMetricReadouts() throws {
        let f = try Self.fixture.get()
        let cases: [(ScheduledMetric, ScheduledAlgorithm, MeasurementKind, MeasurementUnit)] = [
            (.fundamentalFrequency, .yin, .fundamentalFrequency, .hertz),
            (.rms, .levels, .rms, .normalizedAmplitude),
            (.levelDBFS, .levels, .levelDBFS, .decibelsFullScale),
            (.cpp, .cpps, .cpp, .decibelsRatio), (.cpps, .cpps, .cpps, .decibelsRatio),
            (.harmonicToNoiseRatio, .hnr, .harmonicToNoiseRatio, .decibelsRatio),
        ]
        let identity = try f.schedule.identity()
        for (metric, algorithm, kind, unit) in cases {
            let plot = try f.metric(metric, algorithm: algorithm)
            let expected = try f.frames.filter { $0.algorithm == algorithm }.map {
                try $0.export(metric)
            }
            #expect(plot.columns.count == expected.count && expected.count > 1)
            #expect(plot.unit == unit && plot.profile == identity)
            #expect(plot.settings == (try VisualizationProfileSnapshot(f.schedule).canonicalRecipe))
            for (i, row) in expected.enumerated() {
                let cell = AcousticPlotIndex(column: i, bin: 0)
                #expect(row.result.measurement.kind == kind)
                #expect(plot.coordinate(of: cell) == row.frameCenterSecondsFromOrigin)
                #expect(plot.columns[i].value(at: 0) == row.result.outcome.estimate?.value)
                #expect(
                    plot.columns[i].support == row.observationWindow
                        && plot.columns[i].dependency == row.result.timing.source)
                let cursor = try #require(plot.cursor(for: cell))
                #expect(plot.inspect(cursor) == cell)
            }
        }
        let pitch = try f.metric(.fundamentalFrequency, algorithm: .yin)
        let values = pitch.columns.compactMap { $0.value(at: 0) }
        #expect(values.contains { abs($0 - 125) < 2 })
        #expect(values.contains { abs($0 - 200) < 2 })
        #expect(pitch.columns.contains { $0.unavailability != nil && $0.value(at: 0) == nil })
        let clipping = try f.metric(.clippingFraction, algorithm: .levels)
        #expect(clipping.columns.contains { $0.value(at: 0) == 0 })
        #expect(clipping.columns.contains { ($0.value(at: 0) ?? 0) > 0 })
    }

    @Test func waveformEnvelopeRetainsExactSamplesAndSelection() throws {
        let f = try Self.fixture.get()
        let wave = try f.waveform()
        #expect(wave.binCount == f.pcm.count)
        #expect(wave.horizontalRange == 0...0.3)
        for b in try wave.envelope(bins: 17..<4622, maximumBuckets: 73) {
            #expect(b.minimum == f.pcm[b.bins].min() && b.maximum == f.pcm[b.bins].max())
        }
        for i in [0, 1, 1599, 3520, 4799] {
            let index = AcousticPlotIndex(column: 0, bin: i)
            let cursor = try #require(wave.cursor(for: index))
            #expect(cursor.source.startSample == f.source.startSample + Int64(i))
            #expect(wave.inspect(cursor) == index)
            #expect(wave.columns[0].rawValue(at: i) == f.pcm[i])
        }
        let a = try SourceInterval(
            epoch: f.source.epoch, startSample: f.source.endSample,
            sampleCount: 0, sampleRate: f.source.sampleRate)
        #expect(wave.inspect(.init(source: a)) == nil)
        #expect(throws: VisualizationError.invalidConfiguration) {
            try wave.envelope(bins: -1..<1, maximumBuckets: 1)
        }
    }

    @Test func missingFramesAndExtremeRangeStayDistinctFromMeasuredZero() throws {
        let zero = try visualizationResult(
            start: 100, outcome: .available(ScalarEstimate(value: 0)))
        let missing = try visualizationResult(
            start: 130, outcome: .unavailable(.missingAcquisition))
        let extreme = try visualizationResult(
            start: 160, outcome: .available(ScalarEstimate(value: Double.greatestFiniteMagnitude)))
        let rows = [zero, missing, extreme].map(VisualizationMeasurement.init)
        let gap = try SourceDiscontinuity(
            previousEpoch: visualizationEpoch, nextEpoch: visualizationEpoch.successor(),
            reason: .droppedAudio, missingSource: visualizationSource(124, 28))
        let snapshot = try VisualizationMetricSnapshot(
            series: rows[0].id.series, measurements: rows, boundaries: [gap])
        let axis = try VisualizationTimeAxis(origin: visualizationSource(100, 0))
        let data = try AcousticPlotData(metric: snapshot, axis: axis)
        #expect(data.columns[0].value(at: 0) == 0)
        #expect(
            data.columns[1].value(at: 0) == nil
                && data.columns[1].reason(at: 0) == .missingAcquisition)
        #expect(data.columns[2].value(at: 0) == Double.greatestFiniteMagnitude)
        #expect(data.inspect(.init(source: try visualizationSource(123, 0))) == nil)
        let scale = AcousticPlotScale(
            bounds: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude)
        #expect(scale.fraction(0) == 0.5 && scale.value(0.5) == 0)
    }
}
