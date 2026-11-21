import Foundation

final class SWIPEPrimeWindowStorage {
    let length: Int
    let offset: Int
    let transform: PreparedFourierTransform<Double>
    let hann: SWIPEPrimeBuffer<Double>
    let windowed: SWIPEPrimeBuffer<Double>
    let spectrum: SWIPEPrimeBuffer<FourierBin<Double>>
    let magnitude: SWIPEPrimeBuffer<Double>
    let loudness: SWIPEPrimeBuffer<Double>
    let normalizedLoudness: SWIPEPrimeBuffer<Double>
    let interpolationLower: SWIPEPrimeBuffer<Int>
    let interpolationWeight: SWIPEPrimeBuffer<Double>
    let candidateIndices: SWIPEPrimeBuffer<Int>
    let strengths: SWIPEPrimeBuffer<Double?>

    init(length: Int, layout: SWIPEPrimeLayout, sampleRate: Int, diagnostics: WorkerDiagnostics)
        throws
    {
        self.length = length
        self.offset = (layout.requiredSampleCount - length) / 2
        transform = try PreparedFourierTransform(
            FourierConfiguration(length: length, sampleRate: Double(sampleRate)),
            diagnostics: diagnostics)
        hann = SWIPEPrimeBuffer(count: length, repeating: 0)
        windowed = SWIPEPrimeBuffer(count: length, repeating: 0)
        spectrum = SWIPEPrimeBuffer(count: length / 2 + 1, repeating: FourierBin(real: 0))
        magnitude = SWIPEPrimeBuffer(count: length / 2 + 1, repeating: 0)
        loudness = SWIPEPrimeBuffer(count: layout.erbFrequenciesHz.count, repeating: 0)
        normalizedLoudness = SWIPEPrimeBuffer(count: layout.erbFrequenciesHz.count, repeating: 0)
        interpolationLower = SWIPEPrimeBuffer(count: layout.erbFrequenciesHz.count, repeating: 0)
        interpolationWeight = SWIPEPrimeBuffer(count: layout.erbFrequenciesHz.count, repeating: 0)
        let indices = layout.candidateWindows.indices.filter {
            let mixture = layout.candidateWindows[$0]
            return mixture.lowerLength == length
                || (mixture.upperWeight > 0 && mixture.upperLength == length)
        }
        candidateIndices = SWIPEPrimeBuffer(count: indices.count, repeating: 0)
        strengths = SWIPEPrimeBuffer(count: layout.candidateFrequenciesHz.count, repeating: nil)
        for j in 0..<length {
            hann.values[j] = 0.5 - 0.5 * cos(2 * .pi * Double(j) / Double(length))
        }
        for index in indices.indices { candidateIndices.values[index] = indices[index] }
        for bin in layout.erbFrequenciesHz.indices {
            let position = layout.erbFrequenciesHz[bin] * Double(length) / Double(sampleRate)
            let lower = min(Int(floor(position)), length / 2)
            interpolationLower.values[bin] = lower
            interpolationWeight.values[bin] = position - Double(lower)
        }
    }

    var preparedBytes: Int {
        hann.bytes + windowed.bytes + spectrum.bytes + magnitude.bytes + loudness.bytes
            + normalizedLoudness.bytes + interpolationLower.bytes + interpolationWeight.bytes
            + candidateIndices.bytes + strengths.bytes + transform.scalarWorkspaceBytes
    }

    var borrowed: BorrowedSWIPEPrimeWindow {
        BorrowedSWIPEPrimeWindow(
            length: length, offset: offset, magnitude: magnitude.borrowed,
            loudness: loudness.borrowed,
            candidateIndices: candidateIndices.borrowed, candidateStrengths: strengths.borrowed)
    }

    func analyze(samples: UnsafeBufferPointer<Double>, kernels: UnsafeBufferPointer<Double>) throws
    {
        for j in 0..<length { windowed.values[j] = samples[offset + j] * hann.values[j] }
        try transform.forwardReal(windowed.borrowed, into: spectrum.values)
        for bin in spectrum.values.indices {
            let value = spectrum.values[bin]
            magnitude.values[bin] = hypot(value.real, value.imaginary)
        }
        var energy = SWIPEPrimeSum()
        for bin in loudness.values.indices {
            let lower = interpolationLower.values[bin]
            let upper = min(lower + 1, length / 2)
            let weight = interpolationWeight.values[bin]
            let value = sqrt(
                (1 - weight) * magnitude.values[lower] + weight * magnitude.values[upper])
            guard value.isFinite else { throw SWIPEPrimeError.numericalFailure }
            loudness.values[bin] = value
            energy.add(value * value)
        }
        let norm = sqrt(energy.value)
        guard norm.isFinite else { throw SWIPEPrimeError.numericalFailure }
        if norm == 0 {
            for candidate in candidateIndices.values { strengths.values[candidate] = nil }
            return
        }
        for bin in loudness.values.indices {
            normalizedLoudness.values[bin] = loudness.values[bin] / norm
        }
        for candidate in candidateIndices.values {
            let offset = candidate * loudness.values.count
            var product = SWIPEPrimeSum()
            for bin in loudness.values.indices {
                product.add(kernels[offset + bin] * normalizedLoudness.values[bin])
            }
            guard product.value.isFinite else { throw SWIPEPrimeError.numericalFailure }
            strengths.values[candidate] = product.value
        }
    }
}
