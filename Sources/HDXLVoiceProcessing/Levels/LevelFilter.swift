import Foundation

/// Float64 transposed direct-form-II state; the reference oracle uses Decimal direct form I.
struct LevelBiquadState {
    let coefficients: LevelBiquadCoefficients
    var first = 0.0
    var second = 0.0

    mutating func process(_ input: Double, precisionLimited: inout Bool) throws -> Double {
        let c = coefficients
        let feed0 = c.b0 * input
        let output = feed0 + first
        let feed1 = c.b1 * input
        let feed2 = c.b2 * input
        let back1 = c.a1 * output
        let back2 = c.a2 * output
        let nextFirst = (feed1 - back1) + second
        let nextSecond = feed2 - back2
        guard output.isFinite, nextFirst.isFinite, nextSecond.isFinite else {
            throw LevelError.nonfiniteResult
        }
        if input.isSubnormal || first.isSubnormal || second.isSubnormal
            || feed0.isSubnormal || feed1.isSubnormal || feed2.isSubnormal
            || back1.isSubnormal || back2.isSubnormal || output.isSubnormal
            || nextFirst.isSubnormal || nextSecond.isSubnormal
            || (input != 0
                && ((c.b0 != 0 && feed0 == 0) || (c.b1 != 0 && feed1 == 0)
                    || (c.b2 != 0 && feed2 == 0)))
            || (output != 0 && ((c.a1 != 0 && back1 == 0) || (c.a2 != 0 && back2 == 0)))
        {
            precisionLimited = true
        }
        first = nextFirst
        second = nextSecond
        return output
    }
    mutating func reset() {
        first = 0
        second = 0
    }
}

struct LevelKFilter {
    var shelf: LevelBiquadState
    var highpass: LevelBiquadState
    private(set) var precisionLimited = false

    init(_ coefficients: KWeightingCoefficients) {
        shelf = LevelBiquadState(coefficients: coefficients.shelf)
        highpass = LevelBiquadState(coefficients: coefficients.highpass)
    }
    mutating func process(_ input: Double) throws -> Double {
        let first = try shelf.process(input, precisionLimited: &precisionLimited)
        return try highpass.process(first, precisionLimited: &precisionLimited)
    }
    mutating func reset() {
        shelf.reset()
        highpass.reset()
        precisionLimited = false
    }
}

struct LevelCompensatedSum {
    private var total = 0.0
    private var correction = 0.0
    private(set) var absoluteUpdates = 0.0
    private(set) var reliable = true

    var value: Double { total + correction }
    mutating func add(_ value: Double) {
        guard reliable else { return }
        let next = total + value
        if abs(total) >= abs(value) {
            correction += (total - next) + value
        } else {
            correction += (value - next) + total
        }
        total = next
        absoluteUpdates += abs(value)
        reliable = total.isFinite && correction.isFinite && absoluteUpdates.isFinite
    }
    var needsRebase: Bool {
        !reliable || !value.isFinite || value <= 32 * Double.ulpOfOne * absoluteUpdates
    }
}
