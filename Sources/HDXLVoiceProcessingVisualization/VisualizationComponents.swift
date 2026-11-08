import Foundation
import HDXLVoiceProcessing
import SwiftUI

/// A textual state is always present; colors never encode an aesthetic judgment.
public struct VisualizationStatusView: View {
    public let state: VisualizationState
    public init(_ state: VisualizationState) { self.state = state }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(state.title, systemImage: symbol).font(.subheadline.weight(.medium))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .loading: "hourglass"
        case .running: "waveform"
        case .paused: "pause.circle"
        case .interrupted: "waveform.path.badge.minus"
        case .insufficientData: "waveform.badge.magnifyingglass"
        case .unsupportedMetric: "questionmark.circle"
        case .failure: "exclamationmark.triangle"
        }
    }

    private var detail: String? {
        switch state {
        case .interrupted(let reason): visualizationResetText(reason)
        case .unsupportedMetric(let kind): VisualizationText.measurement(kind)
        case .failure(let code): "Code: \(code.name) · v\(code.version)"
        default: nil
        }
    }
}

/// Exact raw inspection accompanies display formatting. Missing estimates have a
/// reason and no numeric readout. Source support/coverage do not become UI-clock time.
public struct VisualizationMeasurementReadout: View {
    public let measurement: VisualizationMeasurement
    public let format: VisualizationValueFormat
    @Environment(\.locale) private var locale

    public init(
        _ measurement: VisualizationMeasurement, format: VisualizationValueFormat = .standard
    ) {
        self.measurement = measurement
        self.format = format
    }

    public var body: some View {
        let result = measurement.result
        VStack(alignment: .leading, spacing: 8) {
            if let formatted = try? format.format(
                result.outcome, unit: result.measurement.unit, locale: locale)
            {
                Text(formatted.valueText)
                    .font(formatted.displayValue == nil ? .headline : .largeTitle.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("\(formatted.valueText), \(formatted.unit.spoken)"))
                Text(formatted.unit.symbol).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Label("Display conversion unavailable", systemImage: "exclamationmark.triangle")
            }
            if let estimate = result.outcome.estimate {
                LabeledContent("Raw value", value: String(estimate.value))
                if let confidence = estimate.confidence {
                    LabeledContent("Estimator confidence", value: String(confidence))
                }
                ForEach(estimate.warnings, id: \.self) { warning in
                    Label(visualizationWarningText(warning), systemImage: "info.circle")
                        .font(.caption)
                }
            }
            LabeledContent(
                "Source samples",
                value: "\(result.timing.source.startSample)..<\(result.timing.source.endSample)")
            LabeledContent(
                "Included samples",
                value: "\(result.timing.includedSampleCount) / \(result.timing.source.sampleCount)")
            LabeledContent("Epoch", value: String(result.timing.source.epoch.sequence))
            if let scheduled = measurement.scheduled {
                LabeledContent(
                    "Dependency samples",
                    value:
                        "\(scheduled.dependencyTiming.source.startSample)..<\(scheduled.dependencyTiming.source.endSample)"
                )
                LabeledContent(
                    "Selected dependency samples",
                    value:
                        "\(scheduled.dependencyCoverage.selected) / \(scheduled.dependencyCoverage.source)"
                )
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }
}

/// A reusable inspection surface. The host retains the store; this view neither
/// subscribes to results nor owns capture/session work. History and profile headers
/// are separate observers so new samples need not invalidate stable profile content.
public struct VisualizationMetricPanel: View {
    public let store: VisualizationMetricStore
    public let title: String?

    public init(store: VisualizationMetricStore, title: String? = nil) {
        self.store = store
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VisualizationMetricHeading(store: store, title: title)
            VisualizationMetricValues(store: store)
            Divider()
            VisualizationSeriesIdentity(store: store)
        }
        .padding()
    }
}

private struct VisualizationMetricHeading: View {
    let store: VisualizationMetricStore
    let title: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title ?? VisualizationText.measurement(store.series.measurement.kind))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VisualizationStatusView(store.state)
        }
    }
}

private struct VisualizationMetricValues: View {
    let store: VisualizationMetricStore

    private var displayedIndex: Int? {
        if let id = store.inspectedID {
            return store.snapshot.measurements.firstIndex { $0.id == id }
        }
        if let selection = store.selection {
            return store.snapshot.measurements.lastIndex { selection.intersects($0.id.support) }
        }
        return store.snapshot.measurements.indices.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let index = displayedIndex {
                VisualizationMeasurementReadout(
                    store.snapshot.measurements[index], format: store.presentation.valueFormat)
            } else {
                Label(
                    store.selection == nil
                        ? "No measurements yet" : "No measurement in this selection",
                    systemImage: "waveform"
                )
                .foregroundStyle(.secondary)
            }
            if let gap = store.snapshot.boundaries.last {
                Label(visualizationResetText(gap.reason), systemImage: "arrow.triangle.branch")
                if let source = gap.missingSource {
                    Text("Missing source samples: \(source.startSample)..<\(source.endSample)")
                        .font(.caption)
                } else {
                    Text("Missing extent not reported").font(.caption)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        Button("Previous", systemImage: "chevron.left") { step(-1) }
            .disabled(displayedIndex.map { $0 == 0 } ?? true)
        Button("Next", systemImage: "chevron.right") { step(1) }
            .disabled(displayedIndex.map { $0 + 1 >= store.snapshot.measurements.count } ?? true)
        Button("Latest") { store.clearSelection() }
            .disabled(store.snapshot.measurements.isEmpty)
    }

    private func step(_ delta: Int) {
        guard let current = displayedIndex else { return }
        let next = current + delta
        guard store.snapshot.measurements.indices.contains(next) else { return }
        // Main-actor synchronous selection; a refused stale identity never falls back to another result.
        try? store.inspect(store.snapshot.measurements[next].id)
    }
}

private struct VisualizationSeriesIdentity: View {
    let store: VisualizationMetricStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                "Profile: \(store.series.profile.identifier.name) · v\(store.series.profile.identifier.version)"
            )
            Text(store.series.profile.sha256).font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Algorithm: \(store.series.measurement.algorithm.name) · v\(store.series.measurement.algorithm.version)"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

private func visualizationWarningText(_ warning: MeasurementWarning) -> String {
    switch warning {
    case .clipping: "Clipping warning"
    case .lowConfidence: "Low confidence warning"
    case .partialCoverage: "Partial source coverage"
    case .exploratoryApplicability: "Exploratory applicability"
    }
}

private func visualizationResetText(_ reason: ResetReason) -> String {
    switch reason {
    case .explicitReset: "Analysis reset"
    case .newSource: "New source"
    case .droppedAudio: "Acquisition gap"
    case .pause: "Source paused"
    case .routeChange: "Audio route changed"
    case .profileChange: "Analysis profile changed"
    }
}
