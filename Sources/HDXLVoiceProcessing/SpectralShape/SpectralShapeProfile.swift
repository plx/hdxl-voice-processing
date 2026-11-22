import CryptoKit
import Foundation

/// Frequency limits in hertz on the source spectrum's frequency grid.
public struct SpectralFrequencyBand: Sendable, Hashable, Codable {
    public let lowerHz: Double
    public let upperHz: Double

    public init(lowerHz: Double, upperHz: Double) throws {
        guard lowerHz.isFinite, upperHz.isFinite, lowerHz >= 0, upperHz > lowerHz else {
            throw ContractError.invalidConfiguration
        }
        self.lowerHz = lowerHz == 0 ? 0 : lowerHz
        self.upperHz = upperHz
    }

    func contains(_ band: Self) -> Bool { lowerHz <= band.lowerHz && upperHz >= band.upperHz }

    private enum CodingKeys: String, CodingKey, CaseIterable { case lowerHz, upperHz }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            lowerHz: c.decode(Double.self, forKey: .lowerHz),
            upperHz: c.decode(Double.self, forKey: .upperHz))
    }
}

/// The name identifies the user's or researcher's definition, including which band is on top.
public struct SpectralBandRatioDefinition: Sendable, Hashable, Codable {
    public let name: VersionedIdentifier
    public let numerator: SpectralFrequencyBand
    public let denominator: SpectralFrequencyBand

    public init(
        name: VersionedIdentifier, numerator: SpectralFrequencyBand,
        denominator: SpectralFrequencyBand
    ) {
        self.name = name
        self.numerator = numerator
        self.denominator = denominator
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case name, numerator, denominator }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            name: c.decode(VersionedIdentifier.self, forKey: .name),
            numerator: c.decode(SpectralFrequencyBand.self, forKey: .numerator),
            denominator: c.decode(SpectralFrequencyBand.self, forKey: .denominator))
    }
}

public enum SpectralShapeSource: String, Sendable, Codable { case frame, longTermSpectrum }
public enum SpectralShapeWeighting: String, Sendable, Codable { case power, binRMSMagnitude }
public enum SpectralSlopeCoordinate: String, Sendable, Codable { case hertz, octavesFromOneHertz }
public enum SpectralRegressionWeighting: String, Sendable, Codable { case uniform, shapeWeight }

public struct SpectralShapeProfile: Sendable, Hashable, Codable {
    public let source: SpectralShapeSource
    public let weighting: SpectralShapeWeighting
    public let analysisBand: SpectralFrequencyBand
    public let includeDC: Bool
    /// Relative power dB. With nil, exact zeros give flatness zero and are excluded from log fits.
    public let relativeLogFloorDB: Double?
    public let rollOffFraction: Double
    public let bandRatio: SpectralBandRatioDefinition
    public let fitBand: SpectralFrequencyBand
    public let fitCoordinate: SpectralSlopeCoordinate
    public let regressionWeighting: SpectralRegressionWeighting
    public let minimumFitBins: Int

    public init(
        source: SpectralShapeSource, weighting: SpectralShapeWeighting = .power,
        analysisBand: SpectralFrequencyBand, includeDC: Bool = true,
        relativeLogFloorDB: Double? = nil, rollOffFraction: Double = 0.85,
        bandRatio: SpectralBandRatioDefinition, fitBand: SpectralFrequencyBand,
        fitCoordinate: SpectralSlopeCoordinate = .octavesFromOneHertz,
        regressionWeighting: SpectralRegressionWeighting = .uniform, minimumFitBins: Int = 3
    ) throws {
        guard rollOffFraction.isFinite, rollOffFraction > 0, rollOffFraction <= 1,
            (2...Int(Int32.max)).contains(minimumFitBins), analysisBand.contains(fitBand),
            analysisBand.contains(bandRatio.numerator), analysisBand.contains(bandRatio.denominator)
        else { throw ContractError.invalidConfiguration }
        if let floor = relativeLogFloorDB {
            guard floor.isFinite, (-3000...0).contains(floor) else {
                throw ContractError.invalidConfiguration
            }
        }
        self.source = source
        self.weighting = weighting
        self.analysisBand = analysisBand
        self.includeDC = includeDC
        self.relativeLogFloorDB = relativeLogFloorDB.map { $0 == 0 ? 0 : $0 }
        self.rollOffFraction = rollOffFraction
        self.bandRatio = bandRatio
        self.fitBand = fitBand
        self.fitCoordinate = fitCoordinate
        self.regressionWeighting = regressionWeighting
        self.minimumFitBins = minimumFitBins
    }

    /// Both the descriptor settings and the upstream product's complete identity participate.
    public func identity(for layout: SpectrogramLayout, selectionProfile: ProfileIdentity? = nil)
        throws -> ProfileIdentity
    {
        struct Parameters: Encodable {
            let sourceSpectrum: ProfileIdentity
            let selection: ProfileIdentity?
            let settings: SpectralShapeProfile
        }
        let value = Parameters(
            sourceSpectrum: layout.profile, selection: selectionProfile, settings: self)
        return try ProfileIdentity(
            identifier: VersionedIdentifier(
                name: "spectral-shape-" + source.rawValue + "-" + weighting.rawValue, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(value)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, weighting, analysisBand, includeDC, relativeLogFloorDB, rollOffFraction,
            bandRatio
        case fitBand, fitCoordinate, regressionWeighting, minimumFitBins
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            source: c.decode(SpectralShapeSource.self, forKey: .source),
            weighting: c.decode(SpectralShapeWeighting.self, forKey: .weighting),
            analysisBand: c.decode(SpectralFrequencyBand.self, forKey: .analysisBand),
            includeDC: c.decode(Bool.self, forKey: .includeDC),
            relativeLogFloorDB: c.decodeIfPresent(Double.self, forKey: .relativeLogFloorDB),
            rollOffFraction: c.decode(Double.self, forKey: .rollOffFraction),
            bandRatio: c.decode(SpectralBandRatioDefinition.self, forKey: .bandRatio),
            fitBand: c.decode(SpectralFrequencyBand.self, forKey: .fitBand),
            fitCoordinate: c.decode(SpectralSlopeCoordinate.self, forKey: .fitCoordinate),
            regressionWeighting: c.decode(
                SpectralRegressionWeighting.self, forKey: .regressionWeighting),
            minimumFitBins: c.decode(Int.self, forKey: .minimumFitBins))
    }
}
