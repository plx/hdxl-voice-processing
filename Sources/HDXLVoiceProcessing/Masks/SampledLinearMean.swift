/// Integrate a piecewise-linear curve in sample-index coordinates. End samples
/// have constant half-cell caps, clipped by the declared domain. This is an
/// original quadrature implementation shared by centered spectral operations;
/// it is not a count-based moving average or a copied reference implementation.
/// Values may be supplied from a ring, avoiding temporary contiguous windows.
func sampledLinearMean(
    count: Int, lower: Double, upper: Double,
    domainLower: Double, domainUpper: Double, value: (Int) -> Double
) -> Double? {
    guard count > 0, lower.isFinite, upper.isFinite, domainLower.isFinite,
        domainUpper.isFinite
    else { return nil }
    let left = max(lower, domainLower, -0.5)
    let right = min(upper, domainUpper, Double(count) - 0.5)
    guard left < right else { return nil }
    let span = right - left
    var sum = 0.0
    var correction = 0.0
    func add(_ contribution: Double) {
        let corrected = contribution - correction
        let next = sum + corrected
        correction = (next - sum) - corrected
        sum = next
    }
    if left < 0 { add((min(right, 0) - left) / span * value(0)) }
    var position = max(left, 0)
    let interiorEnd = min(right, Double(count - 1))
    if position < interiorEnd {
        var index = Int(position.rounded(.down))
        while position < interiorEnd {
            let end = min(interiorEnd, Double(index + 1))
            let fraction = (position - Double(index) + end - Double(index)) / 2
            let interpolated = (1 - fraction) * value(index) + fraction * value(index + 1)
            add((end - position) / span * interpolated)
            position = end
            index += 1
        }
    }
    if right > Double(count - 1) {
        add((right - max(left, Double(count - 1))) / span * value(count - 1))
    }
    return sum
}
