import CryptoKit
import Foundation

/// A typed, explicit algorithm setting. Algorithm factories validate their accepted keys/ranges.
public enum ProfileSetting: Sendable, Hashable, Codable {
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case text(String)

    func validated() throws -> Self {
        switch self {
        case .real(let value):
            guard value.isFinite else { throw ContractError.invalidConfiguration }
            return .real(value == 0 ? 0 : value)
        case .text(let value):
            guard value.utf8.count <= 4096 else { throw ContractError.invalidConfiguration }
            return self
        default: return self
        }
    }

    private enum Kind: String, Codable { case integer, real, boolean, text }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case type, integer, real, boolean, text
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let type = try c.decode(Kind.self, forKey: .type)
        guard c.allKeys.count == 2, c.contains(CodingKeys(rawValue: type.rawValue)!) else {
            throw ContractError.invalidConfiguration
        }
        switch type {
        case .integer: self = .integer(try c.decode(Int64.self, forKey: .integer))
        case .real: self = .real(try c.decode(Double.self, forKey: .real))
        case .boolean: self = .boolean(try c.decode(Bool.self, forKey: .boolean))
        case .text: self = .text(try c.decode(String.self, forKey: .text))
        }
        self = try validated()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch try validated() {
        case .integer(let value):
            try c.encode(Kind.integer, forKey: .type)
            try c.encode(value, forKey: .integer)
        case .real(let value):
            try c.encode(Kind.real, forKey: .type)
            try c.encode(value, forKey: .real)
        case .boolean(let value):
            try c.encode(Kind.boolean, forKey: .type)
            try c.encode(value, forKey: .boolean)
        case .text(let value):
            try c.encode(Kind.text, forKey: .type)
            try c.encode(value, forKey: .text)
        }
    }
}

/// An explicit channel index or an arithmetic mean across all source channels.
public struct PCMChannelSelection: Sendable, Hashable, Codable {
    public let channelIndex: Int?
    public static let arithmeticMean = Self()
    private init() { channelIndex = nil }
    public init(channelIndex: Int) throws {
        guard channelIndex >= 0 else { throw ContractError.invalidConfiguration }
        self.channelIndex = channelIndex
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case channelIndex }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard c.contains(.channelIndex) else { throw ContractError.invalidConfiguration }
        if let index = try c.decodeIfPresent(Int.self, forKey: .channelIndex) {
            try self.init(channelIndex: index)
        } else {
            self = .arithmeticMean
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channelIndex, forKey: .channelIndex)
    }
}

/// Structurally validated, immutable configuration; this is not a claim of algorithm conformance.
///
/// Executable algorithm factories must additionally reject unknown/missing settings and
/// unsupported combinations. All numerical choices, including reference-specific defaults,
/// must be materialized in these dictionaries before fingerprinting; see the contract ADR.
public struct AnalysisProfile: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let identifier: VersionedIdentifier
    public let measurement: MeasurementDescriptor
    public let inputFormat: PCMFormat
    public let channels: PCMChannelSelection
    public let precision: AnalysisPrecision
    /// Frame and hop lengths at the analysis rate, after any explicitly configured resampling.
    public let frameLength: Int
    public let hopLength: Int
    public let analysisSampleRate: Double
    public let window: VersionedIdentifier
    public let preprocessing: [String: ProfileSetting]
    public let algorithmSettings: [String: ProfileSetting]
    public let partialWindowPolicy: PartialWindowPolicy

    public init(
        identifier: VersionedIdentifier, measurement: MeasurementDescriptor,
        inputFormat: PCMFormat, channels: PCMChannelSelection, precision: AnalysisPrecision,
        frameLength: Int, hopLength: Int, analysisSampleRate: Double,
        window: VersionedIdentifier, preprocessing: [String: ProfileSetting],
        algorithmSettings: [String: ProfileSetting], partialWindowPolicy: PartialWindowPolicy
    ) throws {
        guard frameLength > 0, hopLength > 0, analysisSampleRate.isFinite, analysisSampleRate > 0,
            (Double(frameLength) / analysisSampleRate).isFinite,
            (Double(hopLength) / analysisSampleRate).isFinite,
            channels.channelIndex.map({ $0 < inputFormat.channelCount }) ?? true,
            !frameLength.multipliedReportingOverflow(by: inputFormat.channelCount).overflow
        else { throw ContractError.invalidConfiguration }
        func validate(_ settings: [String: ProfileSetting]) throws -> [String: ProfileSetting] {
            guard settings.count <= 256, settings.keys.allSatisfy(validContractIdentifier) else {
                throw ContractError.invalidConfiguration
            }
            return try settings.mapValues { try $0.validated() }
        }
        self.schemaVersion = 1
        self.identifier = identifier
        self.measurement = measurement
        self.inputFormat = inputFormat
        self.channels = channels
        self.precision = precision
        self.frameLength = frameLength
        self.hopLength = hopLength
        self.analysisSampleRate = analysisSampleRate
        self.window = window
        self.preprocessing = try validate(preprocessing)
        self.algorithmSettings = try validate(algorithmSettings)
        self.partialWindowPolicy = partialWindowPolicy
    }

    /// Version-1 canonical bytes: compact UTF-8 JSON, sorted keys, unescaped slashes,
    /// finite numbers, and normalized negative zero. Not an RFC 8785 implementation.
    public func canonicalJSON() throws -> Data { try canonicalContractJSON(self) }

    /// Compute once at processor setup, not per frame; includes the entire encoded profile.
    public func identity() throws -> ProfileIdentity {
        let digest = SHA256.hash(data: try canonicalJSON())
        return try ProfileIdentity(
            identifier: identifier, sha256: digest.map { String(format: "%02x", $0) }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, identifier, measurement, inputFormat, channels, precision
        case frameLength, hopLength, analysisSampleRate, window, preprocessing, algorithmSettings,
            partialWindowPolicy
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            identifier: c.decode(VersionedIdentifier.self, forKey: .identifier),
            measurement: c.decode(MeasurementDescriptor.self, forKey: .measurement),
            inputFormat: c.decode(PCMFormat.self, forKey: .inputFormat),
            channels: c.decode(PCMChannelSelection.self, forKey: .channels),
            precision: c.decode(AnalysisPrecision.self, forKey: .precision),
            frameLength: c.decode(Int.self, forKey: .frameLength),
            hopLength: c.decode(Int.self, forKey: .hopLength),
            analysisSampleRate: c.decode(Double.self, forKey: .analysisSampleRate),
            window: c.decode(VersionedIdentifier.self, forKey: .window),
            preprocessing: c.decode([String: ProfileSetting].self, forKey: .preprocessing),
            algorithmSettings: c.decode([String: ProfileSetting].self, forKey: .algorithmSettings),
            partialWindowPolicy: c.decode(PartialWindowPolicy.self, forKey: .partialWindowPolicy))
    }
}
