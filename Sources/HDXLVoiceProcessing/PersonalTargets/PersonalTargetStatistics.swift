import Foundation

/// Inclusive raw-unit bounds. A zero-width interval is explicit and does not
/// acquire an undocumented epsilon or widen after seeing evaluation examples.
public struct PersonalTargetInterval: Sendable, Hashable, Encodable {
    public let lower: Double
    public let upper: Double

    init(lower: Double, upper: Double) throws {
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            throw PersonalTargetError.invalidObservation
        }
        self.lower = lower == 0 ? 0 : lower
        self.upper = upper == 0 ? 0 : upper
    }

    public func contains(_ value: Double) -> Bool {
        value.isFinite && lower <= value && value <= upper
    }
}

public struct PersonalTargetDistribution: Sendable, Hashable, Encodable {
    public let count: Int
    public let minimum: Double
    public let lowerQuartile: Double
    public let median: Double
    public let upperQuartile: Double
    public let maximum: Double

    init(_ values: [Double]) throws {
        guard !values.isEmpty, values.count <= CalibrationRecordLimits.maximumTakes,
            values.allSatisfy(\.isFinite)
        else { throw PersonalTargetError.invalidObservation }
        let sorted = values.sorted()
        count = sorted.count
        minimum = sorted[0]
        maximum = sorted[sorted.count - 1]
        func q(_ fraction: Double) -> Double {
            sorted[max(0, Int(ceil(fraction * Double(sorted.count))) - 1)]
        }
        lowerQuartile = q(0.25)
        median = q(0.5)
        upperQuartile = q(0.75)
    }

    var extent: PersonalTargetInterval {
        // Construction already checked finite, ordered values.
        try! PersonalTargetInterval(lower: minimum, upper: maximum)
    }

    func preferredInterval(multiplier: Double, support: PersonalTargetInterval) throws
        -> PersonalTargetInterval
    {
        let width = upperQuartile - lowerQuartile
        let margin = multiplier * width
        let low = lowerQuartile - margin
        let high = upperQuartile + margin
        guard width.isFinite, margin.isFinite, low.isFinite, high.isFinite else {
            throw PersonalTargetError.invalidObservation
        }
        return try PersonalTargetInterval(
            lower: max(low, support.lower), upper: min(high, support.upper))
    }
}

/// A conditional 95% Wilson interval for independent Bernoulli acquisition-group
/// outcomes. Correlation within people/sessions can invalidate that assumption.
/// It is descriptive, is not an activation gate, and is not a population-voice CI.
public struct PersonalTargetConditionalInterval: Sendable, Hashable, Encodable {
    public let successes: Int
    public let trials: Int
    public let lower: Double
    public let upper: Double
    public let assumption = "independent-acquisition-group-outcomes"

    init?(successes: Int, trials: Int) {
        guard trials > 0, successes >= 0, successes <= trials else { return nil }
        let n = Double(trials)
        let p = Double(successes) / n
        let z = 1.959963984540054
        let z2 = z * z
        let denominator = 1 + z2 / n
        let center = (p + z2 / (2 * n)) / denominator
        let half = z * sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / denominator
        self.successes = successes
        self.trials = trials
        lower = max(0, center - half)
        upper = min(1, center + half)
    }
}
