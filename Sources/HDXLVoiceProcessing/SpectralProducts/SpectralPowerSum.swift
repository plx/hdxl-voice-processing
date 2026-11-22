/// Positive weighted sum stored relative to its largest observed bin power.
/// The normalized sum is at most the total integer weight. Scaling precedes the
/// division so subnormal contributions can accumulate before rounding the output.
struct SpectralPowerSum {
    private var scale = 0.0
    private var sum = 0.0
    private var roundingError = 0.0

    mutating func add(_ power: Double, weight: Double) {
        guard power > 0 else { return }
        if power > scale {
            let ratio = scale / power
            sum *= ratio
            roundingError *= ratio
            scale = power
        }
        let term = (power / scale) * weight
        let adjusted = term - roundingError
        let next = sum + adjusted
        roundingError = (next - sum) - adjusted
        sum = next
    }

    func mean(weight: Double) -> Double? {
        guard scale > 0 else { return 0 }
        let result = scale * min(1, (sum - roundingError) / weight)
        return result > 0 ? result : nil
    }

    static func means(_ sums: [Self], weight: Int64) -> [Double]? {
        precondition(weight > 0)
        var result: [Double] = []
        result.reserveCapacity(sums.count)
        let denominator = Double(weight)
        for bin in sums {
            guard let value = bin.mean(weight: denominator) else { return nil }
            result.append(value)
        }
        return result
    }
}
