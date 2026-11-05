import Foundation

/// A case-sensitive ASCII name and a separately versioned numerical definition.
public struct VersionedIdentifier: Sendable, Hashable, Codable {
    public let name: String
    public let version: UInt32

    public init(name: String, version: UInt32) throws {
        guard validContractIdentifier(name) else { throw ContractError.invalidIdentifier }
        guard version > 0 else { throw ContractError.invalidVersion }
        self.name = name
        self.version = version
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case name, version }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            name: c.decode(String.self, forKey: .name),
            version: c.decode(UInt32.self, forKey: .version))
    }
}

/// The measurement definition is separate from the algorithm used to estimate it.
public enum MeasurementKind: String, Sendable, Hashable, Codable, CaseIterable {
    case cpp, cpps, fundamentalFrequency, harmonicToNoiseRatio
    case rms, peakAmplitude, meanSquare, crestFactor, levelDBFS, calibratedSPL, clippingFraction,
        kWeightedEnergy
    case jitterLocal, jitterAbsolute, jitterRAP, jitterPPQ5, jitterDDP
    case shimmerLocal, shimmerDB, shimmerAPQ3, shimmerAPQ5, shimmerAPQ11, shimmerDDA
    case spectralCentroid, spectralSpread, spectralSkewness, spectralKurtosis, spectralFlatness
    case spectralSlope, spectralBandEnergyRatio, formantFrequency, formantBandwidth
    case h1MinusH2, correctedH1MinusH2

    public func accepts(_ unit: MeasurementUnit) -> Bool {
        switch self {
        case .cpp, .cpps, .harmonicToNoiseRatio, .shimmerDB, .h1MinusH2, .correctedH1MinusH2:
            unit == .decibelsRatio
        case .fundamentalFrequency, .spectralCentroid, .spectralSpread, .formantFrequency,
            .formantBandwidth:
            unit == .hertz
        case .rms, .peakAmplitude: unit == .normalizedAmplitude
        case .levelDBFS: unit == .decibelsFullScale
        case .calibratedSPL: unit == .decibelsSPL
        case .jitterAbsolute: unit == .seconds
        case .clippingFraction, .jitterLocal, .jitterRAP, .jitterPPQ5, .jitterDDP,
            .shimmerLocal, .shimmerAPQ3, .shimmerAPQ5, .shimmerAPQ11, .shimmerDDA:
            unit == .fraction || unit == .percent
        case .meanSquare, .kWeightedEnergy: unit == .normalizedSquaredAmplitude
        case .crestFactor: unit == .dimensionless || unit == .decibelsRatio
        case .spectralSkewness, .spectralKurtosis, .spectralFlatness: unit == .dimensionless
        case .spectralSlope: unit == .decibelsPerOctave || unit == .decibelsPerHertz
        case .spectralBandEnergyRatio: unit == .dimensionless || unit == .decibelsRatio
        }
    }
}

/// dBFS, calibrated SPL, and dimensionless dB ratios have distinct references.
public enum MeasurementUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case hertz, seconds, samples, normalizedAmplitude, normalizedSquaredAmplitude
    case normalizedAmplitudeSeconds, normalizedSquaredAmplitudeSecondsSquared
    case inverseSeconds, inverseSecondsSquared
    case decibelsRatio, decibelsFullScale, decibelsSPL, decibelsPerOctave, decibelsPerHertz
    case fraction, percent, dimensionless
}

public struct MeasurementDescriptor: Sendable, Hashable, Codable {
    public let kind: MeasurementKind
    public let unit: MeasurementUnit
    public let algorithm: VersionedIdentifier

    public init(kind: MeasurementKind, unit: MeasurementUnit, algorithm: VersionedIdentifier) throws
    {
        guard kind.accepts(unit) else { throw ContractError.invalidUnit }
        self.kind = kind
        self.unit = unit
        self.algorithm = algorithm
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, unit, algorithm }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            kind: c.decode(MeasurementKind.self, forKey: .kind),
            unit: c.decode(MeasurementUnit.self, forKey: .unit),
            algorithm: c.decode(VersionedIdentifier.self, forKey: .algorithm))
    }
}

/// Version/name alone is insufficient: every setting participates in the fingerprint.
public struct ProfileIdentity: Sendable, Hashable, Codable {
    public let identifier: VersionedIdentifier
    public let sha256: String

    public init(identifier: VersionedIdentifier, sha256: String) throws {
        guard sha256.utf8.count == 64,
            sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ContractError.invalidFingerprint }
        self.identifier = identifier
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case identifier, sha256 }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            identifier: c.decode(VersionedIdentifier.self, forKey: .identifier),
            sha256: c.decode(String.self, forKey: .sha256))
    }
}
