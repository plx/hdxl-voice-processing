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
        default:
            let half = (hopSeconds ?? 0) / 2
            var low = left - half
            var high = right + half
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
            sample = samplePosition(anchor: point.anchorSample, offset: point.secondsFromAnchor)
        }
        return sample.flatMap(cursor(atSample:))
    }

    private func samplePosition(anchor: Int64, offset: Double) -> Int64? {
        guard let delta = Int64(exactly: (offset * timeAxis.source.sampleRate).rounded()) else {
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
        guard let near = nearestIndex(x: x, ordinate: Double(bin) * binStep) else { return nil }
        let i = near.column
        if let hopSeconds {
            guard centers[i] + hopSeconds / 2 >= span.lowerSeconds,
                centers[i] - hopSeconds / 2 <= span.upperSeconds
            else { return nil }
        } else if !selection.intersects(columns[i].support) {
            guard cursor(for: near).map({ selection.intersects($0.source) }) == true else {
                return nil
            }
        }
        if selection.source.sampleCount == 0, columns[i].unavailability == nil,
            boundaries.contains(where: { $0.missingSource.map(selection.intersects) == true })
        {
            return nil
        }
        return near
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
