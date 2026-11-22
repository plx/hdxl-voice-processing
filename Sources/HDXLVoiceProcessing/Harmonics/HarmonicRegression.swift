import Foundation

struct HarmonicRegression {
    let first: HarmonicAmplitude?
    let second: HarmonicAmplitude?
    let residual: Double
    let cycleVariation: Double
    let detectionFloor: Double

    /// Five columns: intercept and both quadratures of the first two harmonics. Normalize
    /// PCM before accumulating so the system is independent of the recording gain.
    static func fit<Sample: BinaryFloatingPoint>(
        _ samples: UnsafeBufferPointer<Sample>, rate: Int, frequency: Double
    ) throws -> Self {
        let n = samples.count
        let peak = samples.reduce(0.0) { max($0, abs(Double($1))) }
        guard peak > 0 else { throw HarmonicFailure.silence }
        let phaseStep = 2 * Double.pi * frequency / Double(rate)
        let hannStep = 2 * Double.pi / Double(n - 1)
        return try withUnsafeTemporaryAllocation(of: Double.self, capacity: 35) { workspace in
            let matrix = UnsafeMutableBufferPointer(rebasing: workspace[0..<30])
            let basis = UnsafeMutableBufferPointer(rebasing: workspace[30..<35])
            matrix.initialize(repeating: 0)
            func loadBasis(_ i: Int) {
                let phase = Double(i) * phaseStep
                let c = cos(phase)
                let s = sin(phase)
                basis[0] = 1
                basis[1] = c
                basis[2] = s
                basis[3] = c * c - s * s
                basis[4] = 2 * c * s
            }
            var sumW = 0.0
            var sumW2 = 0.0
            for i in 0..<n {
                loadBasis(i)
                let w = 0.5 - 0.5 * cos(Double(i) * hannStep)
                sumW += w
                sumW2 += w * w
                let y = Double(samples[i]) / peak
                for r in 0..<5 {
                    let factor = w * basis[r]
                    for col in r..<5 { matrix[r * 6 + col] += factor * basis[col] }
                    matrix[r * 6 + 5] += factor * y
                }
            }
            for r in 1..<5 {
                for col in 0..<r { matrix[r * 6 + col] = matrix[col * 6 + r] }
            }
            // Partial pivoting on the five-by-five normal system. The pivot guard is
            // relative to total window weight, particularly important near Nyquist.
            for k in 0..<5 {
                var pivot = k
                for r in (k + 1)..<5 where abs(matrix[r * 6 + k]) > abs(matrix[pivot * 6 + k]) {
                    pivot = r
                }
                guard abs(matrix[pivot * 6 + k]) > 1e-10 * sumW else {
                    throw HarmonicFailure.singularFit
                }
                if pivot != k {
                    for col in k..<6 { matrix.swapAt(k * 6 + col, pivot * 6 + col) }
                }
                let scale = matrix[k * 6 + k]
                for col in k..<6 { matrix[k * 6 + col] /= scale }
                for r in 0..<5 where r != k {
                    let factor = matrix[r * 6 + k]
                    for col in k..<6 { matrix[r * 6 + col] -= factor * matrix[k * 6 + col] }
                }
            }
            var sumError = 0.0
            for i in 0..<n {
                loadBasis(i)
                let w = 0.5 - 0.5 * cos(Double(i) * hannStep)
                var fitted = 0.0
                for k in 0..<5 { fitted += basis[k] * matrix[k * 6 + 5] }
                let e = Double(samples[i]) / peak - fitted
                sumError += w * e * e
            }
            let residual = sqrt(sumError / sumW)
            let effectiveSamples = sumW * sumW / sumW2
            // A stationary vowel can have a large residual from higher harmonics.
            // Estimate the non-repeating part by comparing one fractional period apart.
            let period = Double(rate) / frequency
            let lag = Int(ceil(period))
            let fraction = Double(lag) - period
            // A fractional delay also changes the magnitude of a stationary sampled
            // sinusoid. Subtract that predictable change before measuring cycle variation.
            func interpolationDrift(_ h: Int, cosine: Double, sine: Double) -> (Double, Double) {
                let theta = Double(h) * phaseStep
                let c =
                    (1 - fraction) * cos(theta * fraction) + fraction * cos(theta * (fraction - 1))
                let s =
                    (1 - fraction) * sin(theta * fraction) + fraction * sin(theta * (fraction - 1))
                return (cosine * (1 - c) + sine * s, sine * (1 - c) - cosine * s)
            }
            func coefficient(_ column: Int) -> Double { matrix[column * 6 + 5] }
            let firstDrift = interpolationDrift(1, cosine: coefficient(1), sine: coefficient(2))
            let secondDrift = interpolationDrift(2, cosine: coefficient(3), sine: coefficient(4))
            let comparisons = Int((Double(n) / period).rounded()) - 1
            var squaredDifference = 0.0
            var firstVariation = 0.0
            var secondVariation = 0.0
            for cycle in 0..<comparisons {
                let lower = lag + cycle * (n - lag) / comparisons
                let upper = lag + (cycle + 1) * (n - lag) / comparisons
                var c1 = 0.0
                var s1 = 0.0
                var c2 = 0.0
                var s2 = 0.0
                for i in lower..<upper {
                    let j = i - lag
                    let previous =
                        (1 - fraction) * (Double(samples[j]) / peak)
                        + fraction * (Double(samples[j + 1]) / peak)
                    let difference = Double(samples[i]) / peak - previous
                    squaredDifference += difference * difference
                    loadBasis(i)
                    let residualChange =
                        difference - firstDrift.0 * basis[1] - firstDrift.1 * basis[2]
                        - secondDrift.0 * basis[3] - secondDrift.1 * basis[4]
                    c1 += residualChange * basis[1]
                    s1 += residualChange * basis[2]
                    c2 += residualChange * basis[3]
                    s2 += residualChange * basis[4]
                }
                let count = Double(upper - lower)
                firstVariation += (c1 * c1 + s1 * s1) / (count * count)
                secondVariation += (c2 * c2 + s2 * s2) / (count * count)
            }
            // Half the RMS cycle-to-cycle change of each complex harmonic amplitude.
            let variation = sqrt(max(firstVariation, secondVariation) / Double(comparisons))
            let noiseScale = 1 + (1 - fraction) * (1 - fraction) + fraction * fraction
            let aperiodic = sqrt(squaredDifference / (Double(n - lag) * noiseScale))
            let floor = max(
                1e-7, 0.02 * residual, variation,
                3 * min(residual, aperiodic) * sqrt(2 / effectiveSamples))
            func amplitude(_ firstColumn: Int, harmonic: Int) throws -> HarmonicAmplitude? {
                let scaled = hypot(coefficient(firstColumn), coefficient(firstColumn + 1))
                guard scaled > floor else { return nil }
                let amplitude = scaled * peak
                guard amplitude.isFinite, amplitude > 0 else {
                    throw HarmonicFailure.unrepresentableAmplitude
                }
                return HarmonicAmplitude(
                    frequencyHz: Double(harmonic) * frequency, peakFS: amplitude,
                    peakDBFS: 20 * log10(amplitude))
            }
            return try Self(
                first: amplitude(1, harmonic: 1), second: amplitude(3, harmonic: 2),
                residual: residual, cycleVariation: variation, detectionFloor: floor)
        }
    }
}
