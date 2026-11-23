import HDXLVoiceProcessing
import SwiftUI

/// A fixed-history plot for a single acoustic series. Bind the same selection to multiple
/// plots on the same source clock. Preparing snapshots never starts an analysis or audio session.
public struct AcousticPlotView: View {
    public let data: AcousticPlotData
    @Binding private var selection: VisualizationSelection?
    private let target: AcousticPersonalTargetOverlay?
    @State private var zoom = false
    @State private var includeZero = false
    @State private var envelope = true
    @State private var bin = 0
    @State private var lastInspected: AcousticPlotIndex?
    @State private var showTarget = true
    @State private var zoomCenter: Double?

    public init(
        _ data: AcousticPlotData, selection: Binding<VisualizationSelection?>,
        personalTarget: AcousticPersonalTargetOverlay? = nil
    ) {
        self.data = data
        _selection = selection
        target = personalTarget.flatMap { $0.applies(to: data) ? $0 : nil }
    }

    private var active: AcousticPlotIndex? {
        guard !data.columns.isEmpty else { return nil }
        let validBin = min(max(0, bin), data.binCount - 1)
        if let selection {
            if let lastInspected, data.cursor(for: lastInspected) == selection {
                return lastInspected
            }
            return data.inspect(selection, bin: validBin)
        }
        return AcousticPlotIndex(column: data.columns.count - 1, bin: validBin)
    }

    private var horizontal: AcousticPlotScale {
        let whole = AcousticPlotScale(bounds: data.horizontalRange ?? 0...1)
        guard zoom, whole.bounds.lowerBound != whole.bounds.upperBound else { return whole }
        let center = zoomCenter.map(whole.fraction) ?? 0.5
        let start = max(0, min(0.75, center - 0.125))
        return AcousticPlotScale(bounds: whole.value(start)...whole.value(start + 0.25))
    }

    private var vertical: AcousticPlotScale {
        if data.kind.isImage {
            return AcousticPlotScale(bounds: 0...(Double(data.binCount - 1) * data.binStep))
        }
        let bounds = AcousticPlotScale.displayBounds(for: data.range ?? 0...1)
        return AcousticPlotScale(
            bounds: includeZero ? min(0, bounds.lowerBound)...max(0, bounds.upperBound) : bounds)
    }

    private var xLabel: String {
        data.kind == .spectrum
            ? "Frequency (Hz)" : "Source time (s) from sample \(data.timeAxis.originSample)"
    }

    private var yLabel: String {
        switch data.kind {
        case .spectrogram: "Frequency (Hz)"
        case .cepstrogram: "Quefrency (s)"
        default: "\(data.valueLabel) (\(VisualizationUnitLabel.native(data.unit).symbol))"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(data.kind.title).font(.headline)
            if data.columns.isEmpty {
                Label("No measurements", systemImage: "waveform.slash")
            } else {
                Text(yLabel).font(.caption.weight(.medium))
                plotArea
                if data.kind.isImage {
                    if let range = data.range {
                        Text(
                            "\(data.valueLabel) · dark \(tick(range.lowerBound)) to light \(tick(range.upperBound)) \(VisualizationUnitLabel.native(data.unit).symbol)"
                        )
                        .font(.caption)
                    } else {
                        Text("No available bins").font(.caption)
                    }
                }
                if data.columns.contains(where: { $0.unavailability != nil })
                    || !data.boundaries.isEmpty
                {
                    Label("Missing or unavailable observations", systemImage: "xmark").font(
                        .caption)
                }
                if data.boundaries.contains(where: { $0.missingSource == nil }) {
                    Text("A source discontinuity has no reported extent.").font(.caption)
                }
                if let target {
                    Toggle(
                        "Personal target · calibrated selected-interval CPPS median",
                        isOn: $showTarget)
                    if showTarget {
                        Label(target.state.text, systemImage: "line.diagonal")
                        Text(
                            "Target support \(target.source.startSample)..<\(target.source.endSample) samples"
                        )
                        Text("Personal calibration \(target.target.sha256)").font(
                            .caption.monospaced())
                        if let median = target.selectedMedianDB {
                            Text("Selected median \(String(median)) dB")
                        }
                    }
                }
                axisControls
                navigation
                if let active {
                    readout(active)
                } else {
                    Label("No observation at this selection", systemImage: "scope")
                }
                if !data.markers.isEmpty {
                    DisclosureGroup("Overlays (\(data.markers.count))") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(data.markers.indices, id: \.self) { i in
                                    let mark = data.markers[i]
                                    Text(
                                        "\(mark.label) · \(String(mark.coordinate)) \(data.kind == .spectrum ? "Hz" : "s")"
                                    )
                                    .font(.subheadline.weight(.medium))
                                    Text(mark.detail).font(.caption)
                                    Text(
                                        "Samples \(mark.support.startSample)..<\(mark.support.endSample) · \(mark.profile.identifier.name)"
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.frame(maxHeight: 200)
                    }
                }
            }
            DisclosureGroup("Analysis profile and window") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(data.settings)
                    if let calibration = data.calibration {
                        Text(
                            "SPL calibration \(calibration.identifier.name) · v\(calibration.identifier.version)"
                        )
                        Text(calibration.sha256).font(.caption.monospaced())
                    }
                    Text(
                        "Profile \(data.profile.identifier.name) · v\(data.profile.identifier.version)"
                    )
                    Text(data.profile.sha256).font(.caption.monospaced())
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var plotArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(tick(vertical.bounds.upperBound))
                        Spacer()
                        Text(tick(vertical.bounds.lowerBound))
                    }
                    .padding(.bottom, 10)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    GeometryReader { proxy in
                        AcousticPlotDrawing(
                            data: data, horizontal: horizontal, vertical: vertical,
                            selection: selection, focused: active, envelope: envelope,
                            target: showTarget ? target : nil
                        )
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0).onEnded { gesture in
                                select(gesture, size: proxy.size)
                            }
                        )
                        .clipped()
                    }
                }.frame(height: 154)
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack {
                        Text(tick(horizontal.bounds.lowerBound))
                        Spacer()
                        Text(tick(horizontal.bounds.upperBound))
                    }.padding(.horizontal, 4).font(.caption2.monospacedDigit()).foregroundStyle(
                        .secondary)
                }
            }
            Text(xLabel).font(.caption).frame(maxWidth: .infinity)
        }
    }

    private var axisControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { options }
            VStack(alignment: .leading, spacing: 8) { options }
        }
    }

    @ViewBuilder private var options: some View {
        Button(
            zoom ? "Show full axis" : "Zoom in 4×",
            systemImage: zoom ? "minus.magnifyingglass" : "plus.magnifyingglass"
        ) {
            zoomCenter = active.flatMap(data.coordinate) ?? horizontal.value(0.5)
            zoom.toggle()
        }
        if !data.kind.isImage {
            Toggle("Include zero", isOn: $includeZero)
        }
        if data.kind == .waveform { Toggle("Min/max envelope", isOn: $envelope) }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if data.kind != .spectrum && data.kind != .waveform {
                navigationRow(
                    "Observation", index: active?.column, count: data.columns.count,
                    previous: nextColumn(-1), next: nextColumn(1))
            }
            if data.binCount > 1 {
                navigationRow(
                    data.kind == .waveform ? "Sample" : "Bin", index: active?.bin,
                    count: data.binCount,
                    previous: nextBin(-1), next: nextBin(1))
            }
            ViewThatFits(in: .horizontal) {
                HStack { selectionButtons }
                VStack(alignment: .leading) { selectionButtons }
            }
        }.font(.subheadline)
    }

    private func navigationRow(
        _ label: String, index: Int?, count: Int,
        previous: (() -> Void)?, next: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            Text("\(label) \(index.map { String($0 + 1) } ?? "—") of \(count)")
            Button {
                previous?()
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous \(label.lowercased())").disabled(previous == nil)
            Button {
                next?()
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next \(label.lowercased())").disabled(next == nil)
        }
    }

    @ViewBuilder private var selectionButtons: some View {
        Button("Select support", systemImage: "selection.pin.in.out") {
            if let active {
                selection = VisualizationSelection(source: data.columns[active.column].dependency)
            }
        }.disabled(active == nil)
        Button("Clear selection", systemImage: "xmark.circle") {
            selection = nil
            lastInspected = nil
        }.disabled(selection == nil)
    }

    private func nextColumn(_ delta: Int) -> (() -> Void)? {
        let i = (active?.column ?? (delta > 0 ? -1 : data.columns.count)) + delta
        guard data.columns.indices.contains(i) else { return nil }
        return { inspect(.init(column: i, bin: active?.bin ?? 0)) }
    }

    private func nextBin(_ delta: Int) -> (() -> Void)? {
        let i = (active?.bin ?? (delta > 0 ? -1 : data.binCount)) + delta
        guard (0..<data.binCount).contains(i) else { return nil }
        return { inspect(.init(column: active?.column ?? 0, bin: i)) }
    }

    private func select(_ gesture: DragGesture.Value, size: CGSize) {
        guard size.width > 0 else { return }
        let from = horizontal.value((gesture.startLocation.x - 4) / max(1, size.width - 8))
        let x = horizontal.value((gesture.location.x - 4) / max(1, size.width - 8))
        let ordinate = vertical.value(1 - (gesture.location.y - 4) / max(1, size.height - 18))
        if data.kind != .spectrum, abs(gesture.translation.width) >= 8,
            let a = data.cursor(atSeconds: min(from, x)),
            let b = data.cursor(atSeconds: max(from, x)),
            let source = try? SourceInterval(
                epoch: a.source.epoch, startSample: a.source.startSample,
                sampleCount: b.source.startSample - a.source.startSample,
                sampleRate: a.source.sampleRate)
        {
            selection = VisualizationSelection(source: source)
            lastInspected = nil
        } else if let index = data.nearestIndex(x: x, ordinate: ordinate) {
            if data.kind != .waveform && data.kind != .spectrum,
                let cursor = data.cursor(atSeconds: x)
            {
                if let match = data.inspect(cursor, bin: index.bin) {
                    inspect(match)
                } else {
                    selection = cursor
                    lastInspected = nil
                }
            } else {
                inspect(index)
            }
        }
    }

    private func inspect(_ index: AcousticPlotIndex) {
        guard let cursor = data.cursor(for: index) else { return }
        bin = index.bin
        lastInspected = index
        selection = cursor
        if zoom, let x = data.coordinate(of: index), !horizontal.bounds.contains(x) {
            zoomCenter = x
        }
    }

    @ViewBuilder private func readout(_ index: AcousticPlotIndex) -> some View {
        let column = data.columns[index.column]
        VStack(alignment: .leading, spacing: 6) {
            if case .metric(let point) = column {
                VisualizationMeasurementReadout(point.measurement)
                ForEach(point.context.indices, id: \.self) { i in
                    Text(point.context[i]).font(.caption)
                }
            } else {
                if let value = column.value(at: index.bin) {
                    Text("\(String(value)) \(VisualizationUnitLabel.native(data.unit).symbol)")
                        .font(.headline.monospacedDigit())
                } else {
                    Label(
                        column.reason(at: index.bin).map(VisualizationText.unavailability)
                            ?? "No data", systemImage: "xmark")
                }
                if let raw = column.rawValue(at: index.bin) {
                    Text("Raw \(String(raw)) \(VisualizationUnitLabel.native(data.rawUnit).symbol)")
                        .font(.subheadline)
                }
                if data.kind == .spectrum || data.kind.isImage {
                    Text(
                        "\(data.kind == .cepstrogram ? "Quefrency" : "Frequency") \(String(Double(index.bin) * data.binStep)) \(data.kind == .cepstrogram ? "s" : "Hz")"
                    )
                }
                if data.kind == .waveform {
                    Text("Source sample \(column.support.startSample + Int64(index.bin))")
                }
                Text(
                    "Frame support \(column.support.startSample)..<\(column.support.endSample) samples"
                )
            }
            if column.support != column.dependency {
                Text(
                    "Contributing samples \(column.dependency.startSample)..<\(column.dependency.endSample)"
                )
            }
            Text("Profile \(data.profile.identifier.name) · v\(data.profile.identifier.version)")
                .font(.caption)
            if let source = selection?.source {
                Text(
                    source.sampleCount == 0
                        ? "Cursor at sample \(source.startSample)"
                        : "Selected samples \(source.startSample)..<\(source.endSample)"
                )
                .font(.caption)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }

    private func tick(_ value: Double) -> String {
        value.formatted(
            .number.precision(.significantDigits(1...4)).notation(
                abs(value) >= 1e6 || (value != 0 && abs(value) < 0.001) ? .scientific : .automatic))
    }
}
