import Foundation

public enum FormantFitFailure: String, Error, Sendable, Encodable {
    case shortWindow, silent, constant, nonfinite, singularRecursion, unstableRecursion,
        rootNonconvergence
    var reason: UnavailabilityReason {
        switch self {
        case .shortWindow: .insufficientData
        case .silent: .silence
        case .constant: .inapplicableTask
        case .nonfinite: .invalidInput
        case .singularRecursion, .unstableRecursion, .rootNonconvergence: .analysisFailure
        }
    }
}

public enum FormantCaution: String, Sendable, Hashable, Encodable {
    case pitchUnassessed, pitchSupportMismatch, highPitch, weakPrediction, ceilingSensitive
}

public enum FormantRejection: String, Sendable, Hashable, Encodable {
    case realOrNearReal, zeroRadius, unstablePole, outsideEdgeMargin, broadBandwidth,
        sparseHarmonics, weakPrediction
}

/// Optional independent F0 observation for precisely the reported source-window support.
public struct FormantPitchEvidence: Sendable, Hashable, Encodable {
    public let source: SourceInterval
    public let profile: ProfileIdentity
    public let frequencyHz: Double
    public init(source: SourceInterval, profile: ProfileIdentity, frequencyHz: Double) throws {
        guard frequencyHz.isFinite, frequencyHz > 0, frequencyHz < source.sampleRate / 2 else {
            throw ContractError.invalidValue
        }
        self.source = source
        self.profile = profile
        self.frequencyHz = frequencyHz
    }
}

/// One upper-half-plane pole per conjugate pair, plus any real poles. Both components use Hz.
public struct BurgFormantCandidate: Sendable, Hashable, Encodable {
    public let real: Double
    public let imaginary: Double
    public let radius: Double
    public let frequencyHz: Double
    public let bandwidthHz: Double?
    /// Ascending frequency rank after the reference edge and stability exclusions, before credibility screening.
    public let number: Int?
    public let rejections: [FormantRejection]
    public var isCredible: Bool { number != nil && rejections.isEmpty }
}

public struct BurgFormantDiagnostics: Sendable, Hashable, Encodable {
    /// Monic prediction polynomial in descending powers. Nil means fitting failed before coefficients existed.
    public let coefficients: [Double]?
    public let predictionErrorRatio: Double?
    public let predictionGainDB: Double?
    public let maximumReflectionMagnitude: Double?
    public let rootSweeps: Int
    public let triedSecondStart: Bool
    public let maximumRootResidual: Double?
    init(fit: FormantBurgFit?, solution: FormantRootSolution?) {
        coefficients = fit?.coefficients
        predictionErrorRatio = fit?.predictionErrorRatio
        predictionGainDB = fit?.predictionGainDB
        maximumReflectionMagnitude = fit?.maximumReflectionMagnitude
        rootSweeps = solution?.sweeps ?? 0
        triedSecondStart = solution?.triedSecondStart ?? false
        maximumRootResidual = solution?.maximumRelativeResidual
    }
}

public struct BurgFormantFrame: Sendable, Hashable, Encodable {
    public let configuration: BurgFormantProfile
    public let profile: ProfileIdentity
    public let timing: AnalysisTiming
    /// Whole-input Fourier resampling and pre-emphasis use this contiguous source interval.
    public let conditioningSupport: SourceInterval
    public let centerSecondsFromOrigin: Double
    public let index: Int
    public let pitch: FormantPitchEvidence?
    public let diagnostics: BurgFormantDiagnostics
    public let failure: FormantFitFailure?
    public let cautions: [FormantCaution]
    public let candidates: [BurgFormantCandidate]
    public let credibilityRule = BurgFormantProfile.credibilityRule
    public let frequencyUnit = MeasurementUnit.hertz
    public let bandwidthUnit = MeasurementUnit.hertz
    public func formant(_ number: Int) -> BurgFormantCandidate? {
        candidates.first { $0.number == number && $0.isCredible }
    }
    public var f1: BurgFormantCandidate? { formant(1) }
    public var f2: BurgFormantCandidate? { formant(2) }
    public var f3: BurgFormantCandidate? { formant(3) }

    /// A session recipe that reproduces this frame's exact profile digest.
    public var archiveProfile: SessionArchiveProfile {
        guard let pitch else { return .burgFormants(configuration) }
        return .pitchBoundBurgFormants(
            configuration, pitchProfile: pitch.profile,
            supportMatched: pitch.source == timing.source)
    }

    /// Keep an unavailable or low-confidence rank distinct from a measured zero in exported contracts.
    public func measurement(number: Int, kind: MeasurementKind) throws -> MeasurementResult {
        let descriptor = try configuration.descriptor(number: number, kind: kind)
        let outcome: MeasurementOutcome
        if let failure {
            outcome = .unavailable(failure.reason)
        } else if let candidate = candidates.first(where: { $0.number == number }) {
            if candidate.isCredible, let bandwidth = candidate.bandwidthHz {
                let warnings: [MeasurementWarning] =
                    cautions.contains(.highPitch) || cautions.contains(.ceilingSensitive)
                        || cautions.contains(.pitchSupportMismatch)
                    ? [.exploratoryApplicability, .lowConfidence] : [.exploratoryApplicability]
                outcome = .available(
                    try ScalarEstimate(
                        value: kind == .formantFrequency ? candidate.frequencyHz : bandwidth,
                        warnings: warnings))
            } else {
                outcome = .unavailable(.lowConfidence)
            }
        } else {
            outcome = .unavailable(.insufficientData)
        }
        return try MeasurementResult(
            measurement: descriptor, profile: profile, timing: timing, outcome: outcome)
    }

}

struct FormantSelection {
    let cautions: [FormantCaution]
    let candidates: [BurgFormantCandidate]

    init(
        roots: [FormantRoot], profile: BurgFormantProfile, gainDB: Double?, source: SourceInterval,
        pitch: FormantPitchEvidence?
    ) {
        let rate = Double(profile.analysisSampleRate)
        let ceiling = Double(profile.ceilingHz)
        let matchedPitch = pitch?.source == source ? pitch?.frequencyHz : nil
        var cautions: [FormantCaution] = []
        if matchedPitch == nil {
            cautions.append(pitch == nil ? .pitchUnassessed : .pitchSupportMismatch)
        }
        if let matchedPitch, matchedPitch >= 300 { cautions.append(.highPitch) }
        let weak = gainDB.map { $0 < 3 } ?? false
        if weak { cautions.append(.weakPrediction) }
        // Map a conjugate pair once. True real roots have roundoff-scale imaginary components.
        let upper = roots.map { z in
            abs(z.imaginary) <= 64 * Double.ulpOfOne * max(1, z.magnitude) ? FormantRoot(z.real) : z
        }.filter { $0.imaginary >= 0 }.sorted {
            (atan2($0.imaginary, $0.real), -$0.magnitude) < (
                atan2($1.imaginary, $1.real), -$1.magnitude
            )
        }
        var rank = 0
        var list: [BurgFormantCandidate] = []
        for z in upper {
            let frequency = atan2(abs(z.imaginary), z.real) * rate / (2 * .pi)
            let radius = z.magnitude
            let bandwidth = radius > 0 && radius < 1 ? -log(radius) * rate / .pi : nil
            var reasons: [FormantRejection] = []
            if abs(z.imaginary) <= 1e-8 { reasons.append(.realOrNearReal) }
            if radius == 0 {
                reasons.append(.zeroRadius)
            } else if radius >= 1 {
                reasons.append(.unstablePole)
            }
            if frequency < BurgFormantProfile.edgeExclusionHz
                || frequency > ceiling - BurgFormantProfile.edgeExclusionHz
            {
                reasons.append(.outsideEdgeMargin)
            }
            let admitted = reasons.isEmpty
            if admitted {
                rank += 1
                if bandwidth! > min(1000, frequency) { reasons.append(.broadBandwidth) }
                if let matchedPitch, frequency < 2 * matchedPitch {
                    reasons.append(.sparseHarmonics)
                }
                if weak { reasons.append(.weakPrediction) }
            }
            list.append(
                .init(
                    real: z.real, imaginary: z.imaginary, radius: radius, frequencyHz: frequency,
                    bandwidthHz: bandwidth, number: admitted ? rank : nil, rejections: reasons))
        }
        if !roots.isEmpty
            && (rank < min(3, profile.maximumFormants)
                || list.contains(where: { $0.number != nil && $0.frequencyHz > 0.9 * ceiling }))
        {
            cautions.append(.ceilingSensitive)
        }
        self.cautions = cautions
        candidates = list
    }
}
