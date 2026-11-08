import Foundation
import HDXLVoiceProcessing

public enum VisualizationUnitConversion: Sendable, Hashable {
    case native, milliseconds, percentage
}

public struct VisualizationUnitLabel: Sendable, Hashable {
    public let symbol: String
    public let spoken: String

    public static func native(_ unit: MeasurementUnit) -> Self {
        switch unit {
        case .hertz: Self(symbol: "Hz", spoken: "hertz")
        case .seconds: Self(symbol: "s", spoken: "seconds")
        case .samples: Self(symbol: "samples", spoken: "source samples")
        case .normalizedAmplitude:
            Self(symbol: "FS", spoken: "normalized amplitude, full scale one")
        case .normalizedSquaredAmplitude:
            Self(symbol: "FS²", spoken: "normalized squared amplitude")
        case .normalizedAmplitudeSeconds:
            Self(symbol: "FS·s", spoken: "normalized amplitude seconds")
        case .normalizedSquaredAmplitudeSecondsSquared:
            Self(symbol: "FS²·s²", spoken: "normalized squared amplitude seconds squared")
        case .inverseSeconds: Self(symbol: "s⁻¹", spoken: "inverse seconds")
        case .inverseSecondsSquared: Self(symbol: "s⁻²", spoken: "inverse seconds squared")
        case .decibelsRatio: Self(symbol: "dB", spoken: "decibels, ratio reference")
        case .decibelsFullScale:
            Self(symbol: "dBFS", spoken: "decibels relative to digital full scale")
        case .decibelsSPL:
            Self(symbol: "dB SPL", spoken: "calibrated sound pressure level in decibels")
        case .decibelsPerOctave: Self(symbol: "dB/octave", spoken: "decibels per octave")
        case .decibelsPerHertz: Self(symbol: "dB/Hz", spoken: "decibels per hertz")
        case .fraction: Self(symbol: "fraction", spoken: "fraction, one equals the whole")
        case .percent: Self(symbol: "%", spoken: "percent")
        case .dimensionless: Self(symbol: "dimensionless", spoken: "dimensionless")
        }
    }
}

public struct VisualizationFormattedValue: Sendable, Hashable {
    public let originalOutcome: MeasurementOutcome
    public let originalUnit: MeasurementUnit
    public let displayValue: Double?
    public let valueText: String
    public let unit: VisualizationUnitLabel
}

/// Formatting is explicit, locale-aware and display-only. Confidence/warnings and
/// raw values remain in originalOutcome. No fraction/percent or dB reference is inferred.
public struct VisualizationValueFormat: Sendable, Hashable {
    public let conversion: VisualizationUnitConversion
    public let maximumFractionDigits: Int
    public static let standard = Self()

    private init() {
        conversion = .native
        maximumFractionDigits = 3
    }

    public init(conversion: VisualizationUnitConversion = .native, maximumFractionDigits: Int = 3)
        throws
    {
        guard (0...12).contains(maximumFractionDigits) else {
            throw VisualizationError.invalidConfiguration
        }
        self.conversion = conversion
        self.maximumFractionDigits = maximumFractionDigits
    }

    public func format(
        _ outcome: MeasurementOutcome, unit: MeasurementUnit, locale: Locale = .current
    ) throws -> VisualizationFormattedValue {
        let factor: Double
        let label: VisualizationUnitLabel
        switch conversion {
        case .native:
            factor = 1
            label = .native(unit)
        case .milliseconds:
            guard unit == .seconds else { throw VisualizationError.unsupportedDisplayConversion }
            factor = 1000
            label = VisualizationUnitLabel(symbol: "ms", spoken: "milliseconds")
        case .percentage:
            guard unit == .fraction || unit == .percent else {
                throw VisualizationError.unsupportedDisplayConversion
            }
            factor = unit == .fraction ? 100 : 1
            label = .native(.percent)
        }
        let display: Double?
        let text: String
        switch outcome {
        case .available(let estimate):
            let value = estimate.value * factor
            guard value.isFinite else { throw VisualizationError.nonfiniteDisplayValue }
            display = value == 0 ? 0 : value
            text = value.formatted(
                .number.locale(locale).precision(.fractionLength(0...maximumFractionDigits)))
        case .unavailable(let reason):
            display = nil
            text = VisualizationText.unavailability(reason)
        }
        return VisualizationFormattedValue(
            originalOutcome: outcome, originalUnit: unit, displayValue: display,
            valueText: text, unit: label)
    }
}

/// Names describe acoustic measures and evidence, never aesthetic or medical scores.
public enum VisualizationText {
    public static func unavailability(_ reason: UnavailabilityReason) -> String {
        switch reason {
        case .insufficientData: "Insufficient data"
        case .silence: "Silence"
        case .clipping: "Clipped input"
        case .unsupportedRange: "Unsupported range"
        case .inapplicableTask: "Not applicable to this task"
        case .lowConfidence: "Low confidence"
        case .invalidInput: "Invalid input"
        case .discontinuity: "Source discontinuity"
        case .analysisFailure: "Analysis failed"
        case .cancelled: "Cancelled"
        case .missingAcquisition: "Missing acquired audio"
        case .excluded: "Excluded audio"
        case .stale: "Expired result"
        }
    }

    public static func measurement(_ kind: MeasurementKind) -> String {
        switch kind {
        case .cpp: "CPP"
        case .cpps: "CPPS"
        case .fundamentalFrequency: "Fundamental frequency"
        case .harmonicToNoiseRatio: "Harmonic-to-noise ratio"
        case .rms: "RMS amplitude"
        case .peakAmplitude: "Peak amplitude"
        case .meanSquare: "Mean-square amplitude"
        case .crestFactor: "Crest factor"
        case .levelDBFS: "Digital level"
        case .calibratedSPL: "Calibrated sound pressure level"
        case .clippingFraction: "Clipped sample fraction"
        case .kWeightedEnergy: "K-weighted energy"
        case .jitterLocal: "Local jitter"
        case .jitterAbsolute: "Absolute jitter"
        case .jitterRAP: "Jitter RAP"
        case .jitterPPQ5: "Jitter PPQ5"
        case .jitterDDP: "Jitter DDP"
        case .shimmerLocal: "Local shimmer"
        case .shimmerDB: "Shimmer in decibels"
        case .shimmerAPQ3: "Shimmer APQ3"
        case .shimmerAPQ5: "Shimmer APQ5"
        case .shimmerAPQ11: "Shimmer APQ11"
        case .shimmerDDA: "Shimmer DDA"
        case .spectralCentroid: "Spectral centroid"
        case .spectralSpread: "Spectral spread"
        case .spectralSkewness: "Spectral skewness"
        case .spectralKurtosis: "Spectral kurtosis"
        case .spectralFlatness: "Spectral flatness"
        case .spectralSlope: "Spectral slope"
        case .spectralBandEnergyRatio: "Spectral band energy ratio"
        case .formantFrequency: "Formant frequency"
        case .formantBandwidth: "Formant bandwidth"
        case .h1MinusH2: "H1–H2"
        case .correctedH1MinusH2: "Corrected H1–H2"
        }
    }
}
