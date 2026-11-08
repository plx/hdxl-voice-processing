import Foundation

package enum PulseSearchDirection: Int, Sendable {
    case backward = -1
    case forward = 1
}

package enum PulsePairSupport: Sendable {
    case observed, noObservedPairs, silent, numericalFailure
}

package struct PulseCorrelationBin {
    var coefficient: Double = 0
    var candidatePeak: Double = 0
    var pairCount: Int = 0
    var varyingAnchor = false
    var varyingCandidate = false
    var support: PulsePairSupport = .noObservedPairs
}

package struct PulseSeed {
    let timeSeconds: Double
    let firstSampleIndex: Int
    let lastSampleIndex: Int
    let firstRequiredSampleIndex: Int
    let lastRequiredSampleIndex: Int
    let peak: Double
    let varyingSupport: Bool
}

package struct PulseSearchMatch {
    let timeSeconds: Double
    let correlation: Double?
    let amplitudeGatePeak: Double
    let curvature: Double
    let observedPairCount: Int
    let varyingSupport: Bool
    let support: PulsePairSupport
    let usedRangeFallback: Bool
    let selectedSyntheticCandidate: Bool
    let firstRequiredSampleIndex: Int
    let lastRequiredSampleIndex: Int
    let evaluatedLagCount: Int
}

/// Prepared direct correlation tables. Input PCM is checked once by the owning
/// interval worker; these package-only operations never retain an input pointer.
package final class PulseSearchKernel {
    let configuration: PulseConfiguration
    private let bins: UnsafeMutableBufferPointer<PulseCorrelationBin>
    private let diagnostics: WorkerDiagnostics
    var workspaceBytes: Int { bins.count * MemoryLayout<PulseCorrelationBin>.stride }

    init(_ configuration: PulseConfiguration, diagnostics: WorkerDiagnostics = WorkerDiagnostics())
    {
        self.configuration = configuration
        self.diagnostics = diagnostics
        bins = .allocate(capacity: configuration.maximumCandidateLagCount + 2)
        bins.initialize(repeating: PulseCorrelationBin())
    }
    deinit {
        bins.deinitialize()
        bins.deallocate()
    }

    private var step: Double { 1 / Double(configuration.sampleRate) }
    private var firstCenter: Double { 0.5 / Double(configuration.sampleRate) }

    /// Keep the sampled object's one-based coordinate arithmetic before the
    /// final conversion to native zero-based indices.
    private func coordinate(_ time: Double) -> Double { (time - firstCenter) / step + 1 }
    private func low(_ time: Double) -> Int { Int(floor(coordinate(time))) - 1 }
    private func high(_ time: Double) -> Int { Int(ceil(coordinate(time))) - 1 }
    private func nearest(_ time: Double) -> Int { Int(floor(coordinate(time) + 0.5)) - 1 }

    func seed(
        _ samples: UnsafeBufferPointer<Double>, midpoint: Double, frequency: Double
    ) throws -> PulseSeed {
        try validateGeometry(samples, time: midpoint, frequency: frequency)
        let lowerTime = midpoint - 0.5 / frequency
        let upperTime = midpoint + 0.5 / frequency
        let requiredFirst = low(lowerTime)
        let requiredLast = high(upperTime)
        let a = max(0, requiredFirst)
        let b = min(samples.count - 1, requiredLast)
        guard a <= b else {
            return PulseSeed(
                timeSeconds: midpoint, firstSampleIndex: a, lastSampleIndex: b,
                firstRequiredSampleIndex: requiredFirst, lastRequiredSampleIndex: requiredLast,
                peak: 0, varyingSupport: false)
        }
        var minimum = samples[a]
        var maximum = minimum
        var minimumIndex = a
        var maximumIndex = a
        if a < b {
            for i in (a + 1)...b {
                let value = samples[i]
                if value < minimum {
                    minimum = value
                    minimumIndex = i
                }
                if value > maximum {
                    maximum = value
                    maximumIndex = i
                }
            }
        }
        let peak = max(abs(minimum), abs(maximum))
        let varying =
            peak > 0 && (maximum - minimum) / peak > configuration.minimumRelativeVariation
        let location: Double
        if a == b {
            location = Double(a)
        } else if b == a + 1 && abs(samples[a]) == abs(samples[b]) {
            location = Double(a) + 0.5
        } else if minimum == maximum {
            location = 0.5 * Double(a + b)
        } else {
            let selected = abs(minimum) > abs(maximum) ? minimumIndex : maximumIndex
            if selected == a || selected == b {
                location = Double(selected)
            } else {
                let left = samples[selected - 1]
                let middle = samples[selected]
                let right = samples[selected + 1]
                let denominator = 2 * middle - left - right
                let offset = denominator == 0 ? 0 : 0.5 * (right - left) / denominator
                guard offset.isFinite else { throw PulseError.numericalFailure }
                location = Double(selected) + offset
            }
        }
        return PulseSeed(
            timeSeconds: firstCenter.addingProduct(location, step), firstSampleIndex: a,
            lastSampleIndex: b, firstRequiredSampleIndex: requiredFirst,
            lastRequiredSampleIndex: requiredLast, peak: peak, varyingSupport: varying)
    }

    func match(
        _ samples: UnsafeBufferPointer<Double>, anchor: Double, frequency: Double,
        direction: PulseSearchDirection
    ) throws -> PulseSearchMatch {
        try validateGeometry(samples, time: anchor, frequency: frequency)
        let period = 1 / frequency
        let sign = Double(direction.rawValue)
        let near = anchor + sign * 0.8 / frequency
        let far = anchor + sign * 1.25 / frequency
        let lowerTime = min(near, far)
        let upperTime = max(near, far)
        let a = nearest(anchor - 0.5 * period)
        let b = nearest(anchor + 0.5 * period)
        let firstLag = low(lowerTime - 0.5 * period)
        let lastLag = high(upperTime - 0.5 * period)
        let count = lastLag - firstLag + 1
        guard count > 0, count + 2 <= bins.count,
            b >= a, b - a + 1 <= configuration.maximumCorrelationSampleCount
        else { throw PulseError.capacityExceeded }
        var selected: Int?
        var best = -1.0
        diagnostics.withInterval(.pulseMatching) {
            bins[0] = PulseCorrelationBin()
            bins[1] = PulseCorrelationBin()
            for i in 0..<count {
                bins[i + 2] = Self.correlation(
                    samples, anchorFirst: a, anchorLast: b, candidateFirst: firstLag + i,
                    minimumRelativeVariation: configuration.minimumRelativeVariation)
            }
            // The final computed lag is a right neighbor, not a peak center. The
            // finite-table sentinels participate only in this reference selection.
            for center in 1...count {
                let value = bins[center].coefficient
                if value > best, value >= bins[center - 1].coefficient,
                    value >= bins[center + 1].coefficient
                {
                    selected = center
                    best = value
                }
            }
        }
        guard let center = selected else {
            return PulseSearchMatch(
                timeSeconds: anchor + sign * period, correlation: nil, amplitudeGatePeak: 0,
                curvature: 0, observedPairCount: 0, varyingSupport: false,
                support: .noObservedPairs, usedRangeFallback: false,
                selectedSyntheticCandidate: false,
                firstRequiredSampleIndex: min(a, firstLag),
                lastRequiredSampleIndex: max(b, lastLag + b - a), evaluatedLagCount: count)
        }
        return try diagnostics.withInterval(.pulseInterpolation) {
            let left = bins[center - 1].coefficient
            let right = bins[center + 1].coefficient
            let curvature = (best - left) + (best - right)
            let slope = 0.5 * (right - left)
            let offset = curvature == 0 ? 0 : slope / curvature
            let height = curvature == 0 ? best : best + 0.5 * slope * slope / curvature
            let selectedStart = firstLag + center - 2
            // Preserve the reference coordinate's rounding before taking the lag.
            let fractionalOneBased = Double(selectedStart + 1) + offset
            let lag = fractionalOneBased - Double(a + 1)
            let proposed = anchor.addingProduct(lag, step)
            let outside = !(lowerTime...upperTime).contains(proposed)
            let time =
                outside
                ? anchor + sign * sqrt((lowerTime - anchor) * (upperTime - anchor)) : proposed
            let coefficient = outside ? max(best, bins[count + 1].coefficient) : height
            guard time.isFinite, coefficient.isFinite, curvature.isFinite,
                sign * (time - anchor) > 0
            else { throw PulseError.numericalFailure }
            let selectedBin = bins[center]
            return PulseSearchMatch(
                timeSeconds: time,
                correlation: selectedBin.support == .numericalFailure ? nil : coefficient,
                amplitudeGatePeak: bins[center + 1].candidatePeak, curvature: curvature,
                observedPairCount: selectedBin.pairCount,
                varyingSupport: selectedBin.varyingAnchor && selectedBin.varyingCandidate,
                support: selectedBin.support, usedRangeFallback: outside,
                selectedSyntheticCandidate: center == 1,
                firstRequiredSampleIndex: min(a, selectedStart - 1),
                lastRequiredSampleIndex: max(b, selectedStart + 1 + b - a), evaluatedLagCount: count
            )
        }
    }

    private func validateGeometry(
        _ samples: UnsafeBufferPointer<Double>, time: Double, frequency: Double
    ) throws {
        guard (1...PulseConfiguration.maximumInputSampleCount).contains(samples.count),
            time.isFinite, (0...(Double(samples.count) * step)).contains(time),
            frequency.isFinite, frequency >= configuration.pitchFloorHz,
            frequency < configuration.pitchCeilingHz
        else { throw PulseError.invalidInput }
    }

    /// Caller supplies bounded indices and previously validated finite PCM.
    package static func correlation(
        _ samples: UnsafeBufferPointer<Double>, anchorFirst: Int, anchorLast: Int,
        candidateFirst: Int, minimumRelativeVariation: Double
    ) -> PulseCorrelationBin {
        let shift = candidateFirst - anchorFirst
        let first = max(anchorFirst, 0, -shift)
        let last = min(anchorLast, samples.count - 1, samples.count - 1 - shift)
        guard first <= last else { return PulseCorrelationBin() }
        var energyA = 0.0
        var energyB = 0.0
        var dot = 0.0
        var lowA = samples[first]
        var highA = lowA
        var lowB = samples[first + shift]
        var highB = lowB
        for i in first...last {
            let a = samples[i]
            let b = samples[i + shift]
            energyA = energyA.addingProduct(a, a)
            energyB = energyB.addingProduct(b, b)
            dot = dot.addingProduct(a, b)
            lowA = min(lowA, a)
            highA = max(highA, a)
            lowB = min(lowB, b)
            highB = max(highB, b)
        }
        let peakA = max(abs(lowA), abs(highA))
        let peakB = max(abs(lowB), abs(highB))
        var product = energyA * energyB
        // Preserve the pinned fused arithmetic for ordinary inputs. If raw
        // energies would lose the entire normalization product, independently
        // scale the two observed vectors before evaluating the same cosine.
        // A representable quiet waveform is not numerical silence.
        if peakA > 0, peakB > 0, product < Double.leastNormalMagnitude {
            energyA = 0
            energyB = 0
            dot = 0
            for i in first...last {
                let a = samples[i] / peakA
                let b = samples[i + shift] / peakB
                energyA = energyA.addingProduct(a, a)
                energyB = energyB.addingProduct(b, b)
                dot = dot.addingProduct(a, b)
            }
            product = energyA * energyB
        }
        let denominator = sqrt(product)
        let status: PulsePairSupport =
            peakA == 0 || peakB == 0
            ? .silent
            : product < Double.leastNormalMagnitude || !denominator.isFinite
                ? .numericalFailure : .observed
        let coefficient = status == .observed ? dot / denominator : 0
        return PulseCorrelationBin(
            coefficient: coefficient.isFinite ? coefficient : 0,
            candidatePeak: peakB, pairCount: last - first + 1,
            varyingAnchor: peakA > 0 && (highA - lowA) / peakA > minimumRelativeVariation,
            varyingCandidate: peakB > 0 && (highB - lowB) / peakB > minimumRelativeVariation,
            support: coefficient.isFinite ? status : .numericalFailure)
    }
}
