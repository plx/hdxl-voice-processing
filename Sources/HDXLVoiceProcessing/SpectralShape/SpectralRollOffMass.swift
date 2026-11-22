/// Exact nonnegative sums for the discontinuous roll-off comparison. One unit is 2⁻¹⁰⁷⁴,
/// the smallest positive binary64 value. A finite weight takes at most 2098 bits, the FFT
/// bin count adds at most 22, and multiplying by a fraction's significand adds at most 53.
/// All three fit in 35 inline words. No heap storage scales with the number of bins.
struct SpectralRollOffMass {
    private var words: [35 of UInt64] = .init(repeating: 0)
    private var highest = -1

    /// value = significand × 2^(shift − 1074), also for subnormal weights.
    private static func parts(_ value: Double) -> (significand: UInt64, shift: Int) {
        let exponent = Int(value.exponentBitPattern)
        if exponent == 0 { return (value.significandBitPattern, 0) }
        return (value.significandBitPattern | (1 << 52), exponent - 1)
    }

    private mutating func addWord(_ word: UInt64, at index: Int) {
        var carry = word
        var i = index
        while carry != 0 {
            let addition = words[i].addingReportingOverflow(carry)
            words[i] = addition.partialValue
            highest = max(highest, i)
            carry = addition.overflow ? 1 : 0
            i += 1
        }
    }

    mutating func add(_ weight: Double) {
        guard weight > 0 else { return }
        let (value, shift) = Self.parts(weight)
        let i = shift / 64
        let bits = shift % 64
        addWord(value << bits, at: i)
        if bits > 0 { addWord(value >> (64 - bits), at: i + 1) }
    }

    /// Cumulative integer mass reaches a fractional cutoff exactly when it reaches ceil(q × total).
    func threshold(fraction: Double) -> Self {
        guard highest >= 0 else { return self }
        let (multiplier, shift) = Self.parts(fraction)
        var product = self
        var carry: UInt64 = 0
        for i in 0...highest {
            let wide = words[i].multipliedFullWidth(by: multiplier)
            let addition = wide.low.addingReportingOverflow(carry)
            product.words[i] = addition.partialValue
            carry = wide.high + (addition.overflow ? 1 : 0)
        }
        if carry != 0 { product.addWord(carry, at: highest + 1) }

        let rightShift = 1074 - shift
        let low = rightShift / 64
        let bits = rightShift % 64
        var remainder = false
        for i in 0..<min(low, product.highest + 1) where product.words[i] != 0 { remainder = true }
        var result = Self()
        if low <= product.highest {
            if bits > 0 && product.words[low] & ((1 << bits) - 1) != 0 { remainder = true }
            for i in low...product.highest {
                var word = product.words[i] >> bits
                if bits > 0 && i < product.highest { word |= product.words[i + 1] << (64 - bits) }
                if word != 0 {
                    result.words[i - low] = word
                    result.highest = i - low
                }
            }
        }
        if remainder { result.addWord(1, at: 0) }
        return result
    }

    func reaches(_ threshold: borrowing Self) -> Bool {
        if highest != threshold.highest { return highest > threshold.highest }
        for i in stride(from: highest, through: 0, by: -1) where words[i] != threshold.words[i] {
            return words[i] > threshold.words[i]
        }
        return true
    }
}
