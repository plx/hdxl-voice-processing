import Foundation

/// The fit retains only prepared coordinates and reusable work arrays. Each new row overwrites
/// the active prefix with qualifying bins, so gaps and zero-weight observations stay excluded.
final class SpectralShapeRegression {
    private struct Point {
        var weight = 0.0
        var x = 0.0
        var y = 0.0
    }
    private let bins: Range<Int>
    private let coordinate: [Double]
    private let step: Double
    private let configuration: SpectralShapeProfile
    private var points: [Point]

    init(range: Range<Int>, configuration: SpectralShapeProfile, step: Double) {
        self.bins = range
        self.configuration = configuration
        self.step = step
        // In linear fits work in bin units, then convert the fitted slope to dB/Hz.
        // A constant coordinate offset also cancels from a log-frequency slope.
        coordinate = range.map {
            configuration.fitCoordinate == .hertz ? Double($0) : log2(Double($0))
        }
        points = .init(repeating: Point(), count: range.count)
    }

    func fit(_ powers: UnsafeBufferPointer<Double>, unavailable: UnavailabilityReason?)
        -> (MeasurementOutcome, SpectralSlopeFit)
    {
        var fit = SpectralSlopeFit()
        fit.candidateBins = bins.count
        if let unavailable { return (.unavailable(unavailable), fit) }
        guard bins.count > 0 else { return (.unavailable(.insufficientData), fit) }
        let peak = powers[bins].max() ?? 0
        guard peak > 0 else { return (.unavailable(.silence), fit) }
        let peakDB = 10 * log10(peak)
        let weights = SpectralShapeWeights(peak: peak, configuration: configuration)
        let floor = configuration.relativeLogFloorDB
        let reference = coordinate[0]
        var total = LevelCompensatedSum()
        var xs = LevelCompensatedSum()
        var ys = LevelCompensatedSum()
        for k in bins {
            let p = powers[k]
            if p == 0 && floor == nil { continue }
            let weight = configuration.regressionWeighting == .uniform ? 1 : weights.weight(p)
            guard weight > 0 else { continue }
            let relativeDB = p == 0 ? -Double.infinity : 10 * log10(p) - peakDB
            let level = max(relativeDB, floor ?? -.infinity)
            let x = coordinate[k - bins.lowerBound] - reference
            points[fit.usedBins] = Point(weight: weight, x: x, y: level)
            fit.usedBins += 1
            if level > relativeDB { fit.flooredBins += 1 }
            let frequency = Double(k) * step
            fit.firstFrequencyHz = fit.firstFrequencyHz ?? frequency
            fit.lastFrequencyHz = frequency
            total.add(weight)
            xs.add(weight * x)
            ys.add(weight * level)
        }
        guard fit.usedBins > 0 else { return (.unavailable(.insufficientData), fit) }
        let meanX = xs.value / total.value
        let meanY = ys.value / total.value
        fit.meanCoordinate =
            configuration.fitCoordinate == .hertz
            ? (reference + meanX) * step : reference + meanX + log2(step)
        fit.levelAtMeanCoordinateDB = peakDB + meanY
        guard fit.usedBins >= configuration.minimumFitBins else {
            return (.unavailable(.insufficientData), fit)
        }
        var xx = LevelCompensatedSum()
        var xy = LevelCompensatedSum()
        var yy = LevelCompensatedSum()
        for i in 0..<fit.usedBins {
            let point = points[i]
            let dx = point.x - meanX
            let dy = point.y - meanY
            xx.add(point.weight * dx * dx)
            xy.add(point.weight * dx * dy)
            yy.add(point.weight * dy * dy)
        }
        guard xx.value > 0 else { return (.unavailable(.insufficientData), fit) }
        let slope = xy.value / xx.value
        var error = LevelCompensatedSum()
        for i in 0..<fit.usedBins {
            let point = points[i]
            let residual = (point.y - meanY) - slope * (point.x - meanX)
            error.add(point.weight * residual * residual)
        }
        let rms = sqrt(error.value / total.value)
        guard rms.isFinite else { return (.unavailable(.analysisFailure), fit) }
        fit.residualRMSDB = rms
        if yy.value > 0 { fit.rSquared = max(0, min(1, 1 - error.value / yy.value)) }
        return (
            spectralShapeEstimate(configuration.fitCoordinate == .hertz ? slope / step : slope), fit
        )
    }
}
