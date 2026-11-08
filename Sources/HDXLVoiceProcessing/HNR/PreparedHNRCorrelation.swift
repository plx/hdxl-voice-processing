import Foundation

/// Bounded reusable transform workspace. The independent fixture generator uses
/// direct compensated sums; this implementation uses zero-padded convolution.
package final class PreparedHNRCorrelation {
    package let configuration: HNRConfiguration
    package let window: UnsafeMutableBufferPointer<Double>
    package let windowCorrelation: UnsafeMutableBufferPointer<Double>
    package let signalCorrelation: UnsafeMutableBufferPointer<Double>
    package let curve: UnsafeMutableBufferPointer<Double>
    package let valid: UnsafeMutableBufferPointer<Bool>
    package private(set) var directEnergyLagCount: UInt64 = 0
    private let reversed: UnsafeMutableBufferPointer<Double>
    private let transformed: UnsafeMutableBufferPointer<Double>
    private let firstSpectrum: UnsafeMutableBufferPointer<FourierBin<Double>>
    private let secondSpectrum: UnsafeMutableBufferPointer<FourierBin<Double>>
    private let transform: PreparedFourierTransform<Double>

    package var scalarWorkspaceBytes: Int {
        (window.count + windowCorrelation.count + signalCorrelation.count + curve.count
            + reversed.count + transformed.count) * MemoryLayout<Double>.stride
            + valid.count * MemoryLayout<Bool>.stride
            + (firstSpectrum.count + secondSpectrum.count) * MemoryLayout<FourierBin<Double>>.stride
            + transform.scalarWorkspaceBytes
    }
    package var transformLength: Int { transform.configuration.length }

    package init(_ configuration: HNRConfiguration, diagnostics: WorkerDiagnostics) throws {
        self.configuration = configuration
        let n = configuration.windowSampleCount
        let radius = configuration.maximumCorrelationLag
        let required =
            configuration.method == .autocorrelation
            ? n + radius : 2 * n + configuration.maximumCandidateLag - 1
        transform = try PreparedFourierTransform(
            FourierConfiguration(
                length: FourierConfiguration.lengthPadding(required),
                sampleRate: Double(configuration.sampleRate)), diagnostics: diagnostics)
        func allocate(_ count: Int) -> UnsafeMutableBufferPointer<Double> {
            let buffer = UnsafeMutableBufferPointer<Double>.allocate(capacity: count)
            buffer.initialize(repeating: 0)
            return buffer
        }
        window = allocate(n)
        windowCorrelation = allocate(configuration.method == .autocorrelation ? radius + 1 : 0)
        signalCorrelation = allocate(configuration.method == .autocorrelation ? radius + 1 : 0)
        curve = allocate(radius + 1)
        valid = .allocate(capacity: radius + 1)
        valid.initialize(repeating: false)
        reversed = allocate(configuration.method == .forwardCrossCorrelation ? n : 0)
        transformed = allocate(transform.configuration.length)
        firstSpectrum = .allocate(capacity: transform.configuration.realBinCount)
        secondSpectrum = .allocate(capacity: transform.configuration.realBinCount)
        firstSpectrum.initialize(repeating: FourierBin(real: 0))
        secondSpectrum.initialize(repeating: FourierBin(real: 0))
        for i in window.indices {
            window[i] =
                configuration.method == .autocorrelation
                ? HNRNumerics.gaussian(index: i, count: n) : 1
        }
        if configuration.method == .autocorrelation {
            try autocorrelate(UnsafeBufferPointer(window))
            for i in windowCorrelation.indices { windowCorrelation[i] = transformed[i] }
        }
    }
    deinit {
        for buffer in [window, windowCorrelation, signalCorrelation, curve, reversed, transformed] {
            buffer.deinitialize()
            buffer.deallocate()
        }
        valid.deinitialize()
        valid.deallocate()
        firstSpectrum.deinitialize()
        firstSpectrum.deallocate()
        secondSpectrum.deinitialize()
        secondSpectrum.deallocate()
    }

    private func autocorrelate(_ samples: UnsafeBufferPointer<Double>) throws {
        try transform.forwardReal(samples, into: firstSpectrum)
        for i in firstSpectrum.indices {
            let z = firstSpectrum[i]
            firstSpectrum[i] = FourierBin(real: z.real * z.real + z.imaginary * z.imaginary)
        }
        try transform.inverseReal(UnsafeBufferPointer(firstSpectrum), into: transformed)
    }

    /// AC accepts the already windowed centered N samples. CC accepts the centered
    /// forward N+lag support. Curve validity remains separate from numeric storage.
    package func compute(_ samples: UnsafeBufferPointer<Double>, maximumLag: Int) throws {
        let c = configuration
        let n = c.windowSampleCount
        guard maximumLag >= 0,
            maximumLag
                <= (c.method == .autocorrelation ? c.maximumCorrelationLag : c.maximumCandidateLag),
            c.method != .autocorrelation || maximumLag == c.maximumCorrelationLag,
            samples.count == n + (c.method == .forwardCrossCorrelation ? maximumLag : 0)
        else { throw HNRError.invalidBufferSize }
        for sample in samples where !sample.isFinite { throw HNRError.invalidInput }
        for i in curve.indices {
            curve[i] = 0
            valid[i] = false
        }
        if c.method == .autocorrelation {
            try autocorrelate(samples)
            for i in signalCorrelation.indices { signalCorrelation[i] = transformed[i] }
            if transformed[0] > 0 {
                let scale = windowCorrelation[0] / transformed[0]
                for i in curve.indices {
                    if windowCorrelation[i] > 0 {
                        let value = scale * transformed[i] / windowCorrelation[i]
                        guard value.isFinite else { throw HNRError.numericalFailure }
                        curve[i] = value
                        valid[i] = true
                    }
                }
            }
        } else {
            for i in 0..<n { reversed[i] = samples[n - i - 1] }
            try transform.forwardReal(UnsafeBufferPointer(reversed), into: firstSpectrum)
            try transform.forwardReal(samples, into: secondSpectrum)
            for i in firstSpectrum.indices {
                let a = firstSpectrum[i]
                let b = secondSpectrum[i]
                firstSpectrum[i] = FourierBin(
                    real: a.real * b.real - a.imaginary * b.imaginary,
                    imaginary: a.real * b.imaginary + a.imaginary * b.real)
            }
            try transform.inverseReal(UnsafeBufferPointer(firstSpectrum), into: transformed)
            var energy = HNRSum()
            for i in 0..<n { energy.add(samples[i] * samples[i]) }
            let firstEnergy = energy.value
            for lag in 0...maximumLag {
                if lag > 0 {
                    energy.add(-samples[lag - 1] * samples[lag - 1])
                    energy.add(samples[lag + n - 1] * samples[lag + n - 1])
                }
                var secondEnergy = energy.value
                var product = transformed[n - 1 + lag]
                // A nearly empty shifted window can lose its energy when rolling
                // past a much larger value. Recover that bounded lag directly.
                if secondEnergy <= 128 * Double.ulpOfOne * firstEnergy {
                    var directEnergy = HNRSum()
                    var directProduct = HNRSum()
                    for i in 0..<n {
                        directEnergy.add(samples[lag + i] * samples[lag + i])
                        directProduct.add(samples[i] * samples[lag + i])
                    }
                    secondEnergy = directEnergy.value
                    product = directProduct.value
                    directEnergyLagCount = saturatingAdd(directEnergyLagCount)
                }
                // Taking the square roots separately avoids underflow in E1*E2.
                let denominator = sqrt(firstEnergy) * sqrt(secondEnergy)
                if firstEnergy > 0, secondEnergy > 0, denominator > 0 {
                    let value = product / denominator
                    guard value.isFinite else { throw HNRError.numericalFailure }
                    curve[lag] = value
                    valid[lag] = true
                }
            }
            if maximumLag < c.maximumCorrelationLag {
                for i in (maximumLag + 1)...c.maximumCorrelationLag {
                    // The reference's finite interpolation domain deliberately
                    // has a zero tail, not a claim of acquired lag observations.
                    curve[i] = 0
                    valid[i] = true
                }
            }
        }
        curve[0] = 1
        valid[0] = true
    }
}
