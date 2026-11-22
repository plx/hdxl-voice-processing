import Foundation

extension HarmonicFormantContribution {
    init(number: Int, frequency: Double, bandwidth: Double, f0: Double, rate: Double) throws {
        guard frequency.isFinite, bandwidth.isFinite, frequency > 0, frequency < rate / 2,
            bandwidth > 0, bandwidth < rate / 2
        else { throw HarmonicFailure.unstableCorrection }
        let decay = -Double.pi * bandwidth / rate
        let r = exp(decay)
        let oneMinusR = -expm1(decay)
        // |1 - r·exp(iθ)|² in a form that avoids cancellation near θ = 0.
        func logDistance(_ hz: Double) -> Double {
            let s = sin(Double.pi * hz / rate)
            return log10(oneMinusR * oneMinusR + 4 * r * s * s)
        }
        let dc = 2 * logDistance(frequency)
        func gain(_ hz: Double) -> Double {
            10 * (dc - logDistance(frequency + hz) - logDistance(frequency - hz))
        }
        let first = gain(f0)
        let second = gain(2 * f0)
        guard first.isFinite, second.isFinite, abs(first) <= 60, abs(second) <= 60
        else { throw HarmonicFailure.unstableCorrection }
        self.init(
            number: number, frequencyHz: frequency, bandwidthHz: bandwidth,
            firstGainDB: first, secondGainDB: second,
            nearResonance: min(abs(frequency - f0), abs(frequency - 2 * f0)) <= bandwidth / 2)
    }
}

extension PreparedHarmonicDifference {
    /// Apply the sampled pole-pair correction to a previously computed raw fit.
    /// The F0 that qualified the original Burg poles must match this observation.
    public func correct(_ raw: RawHarmonicFrame, formants: BurgFormantFrame?) throws
        -> CorrectedHarmonicFrame
    {
        guard raw.measurement.profile == rawIdentity, raw.configuration == configuration.fit
        else { throw ContractError.invalidConfiguration }
        let source = raw.dependencySupport
        return try rawAnalyzer.measured(.harmonicCorrection, source: source) {
            var support = source
            var delay = raw.measurement.timing.effectiveDelaySeconds
            var contributions: [HarmonicFormantContribution] = []
            var first: Double?
            var second: Double?
            var failure: HarmonicFailure?
            var unusable: BurgFormantCandidate?
            do {
                if let reason = raw.failure { throw reason }
                guard let f0 = raw.pitch?.outcome.estimate?.value,
                    let h1 = raw.first, let h2 = raw.second
                else { throw ContractError.invalidValue }
                guard !raw.clipped else { throw HarmonicFailure.clippedInput }
                guard f0 < 300 else { throw HarmonicFailure.highPitch }
                guard let formants else { throw HarmonicFailure.missingFormants }
                guard formants.configuration == configuration.formants else {
                    throw HarmonicFailure.wrongFormantProfile
                }
                let dependency = formants.conditioningSupport
                guard formants.timing.source == source,
                    dependency.epoch == source.epoch, dependency.sampleRate == source.sampleRate,
                    dependency.startSample <= source.startSample,
                    dependency.endSample >= source.endSample
                else { throw HarmonicFailure.formantSupportMismatch }
                guard let observed = formants.pitch, observed.source == source,
                    observed.profile == configuration.fit.pitchProfile, observed.frequencyHz == f0
                else { throw HarmonicFailure.qualifyingPitchMismatch }
                guard formants.profile == boundFormants else {
                    throw HarmonicFailure.wrongFormantProfile
                }
                support = dependency
                let placement = raw.measurement.timing.source
                let center =
                    Double(placement.startSample - source.startSample) / source.sampleRate
                    + placement.durationSeconds / 2
                delay = max(
                    delay,
                    Double(dependency.endSample - source.startSample) / source.sampleRate - center,
                    formants.timing.effectiveDelaySeconds + source.durationSeconds / 2 - center)
                guard formants.failure == nil,
                    formants.timing.includedSampleCount == source.sampleCount
                else { throw HarmonicFailure.formantFitFailed }
                for rank in 1...2 {
                    let supplied = formants.candidates.first { $0.number == rank }
                    unusable = supplied
                    guard let candidate = supplied, candidate.isCredible,
                        let hz = candidate.frequencyHz,
                        let bw = candidate.bandwidthHz
                    else {
                        throw rank == 1
                            ? HarmonicFailure.firstFormantUnavailable : .secondFormantUnavailable
                    }
                    contributions.append(
                        try HarmonicFormantContribution(
                            number: rank, frequency: hz,
                            bandwidth: bw, f0: f0, rate: source.sampleRate))
                    unusable = nil
                }
                first = h1.peakDBFS - contributions.reduce(0) { $0 + $1.firstGainDB }
                second = h2.peakDBFS - contributions.reduce(0) { $0 + $1.secondGainDB }
            } catch let reason as HarmonicFailure {
                failure = reason
            }
            let outcome: MeasurementOutcome
            if raw.failure != nil {
                outcome = raw.measurement.outcome
            } else if failure == .formantFitFailed, let cause = formants?.failure {
                outcome = .unavailable(cause.reason)
            } else if let failure {
                outcome = .unavailable(failure.reason)
            } else if let first, let second {
                let sensitive =
                    contributions.contains(where: \.nearResonance)
                    || formants?.cautions.contains(.ceilingSensitive) == true
                outcome = .available(
                    try ScalarEstimate(
                        value: first - second,
                        warnings: sensitive
                            ? [.exploratoryApplicability, .lowConfidence]
                            : [.exploratoryApplicability]))
            } else {
                throw ContractError.invalidValue
            }
            let original = raw.measurement.timing
            let timing = try AnalysisTiming(
                source: original.source, includedSampleCount: original.includedSampleCount,
                sourceStartSeconds: original.sourceStartSeconds,
                hostStartNanoseconds: original.hostStartNanoseconds,
                effectiveDelaySeconds: delay)
            let result = try MeasurementResult(
                measurement: correctedDescriptor, profile: correctedIdentity,
                timing: timing, outcome: outcome)
            return CorrectedHarmonicFrame(
                configuration: configuration, raw: raw, formantProfile: formants?.profile,
                formantWindow: formants?.timing.source,
                formantConditioningSupport: formants?.conditioningSupport,
                formantPitch: formants?.pitch, formantFailure: formants?.failure,
                formantCautions: formants?.cautions ?? [],
                unusableFormant: unusable, contributions: contributions, correctedFirstDBFS: first,
                correctedSecondDBFS: second,
                measurement: result, dependencySupport: support, failure: failure)
        }
    }
}
