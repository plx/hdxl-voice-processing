import CryptoKit
import Foundation

public enum ConditioningError: Error, Sendable, Equatable {
    case unsupportedRate, insufficientInputBandwidth, invalidFrequency, invalidQuality
    case precisionMismatch, capacityExceeded, unexpectedInterval, insufficientData
    case nonfiniteInput, nonfiniteResult, invalidState, reentrantCall
}

/// Exact output/input sample-rate ratio; phase clocks do not accumulate floating-point steps.
public struct ResamplingRatio: Sendable, Hashable, Codable {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int, denominator: Int) throws {
        guard (1...192_000).contains(numerator), (1...192_000).contains(denominator) else {
            throw ConditioningError.unsupportedRate
        }
        var a = numerator
        var b = denominator
        while b != 0 { (a, b) = (b, a % b) }
        self.numerator = numerator / a
        self.denominator = denominator / a
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case numerator, denominator }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            numerator: c.decode(Int.self, forKey: .numerator),
            denominator: c.decode(Int.self, forKey: .denominator))
    }
}

/// These are different numerical profiles, with different boundaries, grids, and delay.
public enum ConditioningMethod: Sendable, Hashable, Codable {
    case praat7WholeInterval(interpolationDepth: Int)
    case streamingPreview(lobes: Int, cutoffFraction: Double)

    func validated() throws -> Self {
        switch self {
        case .praat7WholeInterval(let depth):
            guard (1...128).contains(depth) else { throw ConditioningError.invalidQuality }
        case .streamingPreview(let lobes, let fraction):
            guard (8...64).contains(lobes), fraction.isFinite, (0.5...0.98).contains(fraction)
            else {
                throw ConditioningError.invalidQuality
            }
        }
        return self
    }
    var identifierName: String {
        switch self {
        case .praat7WholeInterval: "praat7-whole-interval-conditioning"
        case .streamingPreview: "blackman-polyphase-preview-conditioning"
        }
    }
    private enum Kind: String, Codable { case praat7WholeInterval, streamingPreview }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, interpolationDepth, lobes, cutoffFraction
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .praat7WholeInterval:
            guard Set(c.allKeys) == [.kind, .interpolationDepth] else {
                throw ConditioningError.invalidQuality
            }
            self = .praat7WholeInterval(
                interpolationDepth: try c.decode(Int.self, forKey: .interpolationDepth))
        case .streamingPreview:
            guard Set(c.allKeys) == [.kind, .lobes, .cutoffFraction] else {
                throw ConditioningError.invalidQuality
            }
            self = .streamingPreview(
                lobes: try c.decode(Int.self, forKey: .lobes),
                cutoffFraction: try c.decode(Double.self, forKey: .cutoffFraction))
        }
        self = try validated()
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch try validated() {
        case .praat7WholeInterval(let depth):
            try c.encode(Kind.praat7WholeInterval, forKey: .kind)
            try c.encode(depth, forKey: .interpolationDepth)
        case .streamingPreview(let lobes, let fraction):
            try c.encode(Kind.streamingPreview, forKey: .kind)
            try c.encode(lobes, forKey: .lobes)
            try c.encode(fraction, forKey: .cutoffFraction)
        }
    }
}

public enum ConditioningGainPolicy: String, Sendable, Hashable, Codable { case none }

/// Mono conditioning settings. Rates are integer Hz; unsupported rates are never rounded.
/// Declared input bandwidth is supplied by the caller, not inferred from microphone hardware.
/// Required bandwidth checks source/target capability, not a guarantee of a perfectly flat filter.
public struct ConditioningConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sourceSampleRate: Int
    public let targetSampleRate: Int
    public let ratio: ResamplingRatio
    public let precision: AnalysisPrecision
    public let method: ConditioningMethod
    /// nil disables the filter; zero means a first difference, with unchanged first sample.
    public let preEmphasisFromHz: Double?
    public let declaredInputBandwidthHz: Double
    public let requiredInputBandwidthHz: Double
    public let gainPolicy: ConditioningGainPolicy

    public var preEmphasisCoefficient: Double? {
        preEmphasisFromHz.map { exp(-2 * .pi * $0 / Double(targetSampleRate)) }
    }
    public init(
        sourceSampleRate: Int, targetSampleRate: Int, precision: AnalysisPrecision,
        method: ConditioningMethod, preEmphasisFromHz: Double?,
        declaredInputBandwidthHz: Double, requiredInputBandwidthHz: Double
    ) throws {
        guard (4000...192_000).contains(sourceSampleRate),
            (4000...192_000).contains(targetSampleRate)
        else {
            throw ConditioningError.unsupportedRate
        }
        guard preEmphasisFromHz.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw ConditioningError.invalidFrequency
        }
        guard declaredInputBandwidthHz.isFinite, requiredInputBandwidthHz.isFinite,
            declaredInputBandwidthHz > 0, declaredInputBandwidthHz <= Double(sourceSampleRate) / 2,
            requiredInputBandwidthHz > 0, requiredInputBandwidthHz <= declaredInputBandwidthHz,
            requiredInputBandwidthHz <= Double(targetSampleRate) / 2
        else { throw ConditioningError.insufficientInputBandwidth }
        let ratio = try ResamplingRatio(numerator: targetSampleRate, denominator: sourceSampleRate)
        if case .streamingPreview = method, ratio.numerator > 4096 {
            throw ConditioningError.capacityExceeded
        }
        self.schemaVersion = 1
        self.sourceSampleRate = sourceSampleRate
        self.targetSampleRate = targetSampleRate
        self.ratio = ratio
        self.precision = precision
        self.method = try method.validated()
        self.preEmphasisFromHz = preEmphasisFromHz.map { $0 == 0 ? 0 : $0 }
        self.declaredInputBandwidthHz = declaredInputBandwidthHz
        self.requiredInputBandwidthHz = requiredInputBandwidthHz
        self.gainPolicy = .none
    }
    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: method.identifierName, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sourceSampleRate, targetSampleRate, ratio, precision, method
        case preEmphasisFromHz, declaredInputBandwidthHz, requiredInputBandwidthHz, gainPolicy
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        guard c.contains(.preEmphasisFromHz) else { throw ContractError.invalidConfiguration }
        try self.init(
            sourceSampleRate: c.decode(Int.self, forKey: .sourceSampleRate),
            targetSampleRate: c.decode(Int.self, forKey: .targetSampleRate),
            precision: c.decode(AnalysisPrecision.self, forKey: .precision),
            method: c.decode(ConditioningMethod.self, forKey: .method),
            preEmphasisFromHz: c.decodeIfPresent(Double.self, forKey: .preEmphasisFromHz),
            declaredInputBandwidthHz: c.decode(Double.self, forKey: .declaredInputBandwidthHz),
            requiredInputBandwidthHz: c.decode(Double.self, forKey: .requiredInputBandwidthHz))
        guard try c.decode(ResamplingRatio.self, forKey: .ratio) == ratio,
            try c.decode(ConditioningGainPolicy.self, forKey: .gainPolicy) == .none
        else { throw ContractError.invalidConfiguration }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sourceSampleRate, forKey: .sourceSampleRate)
        try c.encode(targetSampleRate, forKey: .targetSampleRate)
        try c.encode(ratio, forKey: .ratio)
        try c.encode(precision, forKey: .precision)
        try c.encode(method, forKey: .method)
        try c.encode(preEmphasisFromHz, forKey: .preEmphasisFromHz)
        try c.encode(declaredInputBandwidthHz, forKey: .declaredInputBandwidthHz)
        try c.encode(requiredInputBandwidthHz, forKey: .requiredInputBandwidthHz)
        try c.encode(gainPolicy, forKey: .gainPolicy)
    }
}
