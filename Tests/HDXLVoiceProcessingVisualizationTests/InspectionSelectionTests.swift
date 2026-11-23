import Foundation
import HDXLVoiceProcessing
import SwiftUI
import Testing

@testable import HDXLVoiceProcessingVisualization

@Suite struct InspectionSelectionTests {
    @Test @MainActor func gapsRetainOnlyUnavailableExplanationsAndHistoryUsesStableIdentity() throws
    {
        let original = try InspectorPreviewFixture().experiment.original
        let m = try #require(original.measurements.first)
        let observed = try AcousticMetricObservation(m)
        let source = original.window
        func interval(_ offset: Int64, _ length: Int64) throws -> SourceInterval {
            try .init(
                epoch: source.epoch, startSample: source.startSample + offset, sampleCount: length,
                sampleRate: source.sampleRate)
        }
        let gap = try SourceDiscontinuity(
            previousEpoch: source.epoch, nextEpoch: source.epoch.successor(),
            reason: .droppedAudio, missingSource: interval(20, 12))
        let plot = try AcousticPlotData(
            metric: observed.measurement.id.series, observations: [observed],
            axis: .init(origin: interval(0, 0)), boundaries: [gap])
        let unavailable = try AlgorithmInspection(
            title: "Gap", explanation: "Samples were missing.",
            reference: original.reference, context: original.context, window: interval(20, 12),
            dependency: source,
            profile: original.profile, parameters: original.parameters,
            status: "Missing acquisition",
            unavailability: .missingAcquisition)
        let view = try AcousticPlotInspectorView(
            plot: plot, snapshots: [original, unavailable], selection: .constant(nil))
        #expect(view.matching(.init(source: try interval(23, 0))).map(\.id) == [unavailable.id])
        #expect(
            view.matching(.init(source: try interval(16, 16))).map(\.id) == [
                original.id, unavailable.id,
            ])
        let history = try AcousticPlotInspectorView(
            plot: plot, snapshots: [unavailable], selection: .constant(nil))
        #expect(history.matching(.init(source: try interval(23, 0))).first?.id == unavailable.id)
    }

    @Test func extensionQueryAndNestedMeasurementLimitsAreCheckedBeforeRetention() throws {
        let original = try InspectorPreviewFixture().experiment.original
        let m = try #require(original.measurements.first)
        let limit = try VisualizationLimits(
            maximumMeasurements: 2, maximumFrameScalars: 4096, maximumSegments: 100,
            maximumMetadataBytes: 16384)
        func make(_ count: Int, query: ClosedRange<Double>? = nil) throws -> AlgorithmInspection {
            try .init(
                title: "Pitch readout", explanation: "Selected frequency.",
                reference: original.reference,
                context: original.context, window: original.window, dependency: original.dependency,
                profile: original.profile,
                parameters: original.parameters, status: "Available",
                measurements: Array(repeating: m, count: count),
                querySeconds: query, limits: limit)
        }
        #expect(throws: VisualizationError.invalidSelection) { try make(1, query: 2...3) }
        #expect(throws: VisualizationError.capacityExceeded) { try make(3) }
        let two = try make(2)
        var history = try InspectionHistory(
            sampling: .sampled(every: 1, maximumFrames: 2), context: original.context,
            source: .init(original.window), profile: original.profile, limits: limit)
        try history.capture(frame: 0) { _ in two }
        let replacement = try make(1)
        try history.capture(frame: 1) { _ in replacement }
        #expect(history.snapshots.map(\.id) == [replacement.id])
    }
}
