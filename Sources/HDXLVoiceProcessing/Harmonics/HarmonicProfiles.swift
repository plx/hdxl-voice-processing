import CryptoKit
import Foundation

/// Centered, pitch-synchronous joint sinusoidal regression on mono PCM.
public struct HarmonicFitProfile: Codable, Sendable, Hashable {
    public let schemaVersion = 1
    public let sourceSampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let declaredBandwidthHz: Double
    public let periods: Int
    public let pitchProfile: ProfileIdentity
    public let pitchAlgorithm: VersionedIdentifier

    public init(
        sourceSampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        declaredBandwidthHz: Double? = nil, periods: Int = 3, pitchProfile: ProfileIdentity,
        pitchAlgorithm: VersionedIdentifier? = nil
    ) throws {
        let nyquist = Double(sourceSampleRate) / 2
        let bandwidth = declaredBandwidthHz ?? nyquist
        guard (8000...192_000).contains(sourceSampleRate), [3, 5].contains(periods),
            bandwidth.isFinite, bandwidth > 0, bandwidth <= nyquist
        else { throw ContractError.invalidConfiguration }
        self.sourceSampleRate = sourceSampleRate
        self.inputPrecision = inputPrecision
        self.declaredBandwidthHz = bandwidth
        self.periods = periods
        self.pitchProfile = pitchProfile
        self.pitchAlgorithm = pitchAlgorithm ?? pitchProfile.identifier
    }

    public static var descriptor: MeasurementDescriptor {
        get throws {
            try MeasurementDescriptor(
                kind: .h1MinusH2, unit: .decibelsRatio,
                algorithm: VersionedIdentifier(name: "h1-h2-joint-hann", version: 1))
        }
    }

    public func identity() throws -> ProfileIdentity {
        try harmonicIdentity(self, descriptor: Self.descriptor)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sourceSampleRate, inputPrecision, declaredBandwidthHz, periods,
            pitchProfile, pitchAlgorithm
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sourceSampleRate: c.decode(Int.self, forKey: .sourceSampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            declaredBandwidthHz: c.decode(Double.self, forKey: .declaredBandwidthHz),
            periods: c.decode(Int.self, forKey: .periods),
            pitchProfile: c.decode(ProfileIdentity.self, forKey: .pitchProfile),
            pitchAlgorithm: c.decode(VersionedIdentifier.self, forKey: .pitchAlgorithm))
    }
}

/// Iseli–Alwan discrete, DC-normalized correction using measured F1/B1 and F2/B2.
public struct HarmonicCorrectionProfile: Codable, Sendable, Hashable {
    public let schemaVersion = 1
    public let fit: HarmonicFitProfile
    public let formants: BurgFormantProfile

    public init(fit: HarmonicFitProfile, formants: BurgFormantProfile) throws {
        guard fit.sourceSampleRate == formants.sourceSampleRate,
            fit.inputPrecision == formants.inputPrecision,
            Double(formants.ceilingHz) <= fit.declaredBandwidthHz
        else { throw ContractError.invalidConfiguration }
        self.fit = fit
        self.formants = formants
    }

    public static var descriptor: MeasurementDescriptor {
        get throws {
            try MeasurementDescriptor(
                kind: .correctedH1MinusH2, unit: .decibelsRatio,
                algorithm: VersionedIdentifier(name: "h1-h2-iseli-measured-f1-f2", version: 1))
        }
    }

    public func identity() throws -> ProfileIdentity {
        try harmonicIdentity(self, descriptor: Self.descriptor)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, fit, formants }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            fit: c.decode(HarmonicFitProfile.self, forKey: .fit),
            formants: c.decode(BurgFormantProfile.self, forKey: .formants))
    }
}

private func harmonicIdentity(_ recipe: some Encodable, descriptor: MeasurementDescriptor) throws
    -> ProfileIdentity
{
    let digest = try SHA256.hash(data: canonicalContractJSON(recipe))
    return try ProfileIdentity(
        identifier: descriptor.algorithm,
        sha256: digest.map { String(format: "%02x", $0) }.joined())
}
