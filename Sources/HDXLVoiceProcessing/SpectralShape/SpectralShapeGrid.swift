import Foundation

/// All geometry is prepared once. No interpolation of the source FFT is performed.
struct SpectralShapeGrid {
    let step: Double
    let nyquist: Double
    let limit: Double
    let count: Int
    let startBin: Int

    init(layout: SpectrogramLayout, includeDC: Bool) {
        step = layout.frequency.step
        count = layout.frequency.count
        limit = layout.bandwidthHz
        nyquist = layout.framing.window.sampleRate / 2
        startBin = includeDC ? 0 : 1
    }

    private func firstBin(where predicate: (Int) -> Bool) -> Int {
        var lower = startBin
        var upper = count
        while lower < upper {
            let mid = lower + (upper - lower) / 2
            if predicate(mid) { upper = mid } else { lower = mid + 1 }
        }
        return lower
    }

    func centers(in band: SpectralFrequencyBand) -> Range<Int>? {
        guard band.upperHz <= limit else { return nil }
        return firstBin {
            Double($0) * step >= band.lowerHz
        }..<firstBin { Double($0) * step > band.upperHz }
    }

    private func left(_ bin: Int) -> Double { max(0, (Double(bin) - 0.5) * step) }
    private func right(_ bin: Int) -> Double { min(nyquist, (Double(bin) + 0.5) * step) }

    func cells(in band: SpectralFrequencyBand) -> SpectralBandCells? {
        // Beyond the last available cell, no stored source bin can supply the requested power.
        guard band.upperHz <= min(limit, right(count - 1)) else { return nil }
        let lower = firstBin { right($0) > band.lowerHz }
        let upper = firstBin { left($0) >= band.upperHz }
        let range = lower..<upper
        func overlap(_ k: Int) -> SpectralCellOverlap {
            let a = left(k)
            let b = right(k)
            return SpectralCellOverlap(
                width: min(b, band.upperHz) - max(a, band.lowerHz), cellWidth: b - a)
        }
        return SpectralBandCells(
            range: range, first: range.isEmpty ? .whole : overlap(lower),
            last: range.isEmpty ? .whole : overlap(upper - 1))
    }
}

struct SpectralCellOverlap {
    static let whole = Self(width: 1, cellWidth: 1)
    let fraction: Double
    let logFraction: Double

    init(width: Double, cellWidth: Double) {
        fraction = width / cellWidth
        logFraction = log(width) - log(cellWidth)
    }
}

struct SpectralBandCells {
    let range: Range<Int>
    let first: SpectralCellOverlap
    let last: SpectralCellOverlap

    func overlap(at index: Int) -> SpectralCellOverlap {
        if index == range.lowerBound { return first }
        if index == range.upperBound - 1 { return last }
        return .whole
    }
}
