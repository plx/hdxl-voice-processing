import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization
import Testing

/// Real scheduled CPP/CPPS outputs exercise shared support at whole-interval and
/// streaming-preview boundaries. Support is not a frame discriminator.
@Test(arguments: [false, true])
@MainActor func visualizationCepstralHistoriesKeepDistinctFramePlacement(_ preview: Bool) throws {
    let source = try visualizationSource(1000, 3200)
    let origin = try AnalysisScheduleOrigin(
        source: visualizationSource(1000, 0), continuityEpoch: visualizationEpoch.successor())
    let cpps = try CPPSProfile(
        cepstrogram: CepstrogramConfiguration(
            sourceSampleRate: 16000, hopSeconds: 0.01, declaredInputBandwidthHz: 8000,
            conditioningMethod: preview
                ? .streamingPreview(lobes: 8, cutoffFraction: 0.9)
                : .praat7WholeInterval(interpolationDepth: 50)),
        settings: CPPSConfiguration(
            timeWindowSeconds: 0.02, prominence: CPPConfiguration(fitMethod: .leastSquares)))
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: PCMChannelSelection(channelIndex: 0), cpps: cpps)
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: origin, mode: .finite, expectedSampleCount: source.sampleCount)
    let pcm = (0..<3200).map { 0.3 * sin(2 * .pi * 125 * Double($0) / 16000) }
    var frames: [ScheduledFrame] = []
    try pcm.withUnsafeBufferPointer {
        _ = try worker.processInterleaved($0, interval: source) { frames.append($0) }
    }
    _ = try worker.finish { frames.append($0) }
    #expect(frames.count == (preview ? 12 : 11))
    for metric in [ScheduledMetric.cpp, .cpps] {
        let rows = try frames.map { try VisualizationMeasurement($0, metric: metric) }
        #expect(Set(rows.map(\.id)).count == rows.count)
        if !preview || metric == .cpps {
            #expect(rows[0].id.support.startSample == rows[1].id.support.startSample)
        }
        if !preview { #expect(Set(rows.map(\.id.support)).count == 1) }
        let snapshot = try VisualizationMetricSnapshot(
            series: rows[0].id.series, measurements: rows)
        for (row, frame) in zip(rows, frames) {
            #expect(snapshot.inspect(row.id) == row)
            #expect(row.scheduled == (try frame.export(metric)))
            #expect(
                row.id.scheduledFrameCenterSecondsFromOrigin == frame.frameCenterSecondsFromOrigin)
        }
        #expect(throws: VisualizationError.duplicateMeasurement) {
            try VisualizationMetricSnapshot(
                series: snapshot.series, measurements: [rows[0], rows[0]])
        }
        #expect(throws: VisualizationError.unorderedMeasurements) {
            try VisualizationMetricSnapshot(series: snapshot.series, measurements: rows.reversed())
        }
        let store = VisualizationMetricStore(snapshot: snapshot)
        try store.inspect(rows[0].id)
        let evicted = try VisualizationMetricSnapshot(
            series: snapshot.series, measurements: Array(rows.dropFirst()))
        store.replace(evicted, state: .running)
        #expect(store.inspectedID == nil)
        #expect(store.snapshot.inspect(rows[0].id) == nil)
        #expect(throws: VisualizationError.invalidSelection) { try store.inspect(rows[0].id) }
        try store.inspect(rows[1].id)
        #expect(store.inspectedMeasurement == rows[1])
    }
}

@Test func visualizationBareSupportsMayShareAStartWithoutSharingIdentity() throws {
    let first = try visualizationResult(start: 100)
    let second = try MeasurementResult(
        measurement: first.measurement, profile: first.profile,
        timing: AnalysisTiming(source: visualizationSource(100, 30), includedSampleCount: 30),
        outcome: first.outcome)
    let rows = [VisualizationMeasurement(first), VisualizationMeasurement(second)]
    let snapshot = try VisualizationMetricSnapshot(series: rows[0].id.series, measurements: rows)
    #expect(rows[0].id != rows[1].id)
    for row in rows { #expect(snapshot.inspect(row.id) == row) }
    #expect(throws: VisualizationError.unorderedMeasurements) {
        try VisualizationMetricSnapshot(series: snapshot.series, measurements: rows.reversed())
    }
}
