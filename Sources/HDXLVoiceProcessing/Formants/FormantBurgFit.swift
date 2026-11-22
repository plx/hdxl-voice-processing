import Foundation

/// Fits A(z) = 1 + a₁/z + … + aₚ/zᵖ. Both residual vectors shrink by one sample per order.
/// The leading monic coefficient is stored explicitly. Predictions use the opposite sign.
struct FormantBurgFit {
    let coefficients: [Double]
    let predictionErrorRatio: Double
    let predictionGainDB: Double
    let maximumReflectionMagnitude: Double
}

final class FormantBurgWorkspace {
    private var forward: [Double]
    private var backward: [Double]
    private var coefficients: [Double]
    private var prior: [Double]
    private let weights: [Double]

    init(weights: [Double], order: Int) {
        self.weights = weights
        forward = Array(repeating: 0, count: weights.count)
        backward = Array(repeating: 0, count: weights.count)
        coefficients = Array(repeating: 0, count: order + 1)
        prior = coefficients
    }

    func fit(_ samples: UnsafeBufferPointer<Double>) -> Result<FormantBurgFit, FormantFitFailure> {
        guard samples.count == weights.count, samples.count > coefficients.count else {
            return .failure(.shortWindow)
        }
        var peak = 0.0
        var different = false
        let first = samples[0]
        for x in samples {
            guard x.isFinite else { return .failure(.nonfinite) }
            peak = max(peak, abs(x))
            different = different || x != first
        }
        guard peak > 0 else { return .failure(.silent) }
        guard different else { return .failure(.constant) }
        for i in samples.indices {
            let normalized = (samples[i] / peak) * weights[i]
            forward[i] = normalized
            backward[i] = normalized
        }
        coefficients[0] = 1
        var logError = 0.0
        var largest = 0.0
        for degree in 1..<coefficients.count {
            var cross = 0.0
            var energy = 0.0
            for i in degree..<samples.count {
                let f = forward[i]
                let b = backward[i - 1]
                cross = cross.addingProduct(f, b)
                energy = energy.addingProduct(f, f).addingProduct(b, b)
            }
            guard energy > 0 else { return .failure(.singularRecursion) }
            let k = -2 * cross / energy
            guard k.isFinite, abs(k) < 1 else { return .failure(.unstableRecursion) }
            largest = max(largest, abs(k))
            logError += log1p(-k * k)
            for j in 0..<degree { prior[j] = coefficients[j] }
            for j in 1..<degree { coefficients[j] = prior[j].addingProduct(k, prior[degree - j]) }
            coefficients[degree] = k
            // Descending order preserves the previous backward residual at i-1.
            for i in stride(from: samples.count - 1, through: degree, by: -1) {
                let f = forward[i]
                let b = backward[i - 1]
                forward[i] = f.addingProduct(k, b)
                backward[i] = b.addingProduct(k, f)
            }
        }
        return .success(
            FormantBurgFit(
                coefficients: coefficients, predictionErrorRatio: exp(logError),
                predictionGainDB: -10 * logError / log(10), maximumReflectionMagnitude: largest))
    }
}
