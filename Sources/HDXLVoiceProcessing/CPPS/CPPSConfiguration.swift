import CryptoKit
import Foundation

public enum CPPSError: Error, Sendable, Equatable {
    case invalidConfiguration, capacityExceeded, profileMismatch, unexpectedFrame
    case invalidState, invalidInput, reentrantCall, incompleteInput
}

/// The normal Praat 7.0.02 rectangular path. Temporal integration precedes
/// quefrency integration; each axis activates only when floor(width/step) > 1.
public enum CPPSSmoothingDefinition: String, Sendable, Hashable, Codable {
    case praat7002InterpolatedPower
}

public enum CPPSEdgePolicy: String, Sendable, Hashable, Codable {
    case normalizeAvailableSupport
}

/// CPPS is computed from smoothed linear power, never by smoothing scalar CPP.
/// Pretrend clips negative fitted dB residuals before converting back to power.
/// Final prominence always fits the resulting curve again.
public struct CPPSConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let definition: CPPSSmoothingDefinition
    public let edgePolicy: CPPSEdgePolicy
    public let timeWindowSeconds: Double
    public let quefrencyWindowSeconds: Double
    public let subtractTrendBeforeSmoothing: Bool
    /// Retained in identity. The pinned CPPS matrix path does not use this value.
    public let pitchTolerance: Double
    public let prominence: CPPConfiguration

    public init(
        timeWindowSeconds: Double = 0.01, quefrencyWindowSeconds: Double = 0.001,
        subtractTrendBeforeSmoothing: Bool = false, pitchTolerance: Double = 0.05,
        prominence: CPPConfiguration
    ) throws {
        guard timeWindowSeconds.isFinite, (0...1).contains(timeWindowSeconds),
            quefrencyWindowSeconds.isFinite, (0...1).contains(quefrencyWindowSeconds),
            pitchTolerance.isFinite, (0...1).contains(pitchTolerance)
        else { throw CPPSError.invalidConfiguration }
        schemaVersion = 1
        definition = .praat7002InterpolatedPower
        edgePolicy = .normalizeAvailableSupport
        self.timeWindowSeconds = timeWindowSeconds == 0 ? 0 : timeWindowSeconds
        self.quefrencyWindowSeconds = quefrencyWindowSeconds == 0 ? 0 : quefrencyWindowSeconds
        self.subtractTrendBeforeSmoothing = subtractTrendBeforeSmoothing
        self.pitchTolerance = pitchTolerance == 0 ? 0 : pitchTolerance
        self.prominence = prominence
    }

    public static func murtonRecipePraat7() throws -> Self {
        try Self(prominence: .murtonRecipePraat7())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, definition, edgePolicy, timeWindowSeconds, quefrencyWindowSeconds
        case subtractTrendBeforeSmoothing, pitchTolerance, prominence
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            timeWindowSeconds: c.decode(Double.self, forKey: .timeWindowSeconds),
            quefrencyWindowSeconds: c.decode(Double.self, forKey: .quefrencyWindowSeconds),
            subtractTrendBeforeSmoothing: c.decode(
                Bool.self, forKey: .subtractTrendBeforeSmoothing),
            pitchTolerance: c.decode(Double.self, forKey: .pitchTolerance),
            prominence: c.decode(CPPConfiguration.self, forKey: .prominence))
        guard try c.decode(CPPSSmoothingDefinition.self, forKey: .definition) == definition,
            try c.decode(CPPSEdgePolicy.self, forKey: .edgePolicy) == edgePolicy
        else { throw CPPSError.invalidConfiguration }
    }
}

/// A complete PCM recipe and CPPS definition. Mask selection and aggregation are
/// separately identified downstream; they do not alter this per-frame algorithm.
public struct CPPSProfile: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let cepstrogram: CepstrogramConfiguration
    public let settings: CPPSConfiguration

    public init(cepstrogram: CepstrogramConfiguration, settings: CPPSConfiguration) {
        schemaVersion = 1
        self.cepstrogram = cepstrogram
        self.settings = settings
    }

    /// Modern implementation of the published recipe, with an explicit source rate
    /// and bandwidth declaration. This does not assert historical Praat 6 parity.
    public static func murtonRecipePraat7(
        sourceSampleRate: Int, declaredInputBandwidthHz: Double,
        inputPrecision: AnalysisPrecision = .float64
    ) throws -> Self {
        try Self(
            cepstrogram: CepstrogramConfiguration(
                sourceSampleRate: sourceSampleRate, inputPrecision: inputPrecision,
                declaredInputBandwidthHz: declaredInputBandwidthHz),
            settings: .murtonRecipePraat7())
    }

    public func identity() throws -> ProfileIdentity {
        let name =
            cepstrogram.previewHopLength == nil
            ? "praat-7.0.02-cpps" : "finite-fir-preview-cpps"
        return try ProfileIdentity(
            identifier: VersionedIdentifier(name: name, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, cepstrogram, settings
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        self.init(
            cepstrogram: try c.decode(CepstrogramConfiguration.self, forKey: .cepstrogram),
            settings: try c.decode(CPPSConfiguration.self, forKey: .settings))
    }
}

public struct CPPSLayout: Sendable, Hashable {
    public let prominence: CPPLayout
    public let temporalSmoothingIsActive: Bool
    public let quefrencySmoothingIsActive: Bool
    /// Includes the interpolation sample outside a fractional half-window.
    public let lookaheadFrames: Int
    public let lookaheadSeconds: Double
    public let ringFrameCapacity: Int

    public init(profile: CPPSProfile) throws {
        let c = profile.cepstrogram
        let s = profile.settings
        let active = floor(s.timeWindowSeconds / c.hopSeconds) > 1
        let radius = active ? Int(ceil(s.timeWindowSeconds / (2 * c.hopSeconds))) : 0
        let capacity = 2 * radius + 1
        guard capacity <= 2049, capacity * c.frame.binCount <= 8_388_608 else {
            throw CPPSError.capacityExceeded
        }
        prominence = try CPPLayout(profile: CPPProfile(frame: c.frame, settings: s.prominence))
        temporalSmoothingIsActive = active
        quefrencySmoothingIsActive =
            floor(s.quefrencyWindowSeconds / c.frame.quefrencyStepSeconds) > 1
        lookaheadFrames = radius
        lookaheadSeconds = Double(radius) * c.hopSeconds
        ringFrameCapacity = capacity
    }
}
