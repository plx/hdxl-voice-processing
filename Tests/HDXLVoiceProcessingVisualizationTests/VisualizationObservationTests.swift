import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization
import Observation
import Synchronization
import Testing

private final class VisualizationChangeCounter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func increment() { storage.withLock { $0 += 1 } }
}

@Test @MainActor func visualizationObservationIsLimitedToReadPropertiesAndSeries() throws {
    let initial = try visualizationSnapshot()
    let first = VisualizationMetricStore(snapshot: initial)
    let second = VisualizationMetricStore(snapshot: initial)
    let seriesChanges = VisualizationChangeCounter()
    let historyChanges = VisualizationChangeCounter()
    let otherChanges = VisualizationChangeCounter()
    withObservationTracking {
        _ = first.series
    } onChange: {
        seriesChanges.increment()
    }
    withObservationTracking {
        _ = first.snapshot
    } onChange: {
        historyChanges.increment()
    }
    withObservationTracking {
        _ = second.snapshot
    } onChange: {
        otherChanges.increment()
    }
    first.replace(try visualizationSnapshot([100, 110, 120, 130]), state: .running)
    #expect(historyChanges.value == 1)
    #expect(seriesChanges.value == 0 && otherChanges.value == 0)
    first.update(
        presentation: try VisualizationPresentation(
            scale: .logarithmic, maximumVisibleMeasurements: 1))
    #expect(first.snapshot.measurements.count == 4)
    #expect(first.snapshot.series == initial.series)
    #expect(seriesChanges.value == 0 && otherChanges.value == 0)
}

@Test @MainActor func visualizationProfileSwitchAndEvictionCannotInspectStaleResults() throws {
    let initial = try visualizationSnapshot()
    let store = VisualizationMetricStore(snapshot: initial)
    let first = try #require(initial.measurements.first)
    try store.inspect(first.id)
    #expect(store.inspectedMeasurement == first)
    store.replace(try visualizationSnapshot([110, 120]), state: .paused)
    #expect(store.inspectedMeasurement == nil)
    #expect(store.selection?.source == first.id.support)
    let key = try VisualizationSeriesKey(
        measurement: initial.series.measurement,
        profile: ProfileIdentity(
            identifier: initial.series.profile.identifier, sha256: String(repeating: "e", count: 64)
        ), source: initial.series.source)
    store.replace(try VisualizationMetricSnapshot(series: key, measurements: []), state: .loading)
    #expect(store.inspectedID == nil && store.selection == nil)
    #expect(throws: VisualizationError.invalidSelection) { try store.inspect(first.id) }
    let unrelated = try SourceInterval(
        epoch: visualizationEpoch.successor(), startSample: 100, sampleCount: 1, sampleRate: 16000)
    #expect(throws: VisualizationError.invalidSelection) {
        try store.select(VisualizationSelection(source: unrelated))
    }
}
