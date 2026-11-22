import Foundation

/// A shared peak keeps sums bounded and makes the shape computations independent of gain.
struct SpectralShapeWeights {
    let peak: Double
    let rootPeak: Double
    let magnitude: Bool

    init(peak: Double, configuration: SpectralShapeProfile) {
        self.peak = peak
        magnitude = configuration.weighting == .binRMSMagnitude
        rootPeak = magnitude ? sqrt(peak) : 1
    }

    func weight(_ power: Double) -> Double { magnitude ? sqrt(power) / rootPeak : power / peak }
}

struct SpectralShapeMoments {
    var centroid: MeasurementOutcome
    var spread: MeasurementOutcome
    var flatness: MeasurementOutcome
    var rollOff: MeasurementOutcome

    init(_ reason: UnavailabilityReason) {
        centroid = .unavailable(reason)
        spread = .unavailable(reason)
        flatness = .unavailable(reason)
        rollOff = .unavailable(reason)
    }
}

extension PreparedSpectralShape {
    func shapeMoments(
        _ powers: UnsafeBufferPointer<Double>, unavailable: UnavailabilityReason?,
        only: SpectralShapeDescriptor?
    ) -> SpectralShapeMoments {
        if let unavailable { return SpectralShapeMoments(unavailable) }
        guard let bins = analysisBins else { return SpectralShapeMoments(.unsupportedRange) }
        guard !bins.isEmpty else { return SpectralShapeMoments(.insufficientData) }
        let peak = powers[bins].max() ?? 0
        guard peak > 0 else { return SpectralShapeMoments(.silence) }
        let weights = SpectralShapeWeights(peak: peak, configuration: configuration)
        let location = only == nil || only == .spread || only == .centroid
        let flatness = only == nil || only == .flatness
        let rollOff = (only == nil || only == .rollOff) && configuration.rollOffFraction < 1
        func rollWeight(_ power: Double) -> Double { weights.magnitude ? sqrt(power) : power }
        var rollTotal = SpectralRollOffMass()
        let floor = configuration.relativeLogFloorDB.map { $0 * log(10) / 10 }
        let logPeak = log(peak)
        var sum = LevelCompensatedSum()
        var first = LevelCompensatedSum()
        var logs = LevelCompensatedSum()
        var flooredSum = LevelCompensatedSum()
        var hasLogZero = false
        var hasSubnormalWeight = false
        var lastPositive = bins.lowerBound
        // Use offsets to maintain precision in narrow bands far from DC.
        for k in bins {
            let power = powers[k]
            let weight = weights.weight(power)
            sum.add(weight)
            if rollOff { rollTotal.add(rollWeight(power)) }
            if power > 0 {
                lastPositive = k
                if weight < Double.leastNormalMagnitude { hasSubnormalWeight = true }
            }
            if location { first.add(Double(k - bins.lowerBound) * weight) }
            if flatness {
                if power == 0 && floor == nil {
                    hasLogZero = true
                    continue
                }
                let raw = power == 0 ? -Double.infinity : log(power) - logPeak
                let bounded = max(raw, floor ?? -.infinity) * (weights.magnitude ? 0.5 : 1)
                logs.add(bounded)
                if floor != nil { flooredSum.add(exp(bounded)) }
            }
        }
        let mean = first.value / sum.value
        var result = SpectralShapeMoments(.analysisFailure)
        if location {
            result.centroid = spectralShapeEstimate((Double(bins.lowerBound) + mean) * grid.step)
        }
        if location && hasSubnormalWeight && bins.lowerBound == 0
            && mean < Double.leastNormalMagnitude
        {
            var terms = SpectralLogSum()
            for k in bins where k > 0 && powers[k] > 0 {
                terms.add(
                    (log(powers[k]) - logPeak) * (weights.magnitude ? 0.5 : 1) + log(Double(k)))
            }
            if let total = terms.logarithm {
                result.centroid = spectralPositiveEstimate(
                    logValue: total + log(grid.step) - log(sum.value))
            }
        }
        if flatness {
            let count = Double(bins.count)
            let arithmetic = (floor == nil ? sum.value : flooredSum.value) / count
            let value = hasLogZero ? 0 : exp(logs.value / count - log(arithmetic))
            result.flatness =
                !hasLogZero && value == 0
                ? .unavailable(.analysisFailure) : spectralShapeEstimate(min(1, value))
        }
        if only == .spread || only == nil {
            var variance = LevelCompensatedSum()
            for k in bins {
                let offset = Double(k - bins.lowerBound) - mean
                variance.add(weights.weight(powers[k]) * offset * offset)
            }
            result.spread = spectralShapeEstimate(sqrt(variance.value / sum.value) * grid.step)
            if hasSubnormalWeight && variance.value < Double.leastNormalMagnitude {
                var terms = SpectralLogSum()
                for k in bins where powers[k] > 0 {
                    let distance = abs(Double(k - bins.lowerBound) - mean)
                    if distance > 0 {
                        terms.add(
                            (log(powers[k]) - logPeak) * (weights.magnitude ? 0.5 : 1) + 2
                                * log(distance))
                    }
                }
                if let total = terms.logarithm {
                    result.spread = spectralPositiveEstimate(
                        logValue: 0.5 * (total - log(sum.value)) + log(grid.step))
                }
            }
        }
        if only == .rollOff || only == nil {
            var chosen = lastPositive
            if rollOff {
                let threshold = rollTotal.threshold(fraction: configuration.rollOffFraction)
                var cumulative = SpectralRollOffMass()
                for k in bins {
                    cumulative.add(rollWeight(powers[k]))
                    if powers[k] > 0 && cumulative.reaches(threshold) {
                        chosen = k
                        break
                    }
                }
            }
            result.rollOff = spectralShapeEstimate(Double(chosen) * grid.step)
        }
        return result
    }
}

struct SpectralComponentPower {
    let outcome: MeasurementOutcome
    let logPower: Double?

    func ratio(to denominator: Self) -> MeasurementOutcome {
        // Even when the linear FS² sum overflows, its finite logarithm determines a valid ratio.
        if let a = logPower, let b = denominator.logPower {
            if let linear = outcome.estimate?.value,
                let reference = denominator.outcome.estimate?.value,
                let nearby = spectralNearbyLogRatio(linear, reference)
            {
                return spectralShapeEstimate(nearby * (10 / log(10)))
            }
            return spectralShapeEstimate((a - b) * (10 / log(10)))
        }
        for component in [self, denominator] where component.logPower == nil {
            if case .unavailable = component.outcome { return component.outcome }
        }
        return .unavailable(.silence)
    }
}

func spectralBandEnergy(
    _ powers: UnsafeBufferPointer<Double>, cells: SpectralBandCells?,
    unavailable: UnavailabilityReason?
) -> SpectralComponentPower {
    if let unavailable { return .init(outcome: .unavailable(unavailable), logPower: nil) }
    guard let cells else { return .init(outcome: .unavailable(.unsupportedRange), logPower: nil) }
    guard !cells.range.isEmpty else {
        return .init(outcome: .unavailable(.insufficientData), logPower: nil)
    }
    let peak = powers[cells.range].max() ?? 0
    guard peak > 0 else { return .init(outcome: spectralShapeEstimate(0), logPower: nil) }
    var normalized = LevelCompensatedSum()
    for k in cells.range { normalized.add((powers[k] / peak) * cells.overlap(at: k).fraction) }
    if normalized.value < Double.leastNormalMagnitude {
        // A positive band can occupy less than one representable fraction of a large edge cell.
        var terms = SpectralLogSum()
        for k in cells.range where powers[k] > 0 {
            terms.add(log(powers[k]) + cells.overlap(at: k).logFraction)
        }
        if let total = terms.logarithm {
            return .init(outcome: spectralPositiveEstimate(logValue: total), logPower: total)
        }
    }
    let value = normalized.value * peak
    return .init(
        outcome: value > 0 ? spectralShapeEstimate(value) : .unavailable(.analysisFailure),
        logPower: log(peak) + log(normalized.value))
}

/// Rescale at the largest logarithm before adding. The common, representable path sums linear weights.
private struct SpectralLogSum {
    var largest = -Double.infinity
    var scaled = 0.0
    mutating func add(_ value: Double) {
        if value > largest {
            scaled = scaled * exp(largest - value) + 1
            largest = value
        } else {
            scaled += exp(value - largest)
        }
    }
    var logarithm: Double? { scaled > 0 ? largest + log(scaled) : nil }
}

private func spectralPositiveEstimate(logValue: Double) -> MeasurementOutcome {
    let value = exp(logValue)
    return value > 0 ? spectralShapeEstimate(value) : .unavailable(.analysisFailure)
}

/// Subtraction is exact for nearby positive binary values (Sterbenz's lemma).
/// log1p preserves the sign and size of a ratio too close to one to divide accurately.
func spectralNearbyLogRatio(_ value: Double, _ reference: Double) -> Double? {
    guard value > 0, reference > 0, value >= reference * 0.5, reference >= value * 0.5 else {
        return nil
    }
    return log1p((value - reference) / reference)
}
