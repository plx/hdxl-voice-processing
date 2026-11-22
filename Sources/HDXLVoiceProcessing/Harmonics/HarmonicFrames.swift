import Foundation

/// The first unmet dependency. A failure carries no substitute harmonic difference.
public enum HarmonicFailure: String, Error, Sendable, Hashable, Codable {
    case missingPitch, wrongPitchProfile, wrongPitchMeasurement, pitchSupportMismatch
    case missingPitchEstimate, uncertainPitch, pitchOutOfRange, harmonicOutsideBandwidth
    case insufficientNyquistSeparation
    case shortWindow, nonfinitePCM, silence, singularFit, firstHarmonicUnresolved
    case secondHarmonicUnresolved, bothHarmonicsUnresolved, unrepresentableAmplitude
    case missingFormants, wrongFormantProfile, formantSupportMismatch, qualifyingPitchMismatch
    case formantFitFailed, firstFormantUnavailable, secondFormantUnavailable
    case highPitch, clippedInput, unstableCorrection

    var reason: UnavailabilityReason {
        switch self {
        case .missingPitch, .missingPitchEstimate, .missingFormants, .shortWindow: .insufficientData
        case .uncertainPitch, .insufficientNyquistSeparation, .firstHarmonicUnresolved,
            .secondHarmonicUnresolved,
            .bothHarmonicsUnresolved, .firstFormantUnavailable, .secondFormantUnavailable,
            .highPitch:
            .lowConfidence
        case .wrongPitchMeasurement, .wrongPitchProfile, .pitchSupportMismatch,
            .wrongFormantProfile,
            .formantSupportMismatch, .qualifyingPitchMismatch:
            .inapplicableTask
        case .pitchOutOfRange, .harmonicOutsideBandwidth: .unsupportedRange
        case .nonfinitePCM: .invalidInput
        case .silence: .silence
        case .clippedInput: .clipping
        case .singularFit, .formantFitFailed, .unstableCorrection, .unrepresentableAmplitude:
            .analysisFailure
        }
    }
}

/// An owned summary of the pitch dependency. It excludes optional intermediate arrays.
public struct HarmonicPitchObservation: Sendable, Hashable, Encodable {
    public let measurement: MeasurementDescriptor
    public let profile: ProfileIdentity
    public let timing: AnalysisTiming
    public let outcome: MeasurementOutcome

    init(_ result: MeasurementResult) {
        measurement = result.measurement
        profile = result.profile
        timing = result.timing
        outcome = result.outcome
    }
}

/// Peak sinusoidal amplitude relative to one full-scale PCM unit, with no SPL calibration.
public struct HarmonicAmplitude: Sendable, Hashable, Encodable {
    public let frequencyHz: Double
    public let peakFS: Double
    public let peakDBFS: Double
}

public struct RawHarmonicFrame: Sendable, Hashable, Encodable {
    public let configuration: HarmonicFitProfile
    public let pitch: HarmonicPitchObservation?
    /// The returned measurement's timing locates the fitted subwindow. The pitch observation
    /// depends on the entire source frame, including samples outside the fit.
    public let dependencySupport: SourceInterval
    public let measurement: MeasurementResult
    public let first: HarmonicAmplitude?
    public let second: HarmonicAmplitude?
    public let failure: HarmonicFailure?
    public let clipped: Bool
    /// Weighted RMS of the fit residual divided by the input peak.
    public let relativeResidualRMS: Double?
    /// Minimum resolved sinusoidal amplitude divided by the peak of the fitted PCM.
    public let relativeDetectionFloor: Double?
}

/// One measured pole pair and its signed amplification of each source harmonic.
public struct HarmonicFormantContribution: Encodable, Sendable, Hashable {
    public let number: Int
    public let frequencyHz: Double
    public let bandwidthHz: Double
    public let firstGainDB: Double
    public let secondGainDB: Double
    public let nearResonance: Bool
}

/// Full fidelity export includes both source intervals, the qualifying F0, measured formants,
/// individual corrections and the two scalar series with distinct identifiers.
public struct CorrectedHarmonicFrame: Sendable, Hashable, Encodable {
    public let configuration: HarmonicCorrectionProfile
    public let raw: RawHarmonicFrame
    public let formantProfile: ProfileIdentity?
    public let formantWindow: SourceInterval?
    public let formantConditioningSupport: SourceInterval?
    public let formantPitch: FormantPitchEvidence?
    public let formantFailure: FormantFitFailure?
    public let formantCautions: [FormantCaution]
    /// The first supplied rank that failed credibility or numerical checks, including its measured bandwidth and rejections.
    public let unusableFormant: BurgFormantCandidate?
    public let contributions: [HarmonicFormantContribution]
    public let correctedFirstDBFS: Double?
    public let correctedSecondDBFS: Double?
    public let measurement: MeasurementResult
    public let dependencySupport: SourceInterval
    public let failure: HarmonicFailure?
}
