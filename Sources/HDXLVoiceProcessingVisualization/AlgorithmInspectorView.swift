import HDXLVoiceProcessing
import SwiftUI

/// The same view renders raw production curves and custom stages on either platform.
/// The host owns source selection. Inspecting a bin never reconfigures audio.
public struct AlgorithmInspectorView: View {
    @Environment(\.openURL) private var openURL
    public let inspection: AlgorithmInspection

    public init(_ inspection: AlgorithmInspection) { self.inspection = inspection }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(inspection.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(
                inspection.context.origin == .recording
                    ? "Recorded samples" : "Synthesized demonstration"
            )
            .font(.subheadline.weight(.medium))
            Text(inspection.explanation)
            Text(inspection.status).font(.headline)
            InspectionMeasurements(inspection: inspection)
            Text(
                "Window · samples \(String(inspection.window.startSample))..<\(String(inspection.window.endSample))"
            )
            if let query = inspection.querySeconds {
                Text(
                    "Query · \(String(query.lowerBound))…\(String(query.upperBound)) s from dependency start"
                )
            }
            if inspection.window != inspection.dependency {
                Text(
                    "Dependency · samples \(String(inspection.dependency.startSample))..<\(String(inspection.dependency.endSample))"
                )
            }
            Text(
                "\(String(inspection.window.sampleRate)) Hz · source epoch \(String(inspection.window.epoch.sequence)) · configuration epoch \(String(inspection.context.configurationEpoch))"
            )
            .font(.caption)
            if !inspection.curves.isEmpty { InspectionCurveView(curves: inspection.curves) }
            if !inspection.fields.isEmpty { InspectionFieldsView(fields: inspection.fields) }
            DisclosureGroup("Analysis profile and parameters") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "\(inspection.profile.identifier.name) v\(inspection.profile.identifier.version)"
                    )
                    Text(inspection.profile.sha256)
                    Text("Source stream \(inspection.window.epoch.streamID.uuidString)")
                    Text(inspection.parameters)
                }.font(.caption.monospaced()).textSelection(.enabled)
            }
            Button {
                openURL(inspection.reference)
            } label: {
                Label("Read the method reference", systemImage: "arrow.up.right.square")
                    .foregroundStyle(.tint)
            }.buttonStyle(.plain).accessibilityAddTraits(.isLink)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectionMeasurements: View {
    let inspection: AlgorithmInspection

    var body: some View {
        ForEach(inspection.measurements.indices, id: \.self) { i in
            let result = inspection.measurements[i]
            VStack(alignment: .leading) {
                Text(VisualizationText.measurement(result.measurement.kind)).font(
                    .subheadline.bold())
                switch result.outcome {
                case .available(let estimate):
                    Text(
                        "\(String(estimate.value)) \(VisualizationUnitLabel.native(result.measurement.unit).symbol)"
                    )
                    .monospacedDigit()
                    if !estimate.warnings.isEmpty {
                        Text(estimate.warnings.map(\.rawValue).joined(separator: ", ")).font(
                            .caption)
                    }
                case .unavailable(let reason): Text(VisualizationText.unavailability(reason))
                }
            }
        }
    }
}

private struct InspectionFieldsView: View {
    let fields: [InspectionField]
    @State private var page = 0
    private let pageSize = 10

    var body: some View {
        let lastPage = (fields.count - 1) / pageSize
        let first = min(page, lastPage) * pageSize
        VStack(alignment: .leading, spacing: 6) {
            ForEach(first..<min(fields.count, first + pageSize), id: \.self) { i in
                VStack(alignment: .leading) {
                    Text(fields[i].name).font(.caption.weight(.semibold))
                    Text(fields[i].value).monospacedDigit()
                }.accessibilityElement(children: .combine)
            }
            if lastPage > 0 {
                InspectionNavigation(label: "Details page", position: page, count: lastPage + 1) {
                    page = $0
                }
            }
        }
    }
}

extension InspectionCurve {
    fileprivate var displayTitle: String {
        switch samples.stage.name {
        case "yin-scaledSquaredDifference": "Squared difference"
        case "yin-cumulativeMeanNormalizedDifference": "Normalized pitch difference"
        case "cepstrum-windowed": "Windowed samples"
        case "cepstrum-powerSpectrum": "Power spectrum"
        case "cepstrum-logPowerSpectrum": "Log power spectrum"
        case "cepstrum-powerCepstrum", "cpps-rawPower": "Raw power cepstrum"
        case "cpp-cepstralDB": "Cepstrum in decibels"
        case "cpp-backgroundDB", "cpps-backgroundDB": "Fitted background"
        case "cpp-residualDB", "cpps-residualDB": "Fit residuals"
        case "cpps-preparedPower": "Input to smoothing"
        case "cpps-timeSmoothedPower": "Time-smoothed power"
        case "cpps-smoothedPower": "Smoothed power"
        case "cpps-smoothedDB": "Smoothed cepstrum in decibels"
        case "hnr-valid-correlation": "Correlation from lag \(String(samples.xOrigin))"
        case "burg-lpc-coefficients": "Prediction coefficients"
        case "spectrum-bin-power": "Power per frequency bin"
        default: samples.stage.name
        }
    }
}

private struct InspectionNavigation: View {
    let label: String
    let position: Int
    let count: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                select(position - 1)
            } label: {
                Image(systemName: "chevron.left").frame(minWidth: 32, minHeight: 32)
            }.disabled(position == 0).accessibilityLabel(Text("Previous " + label.lowercased()))
            Text("\(label) \(position + 1) of \(count)").monospacedDigit()
            Button {
                select(position + 1)
            } label: {
                Image(systemName: "chevron.right").frame(minWidth: 32, minHeight: 32)
            }.disabled(position + 1 >= count).accessibilityLabel(Text("Next " + label.lowercased()))
        }.buttonStyle(.plain)
    }
}

private struct InspectionCurveView: View {
    let curves: [InspectionCurve]
    @State private var curve = 0
    @State private var bin = 0

    var body: some View {
        let selected = min(curve, curves.count - 1)
        let item = curves[selected]
        let data = item.samples
        let i = min(bin, data.values.count - 1)
        let x = VisualizationUnitLabel.native(data.xUnit).symbol
        let y = VisualizationUnitLabel.native(data.yUnit).symbol
        VStack(alignment: .leading, spacing: 8) {
            Text(item.displayTitle).font(.headline)
            if curves.count > 1 {
                InspectionNavigation(label: "Stage", position: selected, count: curves.count) {
                    curve = $0
                }
            }
            Text(item.explanation)
            let scale = AcousticPlotScale(
                bounds: (data.values.min() ?? 0)...(data.values.max() ?? 0))
            Canvas { context, size in
                let width = max(1, min(2048, Int(size.width.rounded(.up))))
                let count = data.values.count
                // Each horizontal pixel retains the local minimum and maximum.
                var path = Path()
                for column in 0..<min(width, count) {
                    let columns = min(width, count)
                    let slice = data.values[
                        (column * count / columns)..<((column + 1) * count / columns)]
                    guard let low = slice.min(), let high = slice.max() else { continue }
                    let position = (CGFloat(column) + 0.5) * size.width / CGFloat(columns)
                    let top = (1 - scale.fraction(high)) * size.height
                    let bottom = (1 - scale.fraction(low)) * size.height
                    let point = CGPoint(x: position, y: top)
                    if column == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    path.addLine(to: CGPoint(x: position, y: bottom))
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
                let cursor = (CGFloat(i) + 0.5) / CGFloat(count) * size.width
                var marker = Path()
                marker.move(to: .init(x: cursor, y: 0))
                marker.addLine(to: .init(x: cursor, y: size.height))
                context.stroke(
                    marker, with: .color(.secondary), style: .init(lineWidth: 1, dash: [3, 3]))
            }.frame(height: 100)
                .overlay {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle()).gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { event in
                                    let fraction = min(
                                        1, max(0, event.location.x / max(1, geometry.size.width)))
                                    bin = Int((fraction * Double(data.values.count - 1)).rounded())
                                })
                    }
                }
                .accessibilityHidden(true)
            Text(
                "Horizontal · \(String(data.xOrigin))…\(String(data.xOrigin + Double(data.values.count - 1) * data.xStep)) \(x)"
            )
            Text(
                "Vertical · \(String(scale.bounds.lowerBound))…\(String(scale.bounds.upperBound)) \(y)"
            )
            Text(
                "Bin \(i) · \(String(data.xOrigin + Double(i) * data.xStep)) \(x) · \(String(data.values[i])) \(y)"
            ).monospacedDigit()
            if data.values.count > 1 {
                InspectionNavigation(label: "Value", position: i, count: data.values.count) {
                    bin = $0
                }
            }
        }.onChange(of: selected) { bin = 0 }
    }
}

/// Inspect the same temporal selection as a waveform, cepstrogram or metric plot.
/// A cursor in a gap explicitly has no matching calculation.
public struct AcousticPlotInspectorView: View {
    public let plot: AcousticPlotData
    public let snapshots: [AlgorithmInspection]
    @Binding private var selection: VisualizationSelection?
    @State private var chosen: Int?

    public init(
        plot: AcousticPlotData, snapshots: [AlgorithmInspection],
        selection: Binding<VisualizationSelection?>,
        limits: VisualizationLimits = .standard
    ) throws {
        guard snapshots.count <= limits.maximumMeasurements else {
            throw VisualizationError.capacityExceeded
        }
        guard snapshots.allSatisfy({ plot.timeAxis.source.contains($0.window) }) else {
            throw VisualizationError.incompatibleSource
        }
        var scalars = limits.maximumFrameScalars
        var records = limits.maximumSegments
        var metadata = limits.maximumMetadataBytes
        for snapshot in snapshots {
            guard snapshot.scalarCount <= scalars, snapshot.recordCount <= records,
                snapshot.metadataBytes <= metadata
            else { throw VisualizationError.capacityExceeded }
            scalars -= snapshot.scalarCount
            records -= snapshot.recordCount
            metadata -= snapshot.metadataBytes
        }
        self.plot = plot
        self.snapshots = snapshots
        _selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AcousticPlotView(plot, selection: $selection)
            let lastCursor = plot.columns.indices.last.flatMap {
                plot.cursor(for: .init(column: $0, bin: 0))
            }
            let active = selection ?? lastCursor
            let visible = snapshots.indices.filter { i in
                active.map(snapshots[i].intersects) == true
            }
            if visible.isEmpty { Text("No captured calculation for this selection.") }
            if let first = visible.first {
                let current = chosen.flatMap { visible.contains($0) ? $0 : nil } ?? first
                if visible.count > 1 {
                    Picker(
                        "Matching calculation",
                        selection: Binding(get: { current }, set: { chosen = $0 })
                    ) {
                        ForEach(visible, id: \.self) { i in
                            Text(
                                "\(snapshots[i].title) · sample \(String(snapshots[i].window.startSample))"
                            ).tag(i)
                        }
                    }
                }
                AlgorithmInspectorView(snapshots[current]).id(current)
            }
        }
    }
}

public struct FrozenInspectionComparisonView: View {
    public let comparison: FrozenInspectionComparison

    public init(_ comparison: FrozenInspectionComparison) { self.comparison = comparison }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Frozen-window comparison").font(.headline)
            Text(
                comparison.original.context.origin == .recording
                    ? "Recorded samples" : "Synthesized demonstration")
            Text(
                "Samples \(String(comparison.original.window.startSample))..<\(String(comparison.original.window.endSample))"
            )
            .font(.caption)
            if comparison.settings.isEmpty { Text("Identical settings") }
            ForEach(comparison.settings.indices, id: \.self) { i in
                let change = comparison.settings[i]
                Text(
                    "\(change.path) · \(change.original ?? "absent") → \(change.changed ?? "absent")"
                )
            }
            Text("Baseline").font(.headline)
            InspectionMeasurements(inspection: comparison.original)
            DisclosureGroup("Inspect baseline calculation") {
                AlgorithmInspectorView(comparison.original)
            }
            Text("Changed settings").font(.headline)
            InspectionMeasurements(inspection: comparison.changed)
            DisclosureGroup("Inspect changed calculation") {
                AlgorithmInspectorView(comparison.changed)
            }
        }
    }
}
