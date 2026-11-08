import Foundation

/// Complete numerical recipes, not just display names or fingerprints. Decoding
/// preserves the recipe; it neither prepares a processor nor approves a target.
/// An unknown recipe or version is refused rather than reinterpreted.
public enum SessionArchiveProfile: Sendable, Hashable, Codable {
    case analysis(AnalysisProfile)
    case schedule(AnalysisScheduleProfile)
    case levels(LevelConfiguration)
    case yin(YINConfiguration)
    case trackedYIN(YINProfile)
    case cpp(CPPProfile)
    case cpps(CPPSProfile)
    case hnr(HNRConfiguration)
    case hnrStatistic(HNRStatisticProfile)

    public func identity() throws -> ProfileIdentity {
        switch self {
        case .analysis(let value): try value.identity()
        case .schedule(let value): try value.identity()
        case .levels(let value): try value.identity()
        case .yin(let value): try value.identity()
        case .trackedYIN(let value): try value.identity()
        case .cpp(let value): try value.identity()
        case .cpps(let value): try value.identity()
        case .hnr(let value): try value.identity()
        case .hnrStatistic(let value): try value.identity()
        }
    }

    /// A standalone CPP kernel consumes an already formed cepstrum and cannot
    /// establish the original PCM rate. Its source interval retains that rate;
    /// only a recipe with an upstream cepstrogram can cross-check it here.
    public var sourceSampleRate: Double? {
        switch self {
        case .analysis(let value): value.inputFormat.sampleRate
        case .schedule(let value): value.inputFormat.sampleRate
        case .levels(let value): Double(value.sampleRate)
        case .yin(let value): Double(value.sampleRate)
        case .trackedYIN(let value): Double(value.estimator.sampleRate)
        case .cpp(let value): value.cepstrogram.map { Double($0.conditioning.sourceSampleRate) }
        case .cpps(let value): Double(value.cepstrogram.conditioning.sourceSampleRate)
        case .hnr(let value): Double(value.sampleRate)
        case .hnrStatistic(let value): Double(value.measurement.sampleRate)
        }
    }

    /// Cache at catalog insertion. In a schedule, the scalar's algorithm identity
    /// is the native kernel identity and its profile identity is the full schedule.
    func descriptors() throws -> Set<MeasurementDescriptor> {
        switch self {
        case .analysis(let value): return [value.measurement]
        case .schedule(let value):
            var result: Set<MeasurementDescriptor> = []
            if let levels = value.levels {
                result.formUnion(
                    try Self.levels(levels).descriptors().filter {
                        !($0.kind == .crestFactor && $0.unit == .decibelsRatio)
                            && !($0.kind == .clippingFraction && $0.unit == .percent)
                    })
            }
            if let pitch = value.pitch {
                result.formUnion(try Self.yin(pitch.estimator).descriptors())
                if pitch.tracker != nil {
                    result.formUnion(try Self.trackedYIN(pitch).descriptors())
                }
            }
            if let cpps = value.cpps {
                result.formUnion(try Self.cpps(cpps).descriptors())
                result.formUnion(
                    try Self.cpp(
                        CPPProfile(
                            cepstrogram: cpps.cepstrogram, settings: cpps.settings.prominence)
                    ).descriptors())
            }
            if let hnr = value.hnr {
                result.formUnion(try Self.hnr(hnr).descriptors())
            }
            return result
        case .levels:
            let algorithm = try identity().identifier
            let pairs: [(MeasurementKind, MeasurementUnit)] = [
                (.meanSquare, .normalizedSquaredAmplitude), (.rms, .normalizedAmplitude),
                (.peakAmplitude, .normalizedAmplitude), (.crestFactor, .dimensionless),
                (.crestFactor, .decibelsRatio), (.levelDBFS, .decibelsFullScale),
                (.clippingFraction, .fraction), (.clippingFraction, .percent),
                (.kWeightedEnergy, .normalizedSquaredAmplitude),
            ]
            return try Set(
                pairs.map {
                    try MeasurementDescriptor(kind: $0.0, unit: $0.1, algorithm: algorithm)
                })
        case .trackedYIN(let profile):
            guard profile.tracker != nil else { throw SessionArchiveError.incompatibleProfile }
            return [
                try MeasurementDescriptor(
                    kind: .fundamentalFrequency, unit: .hertz, algorithm: identity().identifier)
            ]
        case .yin:
            return [
                try MeasurementDescriptor(
                    kind: .fundamentalFrequency, unit: .hertz, algorithm: identity().identifier)
            ]
        case .cpp:
            return [
                try MeasurementDescriptor(
                    kind: .cpp, unit: .decibelsRatio, algorithm: identity().identifier)
            ]
        case .cpps:
            return [
                try MeasurementDescriptor(
                    kind: .cpps, unit: .decibelsRatio, algorithm: identity().identifier)
            ]
        case .hnr, .hnrStatistic:
            return [
                try MeasurementDescriptor(
                    kind: .harmonicToNoiseRatio, unit: .decibelsRatio,
                    algorithm: identity().identifier)
            ]
        }
    }

    private enum Kind: String, Codable {
        case analysis, schedule, levels, yin, trackedYIN, cpp, cpps, hnr, hnrStatistic
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, recipe }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .analysis: self = .analysis(try c.decode(AnalysisProfile.self, forKey: .recipe))
        case .schedule:
            self = .schedule(try c.decode(AnalysisScheduleProfile.self, forKey: .recipe))
        case .levels: self = .levels(try c.decode(LevelConfiguration.self, forKey: .recipe))
        case .yin: self = .yin(try c.decode(YINConfiguration.self, forKey: .recipe))
        case .trackedYIN: self = .trackedYIN(try c.decode(YINProfile.self, forKey: .recipe))
        case .cpp: self = .cpp(try c.decode(CPPProfile.self, forKey: .recipe))
        case .cpps: self = .cpps(try c.decode(CPPSProfile.self, forKey: .recipe))
        case .hnr: self = .hnr(try c.decode(HNRConfiguration.self, forKey: .recipe))
        case .hnrStatistic:
            self = .hnrStatistic(try c.decode(HNRStatisticProfile.self, forKey: .recipe))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func encode(_ kind: Kind, _ recipe: some Encodable) throws {
            try c.encode(kind, forKey: .kind)
            try c.encode(recipe, forKey: .recipe)
        }
        switch self {
        case .analysis(let value): try encode(.analysis, value)
        case .schedule(let value): try encode(.schedule, value)
        case .levels(let value): try encode(.levels, value)
        case .yin(let value): try encode(.yin, value)
        case .trackedYIN(let value): try encode(.trackedYIN, value)
        case .cpp(let value): try encode(.cpp, value)
        case .cpps(let value): try encode(.cpps, value)
        case .hnr(let value): try encode(.hnr, value)
        case .hnrStatistic(let value): try encode(.hnrStatistic, value)
        }
    }
}
