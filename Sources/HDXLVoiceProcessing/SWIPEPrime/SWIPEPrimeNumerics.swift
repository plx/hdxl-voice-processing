import Foundation

/// Owns initialized fixed-capacity storage even if later preparation throws.
final class SWIPEPrimeBuffer<Element> {
    let values: UnsafeMutableBufferPointer<Element>
    init(count: Int, repeating value: Element) {
        values = .allocate(capacity: count)
        values.initialize(repeating: value)
    }
    deinit {
        values.deinitialize()
        values.deallocate()
    }
    var borrowed: UnsafeBufferPointer<Element> { UnsafeBufferPointer(values) }
    var bytes: Int { values.count * MemoryLayout<Element>.stride }
}

/// Neumaier summation, independent of the Python oracle's math.fsum machinery.
struct SWIPEPrimeSum {
    private var sum = 0.0
    private var correction = 0.0
    mutating func add(_ value: Double) {
        let next = sum + value
        correction += abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
        sum = next
    }
    var value: Double { sum + correction }
}

enum SWIPEPrimeNumerics {
    static func harmonicLobe(ratio: Double, harmonic: Int) -> Double {
        let displacement = ratio - Double(harmonic)
        let distance = abs(displacement)
        if distance == 0.25 || distance >= 0.75 { return 0 }
        return (distance < 0.25 ? 1 : 0.5) * cos(2 * .pi * displacement)
    }

    static func prepareKernels(layout: SWIPEPrimeLayout) throws -> SWIPEPrimeBuffer<Double> {
        let maximumHarmonic = Int(
            floor(layout.erbFrequenciesHz.last! / layout.candidateFrequenciesHz[0] + 0.75))
        var included = Array(repeating: true, count: maximumHarmonic + 1)
        included[0] = false
        if maximumHarmonic >= 4 {
            for divisor in 2...Int(sqrt(Double(maximumHarmonic))) where included[divisor] {
                for composite in stride(
                    from: divisor * divisor, through: maximumHarmonic, by: divisor)
                {
                    included[composite] = false
                }
            }
        }
        // One is included deliberately alongside the primes.
        let erbCount = layout.erbFrequenciesHz.count
        let result = SWIPEPrimeBuffer(
            count: layout.candidateFrequenciesHz.count * erbCount, repeating: 0.0)
        for candidate in layout.candidateFrequenciesHz.indices {
            let pitch = layout.candidateFrequenciesHz[candidate]
            let offset = candidate * erbCount
            var norm = SWIPEPrimeSum()
            for bin in layout.erbFrequenciesHz.indices {
                let frequency = layout.erbFrequenciesHz[bin]
                guard frequency > 0 else { continue }
                let ratio = frequency / pitch
                let lower = Int(floor(ratio))
                var component = 0.0
                for harmonic in lower...(lower + 1)
                where harmonic <= maximumHarmonic && included[harmonic] {
                    component += harmonicLobe(ratio: ratio, harmonic: harmonic)
                }
                let coefficient = component / sqrt(frequency)
                result.values[offset + bin] = coefficient
                if coefficient > 0 { norm.add(coefficient * coefficient) }
            }
            let scale = sqrt(norm.value)
            guard scale.isFinite, scale > 0 else { throw SWIPEPrimeError.invalidConfiguration }
            for bin in 0..<erbCount { result.values[offset + bin] /= scale }
        }
        return result
    }

    /// Centered nonuniform-period quadratic; the oracle uses Newton divided
    /// differences instead. Strict local maxima only, with a vertex in the
    /// neighboring period interval. Ties and endpoints retain the discrete value.
    static func refine(
        frequencies: [Double], strengths: UnsafeBufferPointer<Double?>, selected: Int,
        threshold: Double
    ) -> SWIPEPrimeObservation {
        let frequency = frequencies[selected]
        let discrete = strengths[selected]!
        var pitch = frequency
        var strength = discrete
        var refined = false
        if selected > 0, selected + 1 < frequencies.count,
            let left = strengths[selected - 1], let right = strengths[selected + 1],
            discrete > left, discrete > right
        {
            let xLeft = frequency / frequencies[selected - 1] - 1
            let xRight = frequency / frequencies[selected + 1] - 1
            let leftSlope = (left - discrete) / xLeft
            let rightSlope = (right - discrete) / xRight
            let quadratic = (leftSlope - rightSlope) / (xLeft - xRight)
            let linear = leftSlope - quadratic * xLeft
            if quadratic < 0 {
                let offset = -linear / (2 * quadratic)
                let ordinate = discrete + linear * offset + quadratic * offset * offset
                if offset.isFinite, ordinate.isFinite, (xRight...xLeft).contains(offset) {
                    pitch = frequency / (1 + offset)
                    strength = ordinate
                    refined = true
                }
            }
        }
        return SWIPEPrimeObservation(
            candidateIndex: selected, discreteFrequencyHz: frequency, frequencyHz: pitch,
            discretePitchStrength: discrete, pitchStrength: strength, isRefined: refined,
            isThresholdQualified: strength >= threshold)
    }
}
