import Foundation

/// Center the fit on a peak-power bin and scale the two weighted deviation vectors separately.
/// Raw square-root weights keep even the weakest positive Double power eligible for the fit.
final class SpectralShapeRegression {
    private struct Point {
        var rootWeight = 0.0
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
        // Work in bin units for a linear fit. Convert its slope to dB/Hz on output.
        coordinate = range.map {
            configuration.fitCoordinate == .hertz ? Double($0) : log2(Double($0))
        }
        points = .init(repeating: Point(), count: range.count)
    }

    private func rootWeight(_ power: Double) -> Double {
        if configuration.regressionWeighting == .uniform { return 1 }
        let root = sqrt(power)
        return configuration.weighting == .power ? root : sqrt(root)
    }

    func fit(_ powers: UnsafeBufferPointer<Double>, unavailable: UnavailabilityReason?)
        -> (MeasurementOutcome, SpectralSlopeFit)
    {
        var fit = SpectralSlopeFit()
        fit.candidateBins = bins.count
        if let unavailable { return (.unavailable(unavailable), fit) }
        guard var anchor = bins.first else { return (.unavailable(.insufficientData), fit) }
        for k in bins where powers[k] > powers[anchor] { anchor = k }
        let peak = powers[anchor]
        guard peak > 0 else { return (.unavailable(.silence), fit) }
        let peakDB = 10 * log10(peak)
        let rootPeak = rootWeight(peak)
        let floor = configuration.relativeLogFloorDB
        let reference = coordinate[anchor - bins.lowerBound]
        var total = LevelCompensatedSum()
        var xs = LevelCompensatedSum()
        var ys = LevelCompensatedSum()
        for k in bins {
            let p = powers[k]
            if p == 0 && (floor == nil || configuration.regressionWeighting == .shapeWeight) {
                continue
            }
            let relativeDB = p == 0 ? -Double.infinity : 10 * log10(p) - peakDB
            let level = max(relativeDB, floor ?? -.infinity)
            let x = coordinate[k - bins.lowerBound] - reference
            let root = rootWeight(p)
            points[fit.usedBins] = Point(rootWeight: root, x: x, y: level)
            fit.usedBins += 1
            if level > relativeDB { fit.flooredBins += 1 }
            let frequency = Double(k) * step
            fit.firstFrequencyHz = fit.firstFrequencyHz ?? frequency
            fit.lastFrequencyHz = frequency
            let relativeRoot = root / rootPeak
            total.add(relativeRoot * relativeRoot)
            xs.add(relativeRoot * (relativeRoot * x))
            ys.add(relativeRoot * (relativeRoot * level))
        }
        let meanX = xs.value / total.value
        let meanY = ys.value / total.value
        fit.meanCoordinate =
            configuration.fitCoordinate == .hertz
            ? (reference + meanX) * step : reference + meanX + log2(step)
        fit.levelAtMeanCoordinateDB = peakDB + meanY
        guard fit.usedBins >= configuration.minimumFitBins else {
            return (.unavailable(.insufficientData), fit)
        }

        var xScale = 0.0
        var yScale = 0.0
        for i in 0..<fit.usedBins {
            let point = points[i]
            points[i].x = point.rootWeight * (point.x - meanX)
            points[i].y = point.rootWeight * (point.y - meanY)
            xScale = max(xScale, abs(points[i].x))
            yScale = max(yScale, abs(points[i].y))
        }
        guard xScale > 0 else { return (.unavailable(.insufficientData), fit) }
        guard yScale > 0 else {
            fit.residualRMSDB = 0
            return (spectralShapeEstimate(0), fit)
        }
        var xx = LevelCompensatedSum()
        var xy = LevelCompensatedSum()
        var yy = LevelCompensatedSum()
        for i in 0..<fit.usedBins {
            let x = points[i].x / xScale
            let y = points[i].y / yScale
            xx.add(x * x)
            xy.add(x * y)
            yy.add(y * y)
        }
        let scaledSlope = xy.value / xx.value
        let slope = scaledSlope * (yScale / xScale)
        var error = LevelCompensatedSum()
        for i in 0..<fit.usedBins {
            let residual = (points[i].y / yScale).addingProduct(-scaledSlope, points[i].x / xScale)
            error.add(residual * residual)
        }
        fit.residualRMSDB = (yScale / rootPeak) * sqrt(error.value / total.value)
        fit.rSquared = max(0, min(1, 1 - error.value / yy.value))
        return (
            spectralShapeEstimate(configuration.fitCoordinate == .hertz ? slope / step : slope), fit
        )
    }
}
