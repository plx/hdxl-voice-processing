import HDXLVoiceProcessing
import SwiftUI

/// Exact local inspection is independent of the source interval published to sibling plots.
struct AcousticPlotInspection {
    let index: AcousticPlotIndex
    let shared: VisualizationSelection
    let cursor: VisualizationSelection
    let support: VisualizationSelection
    let kind: AcousticPlotKind
    let profile: ProfileIdentity

    init?(_ index: AcousticPlotIndex, in data: AcousticPlotData, shareSupport: Bool = false) {
        guard let cursor = data.cursor(for: index),
            let support = data.contributingSelection(for: index)
        else { return nil }
        self.index = index
        self.cursor = cursor
        self.support = support
        shared = shareSupport ? support : cursor
        kind = data.kind
        profile = data.profile
    }

    func matches(_ selection: VisualizationSelection, in data: AcousticPlotData) -> Bool {
        shared == selection && kind == data.kind && profile == data.profile
            && data.cursor(for: index) == cursor
            && data.contributingSelection(for: index) == support
    }
}

/// A fixed-history plot for a single acoustic series. Bind the same selection to multiple
/// plots on the same source clock. Preparing snapshots never starts an analysis or audio session.
public struct AcousticPlotView: View {
    public let data: AcousticPlotData
    @Binding private var selection: VisualizationSelection?
    private let target: AcousticPersonalTargetOverlay?
    private var cursorChanged: ((VisualizationSelection?) -> Void)?
    @State private var zoom = false
    @State private var includeZero = false
    @State private var envelope = true
    @State private var bin = 0
    @State private var initialLocalFocus: AcousticPlotInspection?
    @State private var lastInspected: AcousticPlotInspection?
    @State private var showTarget = true
    @State private var zoomCenter: Double?

    public init(
        _ data: AcousticPlotData, selection: Binding<VisualizationSelection?>,
        personalTarget: AcousticPersonalTargetOverlay? = nil,
        initialInspection: AcousticPlotIndex? = nil
    ) {
        self.data = data
        let initial = initialInspection.flatMap { AcousticPlotInspection($0, in: data) }
        _initialLocalFocus = State(initialValue: selection.wrappedValue == nil ? initial : nil)
        _lastInspected = State(initialValue: initial)
        _bin = State(initialValue: initial?.index.bin ?? 0)
        _selection = selection
        target = personalTarget.flatMap { $0.applies(to: data) ? $0 : nil }
    }

    func reportingCursor(_ changed: @escaping (VisualizationSelection?) -> Void) -> Self {
        var copy = self
        copy.cursorChanged = changed
        return copy
    }

    var active: AcousticPlotIndex? {
        guard !data.columns.isEmpty else { return nil }
        let validBin = min(max(0, bin), data.binCount - 1)
        if let selection {
            if let lastInspected, lastInspected.matches(selection, in: data) {
                return lastInspected.index
            }
            return data.inspect(selection, bin: validBin)
        }
        if let initialLocalFocus, initialLocalFocus.matches(initialLocalFocus.shared, in: data) {
            return initialLocalFocus.index
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
                    plotToggle("Personal target", isOn: $showTarget)
                    if showTarget, visibleTargetSpan != nil {
                        Text("Calibrated target for the selected-interval CPPS median").font(
                            .caption)
                        Label(target.intervalDescription, systemImage: "line.diagonal")
                        Text("Policy state · \(target.state.text)")
                        Text(
                            "Policy reasons · "
                                + target.reasonText
                        ).font(.caption)
                        Text(
                            "Target support \(target.source.startSample)..<\(target.source.endSample) samples"
                        )
                        Text("Personal target identity \(target.target.sha256)").font(
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
        .onChange(of: cursorChanged == nil ? nil : active.flatMap(data.cursor(for:)), initial: true)
        {
            _, cursor in cursorChanged?(cursor)
        }
        .onChange(of: selection) { initialLocalFocus = nil }
    }

    private var visibleTargetSpan: ClosedRange<Double>? {
        target?.visibleSpan(on: data.timeAxis, in: horizontal.bounds)
    }

    private var plotArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(tick(vertical.bounds.upperBound))
                    Spacer()
                    Text(tick(vertical.bounds.lowerBound))
                }
                .padding(.bottom, 10)
                .frame(height: 154)
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        AcousticPlotDrawing(
                            data: data, horizontal: horizontal, vertical: vertical,
                            selection: selection, focused: active, envelope: envelope
                        )
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            selectPoint(location, size: proxy.size)
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8).onEnded { gesture in
                                if abs(gesture.translation.width) > abs(gesture.translation.height)
                                {
                                    selectInterval(
                                        from: gesture.startLocation, to: gesture.location,
                                        size: proxy.size)
                                }
                            }
                        )
                        .clipped()
                    }.frame(height: 154)
                    if showTarget, let span = visibleTargetSpan {
                        GeometryReader { proxy in
                            let width = max(1, proxy.size.width - 8)
                            let low = horizontal.fraction(span.lowerBound) * width
                            let high = horizontal.fraction(span.upperBound) * width
                            Capsule().fill(.purple).frame(width: max(2, high - low), height: 3)
                                .offset(x: 4 + low, y: 2)
                        }.frame(height: 7)
                        Text("Evaluated feedback interval").font(.caption2)
                    }
                    HStack {
                        Text(tick(horizontal.bounds.lowerBound))
                        Spacer()
                        Text(tick(horizontal.bounds.upperBound))
                    }
                    .padding(.horizontal, 4).font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
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
            plotToggle("Include zero", isOn: $includeZero)
        }
        if data.kind == .waveform { plotToggle("Min/max envelope", isOn: $envelope) }
    }

    private func plotToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: isOn.wrappedValue ? "checkmark.square" : "square")
        }
        .toggleStyle(.button)
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
            if let active, let focus = AcousticPlotInspection(active, in: data, shareSupport: true)
            {
                lastInspected = focus
                selection = focus.shared
            }
        }.disabled(active == nil)
        Button("Clear selection", systemImage: "xmark.circle") {
            initialLocalFocus = nil
            selection = nil
            lastInspected = nil
        }.disabled(selection == nil && initialLocalFocus == nil)
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

    private func selectInterval(from start: CGPoint, to end: CGPoint, size: CGSize) {
        guard size.width > 0, data.kind != .spectrum else { return }
        let from = horizontal.value((start.x - 4) / max(1, size.width - 8))
        let to = horizontal.value((end.x - 4) / max(1, size.width - 8))
        guard let interval = data.selection(fromSeconds: from, toSeconds: to) else { return }
        selection = interval
        initialLocalFocus = nil
        lastInspected = nil
    }

    private func selectPoint(_ location: CGPoint, size: CGSize) {
        let x = horizontal.value((location.x - 4) / max(1, size.width - 8))
        let geometry = AcousticPlotVerticalGeometry(scale: vertical, viewHeight: size.height)
        let ordinate = geometry.value(at: location.y)
        guard let index = data.nearestIndex(x: x, ordinate: ordinate) else { return }
        if data.kind == .waveform || data.kind == .spectrum {
            inspect(index)
            return
        }
        guard let cursor = data.cursor(atSeconds: x) else { return }
        let match: AcousticPlotIndex?
        if case .metric = data.kind {
            match = data.scalarIndex(for: cursor, center: x, tap: (location.y, geometry))
        } else {
            match = data.inspect(cursor, bin: index.bin)
        }
        if let match {
            inspect(match)
        } else {
            selection = cursor
            lastInspected = nil
        }
    }

    private func inspect(_ index: AcousticPlotIndex) {
        guard let focus = AcousticPlotInspection(index, in: data) else { return }
        initialLocalFocus = nil
        bin = index.bin
        lastInspected = focus
        selection = focus.shared
        if zoom, let x = data.coordinate(of: index), !horizontal.bounds.contains(x) {
            zoomCenter = x
        }
    }

    @ViewBuilder private func readout(_ index: AcousticPlotIndex) -> some View {
        let column = data.columns[index.column]
        VStack(alignment: .leading, spacing: 6) {
            if case .metric(let point) = column {
                VisualizationMeasurementReadout(point.measurement)
                    .labeledContentStyle(AcousticReadoutFieldStyle())
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
            if case .metric(let point) = column,
                point.observationWindow != point.measurement.result.timing.source
            {
                Text(
                    "Local analysis samples \(point.observationWindow.startSample)..<\(point.observationWindow.endSample)"
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

private struct AcousticReadoutFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                configuration.label.fixedSize()
                configuration.content.fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                configuration.label.font(.caption).foregroundStyle(.secondary)
                configuration.content.fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
