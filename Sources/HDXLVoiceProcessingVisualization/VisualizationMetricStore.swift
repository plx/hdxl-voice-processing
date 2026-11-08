import HDXLVoiceProcessing
import Observation

public enum VisualizationScale: Sendable, Hashable { case linear, logarithmic }

/// Renderer preferences do not reconfigure analysis or overwrite the raw snapshot.
/// Later renderers may aggregate their visible subset while retaining exact inspection.
public struct VisualizationPresentation: Sendable, Hashable {
    public let valueFormat: VisualizationValueFormat
    public let scale: VisualizationScale
    public let maximumVisibleMeasurements: Int
    public static let standard = Self()

    private init() {
        valueFormat = .standard
        scale = .linear
        maximumVisibleMeasurements = 512
    }

    public init(
        valueFormat: VisualizationValueFormat = .standard, scale: VisualizationScale = .linear,
        maximumVisibleMeasurements: Int = 512
    ) throws {
        guard (1...1_048_576).contains(maximumVisibleMeasurements) else {
            throw VisualizationError.invalidConfiguration
        }
        self.valueFormat = valueFormat
        self.scale = scale
        self.maximumVisibleMeasurements = maximumVisibleMeasurements
    }
}

/// Host-owned main-actor publication point for one series. Supply immutable values
/// from a bounded worker/subscription; this object owns no tasks, audio or permissions.
/// Separate stores keep unrelated metrics independent. Views reading only `series`,
/// `state`, or `presentation` need not observe every new history snapshot.
@MainActor @Observable public final class VisualizationMetricStore {
    public private(set) var snapshot: VisualizationMetricSnapshot
    public private(set) var series: VisualizationSeriesKey
    public private(set) var state: VisualizationState
    public private(set) var presentation: VisualizationPresentation
    public private(set) var selection: VisualizationSelection?
    public private(set) var inspectedID: VisualizationMeasurementID?

    public init(
        snapshot: VisualizationMetricSnapshot, state: VisualizationState = .running,
        presentation: VisualizationPresentation = .standard
    ) {
        self.snapshot = snapshot
        series = snapshot.series
        self.state = state
        self.presentation = presentation
    }

    public func replace(_ snapshot: VisualizationMetricSnapshot, state: VisualizationState) {
        if series != snapshot.series {
            series = snapshot.series
            selection = nil
            inspectedID = nil
        } else if let inspectedID, snapshot.inspect(inspectedID) == nil {
            self.inspectedID = nil
        }
        self.snapshot = snapshot
        self.state = state
    }

    public func update(state: VisualizationState) { self.state = state }
    public func update(presentation: VisualizationPresentation) { self.presentation = presentation }

    public func clearSelection() {
        selection = nil
        inspectedID = nil
    }

    public func select(_ selection: VisualizationSelection?) throws {
        if let selection, !series.source.contains(selection.source) {
            throw VisualizationError.invalidSelection
        }
        self.selection = selection
        inspectedID = nil
    }

    public func inspect(_ id: VisualizationMeasurementID?) throws {
        if let id {
            guard snapshot.inspect(id) != nil else { throw VisualizationError.invalidSelection }
            selection = VisualizationSelection(source: id.support)
        }
        inspectedID = id
    }

    public var inspectedMeasurement: VisualizationMeasurement? {
        inspectedID.flatMap(snapshot.inspect)
    }
}
