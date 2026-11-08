import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization
import Testing

@Test func visualizationRelativeTimeKeepsAdjacentLargeSourceSamples() throws {
    let start = Int64.max - 100
    let axis = try VisualizationTimeAxis(origin: visualizationSource(start, 0))
    let source = try visualizationSource(start + 1, 3)
    let placement = try axis.placement(of: source)
    #expect(placement.source == source)
    #expect(placement.lowerSeconds == 1.0 / 16000)
    #expect(placement.centerSeconds == 2.5 / 16000)
    #expect(placement.upperSeconds == 4.0 / 16000)
    #expect(try axis.placement(of: visualizationSource(start - 1, 1)).lowerSeconds == -1.0 / 16000)
    let wrong = try SourceInterval(
        epoch: visualizationEpoch.successor(), startSample: start, sampleCount: 1, sampleRate: 16000
    )
    #expect(throws: VisualizationError.incompatibleSource) { try axis.placement(of: wrong) }
    #expect(throws: VisualizationError.invalidConfiguration) {
        try VisualizationTimeAxis(origin: source)
    }
}

@Test func visualizationSelectionUsesHalfOpenOriginalSupport() throws {
    let cursor = VisualizationSelection(source: try visualizationSource(120, 0))
    #expect(!cursor.intersects(try visualizationSource(100, 20)))
    #expect(cursor.intersects(try visualizationSource(120, 20)))
    #expect(cursor.intersects(try visualizationSource(120, 0)))
    let selection = VisualizationSelection(source: try visualizationSource(110, 10))
    #expect(selection.intersects(try visualizationSource(100, 20)))
    #expect(!selection.intersects(try visualizationSource(120, 20)))
    let wrong = try SourceInterval(
        epoch: visualizationEpoch.successor(), startSample: 110, sampleCount: 1, sampleRate: 16000)
    #expect(!selection.intersects(wrong))
    let snapshot = try visualizationSnapshot()
    #expect(snapshot.selected(by: selection).map(\.id.support.startSample) == [100, 110])
}

@Test func visualizationScalarAdapterPreservesMeaningAndUnavailableZeroDistinction() throws {
    let result = try visualizationResult()
    let row = VisualizationMeasurement(result)
    #expect(row.result == result)
    #expect(row.result.timing.sourceStartSeconds == 42)
    #expect(row.result.timing.completedHostNanoseconds == 10_000_000)
    #expect(row.result.timing.includedSampleCount == 15)
    #expect(row.result.outcome.estimate?.confidence == 0.7)
    #expect(row.result.outcome.estimate?.warnings == [.partialCoverage])
    #expect(row.scheduled == nil)
    let zero = VisualizationMeasurement(
        try visualizationResult(outcome: .available(ScalarEstimate(value: 0))))
    let absent = VisualizationMeasurement(
        try visualizationResult(outcome: .unavailable(.missingAcquisition)))
    #expect(zero.numericValue == 0)
    #expect(absent.numericValue == nil)
    #expect(absent.result.outcome == .unavailable(.missingAcquisition))
}

@Test func visualizationMetricHistoryRejectsMixedAndDuplicateScientificSeries() throws {
    let snapshot = try visualizationSnapshot()
    let first = try #require(snapshot.measurements.first)
    #expect(snapshot.inspect(first.id) == first)
    #expect(throws: VisualizationError.duplicateMeasurement) {
        try VisualizationMetricSnapshot(series: snapshot.series, measurements: [first, first])
    }
    #expect(throws: VisualizationError.unorderedMeasurements) {
        try VisualizationMetricSnapshot(
            series: snapshot.series, measurements: snapshot.measurements.reversed())
    }
    let other = try VisualizationSeriesKey(
        measurement: snapshot.series.measurement,
        profile: ProfileIdentity(
            identifier: snapshot.series.profile.identifier,
            sha256: String(repeating: "f", count: 64)),
        source: snapshot.series.source)
    #expect(throws: VisualizationError.incompatibleSeries) {
        try VisualizationMetricSnapshot(series: other, measurements: snapshot.measurements)
    }
    let empty = try VisualizationMetricSnapshot(series: other, measurements: [])
    #expect(empty.inspect(first.id) == nil)
}

@Test func visualizationLimitsCountNestedDataAndMetadataBeforeRetention() throws {
    let snapshot = try visualizationSnapshot()
    let limits = try VisualizationLimits(
        maximumMeasurements: 2, maximumFrameScalars: 2, maximumSegments: 1,
        maximumMetadataBytes: 1000)
    #expect(throws: VisualizationError.capacityExceeded) {
        try VisualizationMetricSnapshot(
            series: snapshot.series, measurements: snapshot.measurements, limits: limits)
    }
    let frame = try IntermediateSnapshot(
        stage: VersionedIdentifier(name: "waveform", version: 1), source: visualizationSource(),
        xUnit: .seconds, yUnit: .normalizedAmplitude, xOrigin: 0, xStep: 1.0 / 16000,
        values: [0, 1, 2])
    let row = VisualizationMeasurement(try visualizationResult(intermediates: [frame]))
    #expect(throws: VisualizationError.capacityExceeded) {
        try VisualizationMetricSnapshot(series: row.id.series, measurements: [row], limits: limits)
    }
    let textLimit = try VisualizationLimits(
        maximumMeasurements: 10, maximumFrameScalars: 10, maximumSegments: 1,
        maximumMetadataBytes: 1)
    #expect(throws: VisualizationError.capacityExceeded) {
        try VisualizationMetricSnapshot(
            series: snapshot.series, measurements: [], limits: textLimit)
    }
}

@Test func visualizationUnknownGapExtentRemainsUnknown() throws {
    let snapshot = try visualizationSnapshot()
    let gap = try SourceDiscontinuity(
        previousEpoch: visualizationEpoch, nextEpoch: visualizationEpoch.successor(),
        reason: .droppedAudio)
    let withGap = try VisualizationMetricSnapshot(
        series: snapshot.series, measurements: snapshot.measurements, boundaries: [gap])
    #expect(withGap.boundaries == [gap])
    #expect(withGap.boundaries.first?.missingSource == nil)
    #expect(withGap.measurements == snapshot.measurements)
}

@Test func visualizationOwnedSnapshotsSurviveProducerMutationAndTaskTransfer() async throws {
    var values = [0.1, 0.2, 0.3]
    let frame = try VisualizationFrameSnapshot(
        waveform: values, source: visualizationSource(100, 3),
        profile: visualizationProfile().identity(),
        stage: VersionedIdentifier(name: "waveform", version: 1))
    var rows = try visualizationSnapshot().measurements
    let snapshot = try VisualizationMetricSnapshot(series: rows[0].id.series, measurements: rows)
    let reader = Task.detached { (frame.values, snapshot.measurements) }
    values[0] = 99
    rows.removeAll()
    let received = await reader.value
    #expect(received.0 == [0.1, 0.2, 0.3])
    #expect(received.1.count == 3)
    #expect(frame.values[0] == 0.1)
}
