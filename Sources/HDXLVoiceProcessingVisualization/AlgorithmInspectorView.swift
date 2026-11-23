import HDXLVoiceProcessing
import SwiftUI

/// The same view renders raw production curves and custom stages on either platform.
/// The host owns source selection. Inspecting a bin never reconfigures audio.
public struct AlgorithmInspectorView: View {
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
            Link("Read the method reference", destination: inspection.reference)
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
                Stepper(
                    "Details page \(min(page, lastPage) + 1) of \(lastPage + 1)", value: $page,
                    in: 0...lastPage)
            }
        }
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
            Picker("Intermediate stage", selection: $curve) {
                ForEach(curves.indices, id: \.self) { index in
                    Text(curves[index].samples.stage.name).tag(index)
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
            }.frame(height: 100).accessibilityHidden(true)
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
                Stepper("Inspect bin", value: $bin, in: 0...(data.values.count - 1))
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
        self.plot = plot
        self.snapshots = snapshots
        _selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AcousticPlotView(plot, selection: $selection)
            let active =
                selection ?? plot.columns.last.map { VisualizationSelection(source: $0.support) }
            let visible = snapshots.indices.filter { i in
                active?.intersects(snapshots[i].window) == true
            }
            if visible.isEmpty { Text("No captured calculation for this selection.") }
            ForEach(visible, id: \.self) { i in
                AlgorithmInspectorView(snapshots[i])
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
            if comparison.settings.isEmpty { Text("Identical settings") }
            ForEach(comparison.settings.indices, id: \.self) { i in
                let change = comparison.settings[i]
                Text(
                    "\(change.path) · \(change.original ?? "absent") → \(change.changed ?? "absent")"
                )
            }
            Text("Baseline").font(.headline)
            InspectionMeasurements(inspection: comparison.original)
            Text("Changed settings").font(.headline)
            InspectionMeasurements(inspection: comparison.changed)
            DisclosureGroup("Inspect changed calculation") {
                AlgorithmInspectorView(comparison.changed)
            }
        }
    }
}
