import Foundation

public enum HNRDecibelStatus: String, Sendable, Hashable, Codable {
    case finite, lowerReportingLimit, upperReportingLimit, numericalZeroNoise
}

/// A correlation-derived estimate, not a physical signal-to-noise measurement.
/// Exact numerical unity is explicit and does not establish physical noise absence.
/// The reference's capped presentation and the uncapped finite estimate are separate.
public struct HNRPeriodicityEstimate: Sendable, Hashable {
    public let unreflectedCorrelation: Double
    public let wasReflected: Bool
    public let periodicity: Double
    public let noiseFraction: Double
    public let status: HNRDecibelStatus
    public let finiteDecibels: Double?
    public let referenceReportingDecibels: Double

    public init(unreflectedCorrelation: Double) throws {
        guard unreflectedCorrelation.isFinite, unreflectedCorrelation > 0 else {
            throw HNRError.numericalFailure
        }
        let reflected = unreflectedCorrelation > 1
        let r = reflected ? 1 / unreflectedCorrelation : unreflectedCorrelation
        self.unreflectedCorrelation = unreflectedCorrelation
        self.wasReflected = reflected
        self.periodicity = r
        self.noiseFraction = 1 - r
        if r == 1 {
            status = .numericalZeroNoise
            finiteDecibels = nil
            referenceReportingDecibels = 150
        } else {
            let db = 10 / log(10) * (log(r) - log1p(-r))
            guard db.isFinite else { throw HNRError.numericalFailure }
            finiteDecibels = db
            if r <= 1e-15 {
                status = .lowerReportingLimit
                referenceReportingDecibels = -150
            } else if r > 1 - 1e-15 {
                status = .upperReportingLimit
                referenceReportingDecibels = 150
            } else {
                status = .finite
                referenceReportingDecibels = db
            }
        }
    }
}

/// Compensated accumulation is independent of the oracle's math.fsum path.
package struct HNRSum {
    private var total = 0.0
    private var correction = 0.0
    package var value: Double { total + correction }
    package mutating func add(_ term: Double) {
        let next = total + term
        correction += abs(total) >= abs(term) ? (total - next) + term : (term - next) + total
        total = next
    }
}

package enum HNRPeakKind {
    case notLocalMaximum, numericallyFlat, resolved
}

package enum HNRNumerics {
    package static func gaussian(index: Int, count: Int) -> Double {
        let coordinate = Double(2 * index + 1 - count) / Double(count + 1)
        let edge = exp(-12.0)
        return (exp(-12 * coordinate * coordinate) - edge) / (1 - edge)
    }

    package static func peakKind(left: Double, middle: Double, right: Double) -> HNRPeakKind {
        guard middle > 0, middle > left, middle >= right else { return .notLocalMaximum }
        return (middle - left) + (middle - right) > 128 * Double.ulpOfOne
            ? .resolved : .numericallyFlat
    }

    /// Finite even lag curve. Undefined cells are represented separately; they
    /// cannot become zero-valued observations or candidates through interpolation.
    package static func sinc(
        _ values: UnsafeBufferPointer<Double>, valid: UnsafeBufferPointer<Bool>,
        position: Double, depth requested: Int
    ) -> Double? {
        let radius = values.count - 1
        guard valid.count == values.count, radius >= 0, position.isFinite,
            position >= -Double(radius), position <= Double(radius), requested >= 1
        else { return nil }
        let left = Int(floor(position))
        func sample(_ index: Int) -> Double? {
            valid[abs(index)] ? values[abs(index)] : nil
        }
        if position == Double(left) { return sample(left) }
        let depth = min(requested, left + radius + 1, radius - left)
        let fraction = position - Double(left)
        if depth == 1 {
            guard let a = sample(left), let b = sample(left + 1) else { return nil }
            return a + (b - a) * fraction
        }
        if depth == 2 {
            guard let a = sample(left - 1), let b = sample(left),
                let c = sample(left + 1), let d = sample(left + 2)
            else { return nil }
            let low = (c - a) / 2
            let high = (d - b) / 2
            let u = fraction
            return (2 * u * u * u - 3 * u * u + 1) * b + (u * u * u - 2 * u * u + u) * low
                + (-2 * u * u * u + 3 * u * u) * c + (u * u * u - u * u) * high
        }
        // sin(pi*(u+k)) alternates sign. A cosine/sine angle recurrence removes
        // per-cell transcendental calls without importing a reference kernel.
        let step = Double.pi / (Double(depth) + 0.5)
        let stepCosine = cos(step)
        let stepSine = sin(step)
        var lowCosine = cos(step * fraction)
        var lowSine = sin(step * fraction)
        var highCosine = cos(step * (1 - fraction))
        var highSine = sin(step * (1 - fraction))
        // Fold near pi back toward zero before division by the small right-hand
        // distance. Otherwise sin(pi*u)'s absolute error is amplified as u -> 1.
        var numerator = sin(Double.pi * min(fraction, 1 - fraction)) / Double.pi
        var result = HNRSum()
        for k in 0..<depth {
            guard let a = sample(left - k), let b = sample(left + 1 + k) else { return nil }
            result.add(a * numerator / (fraction + Double(k)) * (1 + lowCosine) / 2)
            result.add(b * numerator / (1 - fraction + Double(k)) * (1 + highCosine) / 2)
            let nextLowCosine = lowCosine * stepCosine - lowSine * stepSine
            lowSine = lowSine * stepCosine + lowCosine * stepSine
            lowCosine = nextLowCosine
            let nextHighCosine = highCosine * stepCosine - highSine * stepSine
            highSine = highSine * stepCosine + highCosine * stepSine
            highCosine = nextHighCosine
            numerator = -numerator
        }
        return result.value.isFinite ? result.value : nil
    }

    package static func maximum(
        _ values: UnsafeBufferPointer<Double>, valid: UnsafeBufferPointer<Bool>, integerLag: Int
    ) -> (lag: Double, correlation: Double)? {
        guard integerLag >= 1, integerLag < values.count - 1 else { return nil }
        var a = Double(integerLag - 1)
        var b = Double(integerLag + 1)
        let ratio = (sqrt(5.0) - 1) / 2
        var left = b - ratio * (b - a)
        var right = a + ratio * (b - a)
        guard var low = sinc(values, valid: valid, position: left, depth: 700),
            var high = sinc(values, valid: valid, position: right, depth: 700)
        else { return nil }
        for _ in 0..<60 {
            if low > high {
                b = right
                right = left
                high = low
                left = b - ratio * (b - a)
                guard let value = sinc(values, valid: valid, position: left, depth: 700) else {
                    return nil
                }
                low = value
            } else {
                a = left
                left = right
                low = high
                right = a + ratio * (b - a)
                guard let value = sinc(values, valid: valid, position: right, depth: 700) else {
                    return nil
                }
                high = value
            }
        }
        guard let original = sinc(values, valid: valid, position: Double(integerLag), depth: 700),
            let middle = sinc(values, valid: valid, position: (a + b) / 2, depth: 700)
        else { return nil }
        var best = (lag: Double(integerLag), correlation: original)
        // Explicit scalar comparisons preserve the larger-position tie rule and
        // avoid allocating a temporary candidate array on the prepared hot path.
        func choose(_ lag: Double, _ correlation: Double) {
            if correlation > best.correlation || (correlation == best.correlation && lag > best.lag)
            {
                best = (lag, correlation)
            }
        }
        choose(left, low)
        choose(right, high)
        choose((a + b) / 2, middle)
        return best
    }
}
