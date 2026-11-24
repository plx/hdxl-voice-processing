import Foundation
import HDXLVoiceProcessing

public struct AcousticPlotIndex: Sendable, Hashable {
    public let column: Int
    public let bin: Int
    public init(column: Int, bin: Int) {
        self.column = column
        self.bin = bin
    }
}

/// Linear coordinates with finite interpolation across even the full finite Double range.
struct AcousticPlotScale {
    let bounds: ClosedRange<Double>

    /// Keep a constant or numerically near-constant series legible at the displayed precision.
    static func displayBounds(for range: ClosedRange<Double>) -> ClosedRange<Double> {
        let magnitude = max(abs(range.lowerBound), abs(range.upperBound))
        let width = range.upperBound - range.lowerBound
        guard width <= magnitude * 1e-4 else { return range }
        let radius = magnitude == 0 ? 1 : max(magnitude * 0.001, magnitude.ulp)
        let low = max(-Double.greatestFiniteMagnitude, range.lowerBound - radius)
        let high = min(Double.greatestFiniteMagnitude, range.upperBound + radius)
        return low...high
    }

    func fraction(_ value: Double) -> Double {
        let low = bounds.lowerBound
        let high = bounds.upperBound
        guard low != high else { return 0.5 }
        if value <= low { return 0 }
        if value >= high { return 1 }
        let width = high - low
        if width.isFinite { return (value - low) / width }
        return (value / 2 - low / 2) / (high / 2 - low / 2)
    }

    func value(_ fraction: Double) -> Double {
        let f = min(1, max(0, fraction))
        let low = bounds.lowerBound
        let high = bounds.upperBound
        if low == high || f == 0 { return low }
        if f == 1 { return high }
        let width = high - low
        return width.isFinite ? low + width * f : low * (1 - f) + high * f
    }
}

/// Screen positions shared by Canvas and scalar hit-testing, including the missing-data lane.
struct AcousticPlotVerticalGeometry {
    let scale: AcousticPlotScale
    let viewHeight: Double
    let top = 4.0
    var height: Double { max(1, viewHeight - 18) }
    var missingY: Double { top + height + 6 }
    func y(_ value: Double?) -> Double {
        value.map { top + (1 - scale.fraction($0)) * height } ?? missingY
    }
    func value(at y: Double) -> Double { scale.value(1 - (y - top) / height) }
}

extension AcousticPlotData {
    /// Time coordinates are elapsed source seconds relative to the supplied sample origin.
    /// A spectrum uses Hz horizontally, a cepstrogram uses seconds vertically.
    public var horizontalRange: ClosedRange<Double>? {
        guard let first = columns.first, let left = centers.first, let right = centers.last else {
            return nil
        }
        switch kind {
        case .spectrum: return 0...(Double(binCount - 1) * binStep)
        case .waveform:
            guard let span = try? timeAxis.placement(of: first.support) else { return nil }
            return span.lowerSeconds...span.upperSeconds
        case .spectrogram, .cepstrogram:
            guard let first = imageCell(at: 0), let last = imageCell(at: columns.count - 1) else {
                return nil
            }
            return first.lowerBound...last.upperBound
        default:
            let half = (hopSeconds ?? 0) / 2
            var low = left - half
            var high = right + half
            if left == right {
                for column in columns {
                    guard case .metric(let point) = column else { continue }
                    if let query = point.perturbation, point.sampleAlignedQuery == nil,
                        let anchor = try? timeAxis.placement(of: point.dependency).lowerSeconds
                    {
                        low = min(low, anchor + query.bounds.lowerBound)
                        high = max(high, anchor + query.bounds.upperBound)
                    } else if let span = try? timeAxis.placement(
                        of: point.sampleAlignedQuery ?? point.observationWindow)
                    {
                        low = min(low, span.lowerSeconds)
                        high = max(high, span.upperSeconds)
                    }
                }
            }
            for boundary in boundaries {
                if let source = boundary.missingSource,
                    let span = try? timeAxis.placement(of: source)
                {
                    low = min(low, span.lowerSeconds)
                    high = max(high, span.upperSeconds)
                }
            }
            return low.isFinite && high.isFinite ? low...high : left...right
        }
    }

    public func coordinate(of index: AcousticPlotIndex) -> Double? {
        guard columns.indices.contains(index.column), (0..<binCount).contains(index.bin) else {
            return nil
        }
        switch kind {
        case .waveform:
            guard let start = try? timeAxis.placement(of: columns[0].support).lowerSeconds else {
                return nil
            }
            return start + Double(index.bin) * binStep
        case .spectrum: return Double(index.bin) * binStep
        default: return centers[index.column]
        }
    }

    /// Returns the source cursor for an original observation, preserving integer waveform positions.
    public func cursor(for index: AcousticPlotIndex) -> VisualizationSelection? {
        guard columns.indices.contains(index.column), (0..<binCount).contains(index.bin) else {
            return nil
        }
        let column = columns[index.column]
        let sample: Int64?
        switch column {
        case .waveform: sample = column.support.startSample + Int64(index.bin)
        case .spectral: sample = column.support.startSample + column.support.sampleCount / 2
        case .cepstral(let frame):
            sample = samplePosition(
                anchor: frame.context.origin.startSample,
                offset: frame.context.centerSecondsFromOrigin)
        case .metric(let point):
            if let support = point.midpointSupport {
                sample = support.startSample + support.sampleCount / 2
            } else {
                sample = samplePosition(anchor: point.anchorSample, offset: point.secondsFromAnchor)
            }
        }
        return sample.flatMap(cursor(atSample:))
    }

    /// The waveform readout is an individual acquired sample. Spectral bins and
    /// scalar estimates retain the complete contributing analysis interval.
    public func contributingSelection(for index: AcousticPlotIndex) -> VisualizationSelection? {
        guard columns.indices.contains(index.column), (0..<binCount).contains(index.bin) else {
            return nil
        }
        let source = columns[index.column].dependency
        guard kind == .waveform else { return .init(source: source) }
        return
            (try? SourceInterval(
                epoch: source.epoch, startSample: source.startSample + Int64(index.bin),
                sampleCount: 1, sampleRate: source.sampleRate)).map(VisualizationSelection.init)
    }

    /// Display cells use the smaller of the hop and the acquired spectral support.
    /// Adjacent partial or overlapping cells meet halfway between their centers.
    func imageCell(at index: Int) -> Range<Double>? {
        guard kind.isImage, centers.indices.contains(index), let hopSeconds else { return nil }
        let center = centers[index]
        var low = center - hopSeconds / 2
        var high = center + hopSeconds / 2
        func boundary(_ i: Int) -> (time: Double, consecutive: Bool) {
            let left: UInt64
            let right: UInt64
            let time: Double
            switch (columns[i], columns[i + 1]) {
            case (.spectral(let first, _), .spectral(let next, _)):
                left = first.info.frameIndex
                right = next.info.frameIndex
                let a = columns[i].support
                let b = columns[i + 1].support
                // Average the two window centers on the sample grid before converting to seconds.
                let offset =
                    Double(a.startSample - timeAxis.originSample)
                    + Double(b.startSample - a.startSample) / 2
                    + (Double(a.sampleCount) + Double(b.sampleCount)) / 4
                time = offset / timeAxis.source.sampleRate
            case (.cepstral(let a), .cepstral(let b)):
                left = a.context.frameIndex
                right = b.context.frameIndex
                time = centers[i] + (centers[i + 1] - centers[i]) / 2
            default: preconditionFailure("Image cells require spectral or cepstral columns")
            }
            return (time, right > left && right - left == 1)
        }
        if index > 0 {
            let edge = boundary(index - 1)
            low = edge.consecutive ? edge.time : max(low, edge.time)
        }
        if index + 1 < centers.count {
            let edge = boundary(index)
            high = edge.consecutive ? edge.time : min(high, edge.time)
        }
        if kind == .spectrogram, let support = try? timeAxis.placement(of: columns[index].support) {
            low = max(low, support.lowerSeconds)
            high = min(high, support.upperSeconds)
        }
        return low < high ? low..<high : nil
    }

    private func samplePosition(
        anchor: Int64, offset: Double, rounding: FloatingPointRoundingRule = .down
    ) -> Int64? {
        let product = offset * timeAxis.source.sampleRate
        let integer = product.rounded()
        let sample =
            offset == integer / timeAxis.source.sampleRate ? integer : product.rounded(rounding)
        guard let delta = Int64(exactly: sample)
        else {
            return nil
        }
        let sum = anchor.addingReportingOverflow(delta)
        return sum.overflow ? nil : sum.partialValue
    }

    private func cursor(atSample sample: Int64) -> VisualizationSelection? {
        guard
            let source = try? SourceInterval(
                epoch: timeAxis.source.epoch, startSample: sample,
                sampleCount: 0, sampleRate: timeAxis.source.sampleRate)
        else { return nil }
        return VisualizationSelection(source: source)
    }

    func cursor(atSeconds seconds: Double) -> VisualizationSelection? {
        samplePosition(anchor: timeAxis.originSample, offset: seconds).flatMap(cursor(atSample:))
    }

    /// Publish every sample touched by a drag, with an exclusive upper endpoint.
    func selection(fromSeconds first: Double, toSeconds last: Double) -> VisualizationSelection? {
        guard let start = samplePosition(anchor: timeAxis.originSample, offset: min(first, last)),
            let end = samplePosition(
                anchor: timeAxis.originSample, offset: max(first, last), rounding: .up),
            start >= 0, end >= start,
            let source = try? SourceInterval(
                epoch: timeAxis.source.epoch, startSample: start,
                sampleCount: end - start, sampleRate: timeAxis.source.sampleRate)
        else { return nil }
        return VisualizationSelection(source: source)
    }

    func nearestIndex(x: Double, ordinate: Double) -> AcousticPlotIndex? {
        guard !columns.isEmpty else { return nil }
        func nearestBin(_ coordinate: Double) -> Int {
            let offset = min(Double(binCount - 1), max(0, (coordinate / binStep).rounded()))
            return Int(offset)
        }
        switch kind {
        case .waveform:
            guard let lower = try? timeAxis.placement(of: columns[0].support).lowerSeconds else {
                return nil
            }
            return AcousticPlotIndex(column: 0, bin: nearestBin(x - lower))
        case .spectrum: return AcousticPlotIndex(column: 0, bin: nearestBin(x))
        default:
            var low = 0
            var high = centers.count
            while low < high {
                let mid = low + (high - low) / 2
                if centers[mid] < x { low = mid + 1 } else { high = mid }
            }
            var i = min(low, centers.count - 1)
            if i > 0 && abs(centers[i - 1] - x) <= abs(centers[i] - x) { i -= 1 }
            return AcousticPlotIndex(column: i, bin: kind.isImage ? nearestBin(ordinate) : 0)
        }
    }

    /// A shared cursor in a hole does not silently inspect the nearest available value.
    public func inspect(_ selection: VisualizationSelection, bin: Int = 0) -> AcousticPlotIndex? {
        guard timeAxis.source.contains(selection.source), !columns.isEmpty,
            (0..<binCount).contains(bin),
            let span = try? timeAxis.placement(of: selection.source)
        else { return nil }
        if kind == .waveform {
            guard selection.intersects(columns[0].support) else { return nil }
            let first = max(selection.source.startSample, columns[0].support.startSample)
            let end = min(selection.source.endSample, columns[0].support.endSample)
            return AcousticPlotIndex(
                column: 0,
                bin: Int(first + max(0, end - first) / 2 - columns[0].support.startSample))
        }
        if kind == .spectrum {
            return selection.intersects(columns[0].support)
                ? AcousticPlotIndex(column: 0, bin: bin) : nil
        }
        let x = span.centerSeconds
        if case .metric = kind {
            return scalarIndex(for: selection, center: x)
        }
        var closest: Int?
        var distance = Double.infinity
        for i in centers.indices {
            guard let bounds = imageCell(at: i) else { continue }
            let overlaps =
                selection.source.sampleCount == 0
                ? bounds.contains(x)
                : span.lowerSeconds < bounds.upperBound && span.upperSeconds > bounds.lowerBound
            let candidate = abs(centers[i] - x)
            if overlaps && (closest == nil || candidate < distance) {
                closest = i
                distance = candidate
            }
        }
        return closest.map { .init(column: $0, bin: bin) }
    }

    /// A direct tap can disambiguate equal-center marks by their displayed ordinate.
    func scalarIndex(
        for selection: VisualizationSelection, center: Double,
        tap: (y: Double, geometry: AcousticPlotVerticalGeometry)? = nil
    )
        -> AcousticPlotIndex?
    {
        let acquired = acquiredPortions(of: selection)
        var closest: Int?
        var distance = Double.infinity
        var verticalDistance = Double.infinity
        for (i, column) in columns.enumerated() {
            guard case .metric(let point) = column else { continue }
            let portions = column.unavailability == nil ? acquired : [selection]
            let d = abs(centers[i] - center)
            let vertical = tap.map { abs($0.y - $0.geometry.y(column.value(at: 0))) } ?? 0
            guard closest == nil || d < distance || (d == distance && vertical < verticalDistance)
            else { continue }
            let index = AcousticPlotIndex(column: i, bin: 0)
            guard
                portions.contains(where: { portion in
                    if point.intersects(portion) { return true }
                    // An explicitly unavailable padded estimator may have a nominal center outside its input.
                    return column.unavailability != nil && point.perturbation == nil
                        && cursor(for: index).map { portion.intersects($0.source) } == true
                })
            else { continue }
            closest = i
            distance = d
            verticalDistance = vertical
        }
        return closest.map { .init(column: $0, bin: 0) }
    }

    func acquiredPortions(of selection: VisualizationSelection) -> [VisualizationSelection] {
        let gaps = boundaries.compactMap(\.missingSource).filter {
            $0.sampleCount > 0 && selection.intersects($0)
        }
        .sorted { $0.startSample < $1.startSample }
        guard !gaps.isEmpty else { return [selection] }
        let source = selection.source
        guard source.sampleCount > 0 else { return [] }
        var start = source.startSample
        var result: [VisualizationSelection] = []
        func append(until end: Int64) {
            if end > start,
                let piece = try? SourceInterval(
                    epoch: source.epoch, startSample: start, sampleCount: end - start,
                    sampleRate: source.sampleRate)
            {
                result.append(.init(source: piece))
            }
        }
        for gap in gaps where gap.sampleCount > 0 {
            append(until: max(start, gap.startSample))
            start = min(source.endSample, max(start, gap.endSample))
        }
        append(until: source.endSample)
        return result
    }

    /// Min/max of each consecutive source bucket. The raw sample indices and values survive.
    public func envelope(bins: Range<Int>, maximumBuckets: Int) throws -> [AcousticEnvelopeBucket] {
        guard kind == .waveform, bins.lowerBound >= 0, bins.upperBound <= binCount,
            maximumBuckets > 0,
            case .waveform(let frame) = columns.first
        else { throw VisualizationError.invalidConfiguration }
        guard !bins.isEmpty else { return [] }
        let width = 1 + (bins.count - 1) / maximumBuckets
        return stride(from: bins.lowerBound, to: bins.upperBound, by: width).map { first in
            let end = min(first + width, bins.upperBound)
            let values = frame.values[first..<end]
            return AcousticEnvelopeBucket(
                bins: first..<end, minimum: values.min()!, maximum: values.max()!)
        }
    }
}

public struct AcousticEnvelopeBucket: Sendable, Hashable {
    public let bins: Range<Int>
    public let minimum: Double
    public let maximum: Double
}
