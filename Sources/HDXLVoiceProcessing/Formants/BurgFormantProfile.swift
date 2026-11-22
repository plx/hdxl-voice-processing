import CryptoKit
import Foundation

/// Independent, untracked Burg estimates. All numerical work uses binary64.
public struct BurgFormantProfile: Sendable, Hashable, Codable {
    public let sourceSampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let declaredBandwidthHz: Double
    public let ceilingHz: Int
    public let order: Int
    public let hopMilliseconds: Int
    public let preEmphasisFromHz: Double?

    public var analysisSampleRate: Int { 2 * ceilingHz }
    public var maximumFormants: Int { order / 2 }
    /// Physical support is 50 ms with a 25 ms effective Gaussian width.
    public static let physicalWindowSeconds = 0.050
    public var windowSamples: Int { analysisSampleRate / 20 }
    public var hopSeconds: Double { Double(hopMilliseconds) / 1000 }
    public var window: WindowDefinition { .praatBurgGaussian }
    public static let edgeExclusionHz = 50.0
    public static let credibilityRule = "exploratory-burg-credibility-v1"

    public init(
        sourceSampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        ceilingHz: Int = 5500, order: Int = 10, hopMilliseconds: Int = 10,
        preEmphasisFromHz: Double? = 50, declaredBandwidthHz: Double? = nil
    ) throws {
        let bandwidth = declaredBandwidthHz ?? Double(sourceSampleRate) / 2
        guard (8000...192_000).contains(sourceSampleRate), (4000...8000).contains(ceilingHz),
            ceilingHz.isMultiple(of: 100), (4...16).contains(order), order.isMultiple(of: 2),
            [5, 10].contains(hopMilliseconds),
            preEmphasisFromHz.map({ $0.isFinite && (0...1000).contains($0) }) ?? true,
            bandwidth.isFinite, bandwidth >= Double(ceilingHz),
            bandwidth <= Double(sourceSampleRate) / 2
        else { throw ContractError.invalidConfiguration }
        self.sourceSampleRate = sourceSampleRate
        self.inputPrecision = inputPrecision
        self.declaredBandwidthHz = bandwidth
        self.ceilingHz = ceilingHz
        self.order = order
        self.hopMilliseconds = hopMilliseconds
        self.preEmphasisFromHz = preEmphasisFromHz.map { $0 == 0 ? 0 : $0 }
    }

    public var conditioning: ConditioningConfiguration {
        get throws {
            try ConditioningConfiguration(
                sourceSampleRate: sourceSampleRate,
                targetSampleRate: analysisSampleRate, precision: .float64,
                method: .praat7WholeInterval(interpolationDepth: 50),
                preEmphasisFromHz: preEmphasisFromHz,
                declaredInputBandwidthHz: declaredBandwidthHz,
                requiredInputBandwidthHz: Double(ceilingHz))
        }
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: "burg-formants-untracked", version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    /// Changes whenever a different pitch algorithm or a different support-match policy affects eligibility.
    static func bind(_ base: ProfileIdentity, to observation: ProfileIdentity, matched: Bool) throws
        -> ProfileIdentity
    {
        struct Binding: Encodable {
            let burg: ProfileIdentity
            let pitch: ProfileIdentity
            let matched: Bool
        }
        let bytes = try canonicalContractJSON(
            Binding(burg: base, pitch: observation, matched: matched))
        return try ProfileIdentity(
            identifier: base.identifier,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceSampleRate, inputPrecision, declaredBandwidthHz, ceilingHz, order,
            hopMilliseconds, preEmphasisFromHz
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            sourceSampleRate: c.decode(Int.self, forKey: .sourceSampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            ceilingHz: c.decode(Int.self, forKey: .ceilingHz),
            order: c.decode(Int.self, forKey: .order),
            hopMilliseconds: c.decode(Int.self, forKey: .hopMilliseconds),
            preEmphasisFromHz: c.decodeIfPresent(Double.self, forKey: .preEmphasisFromHz),
            declaredBandwidthHz: c.decode(Double.self, forKey: .declaredBandwidthHz))
    }
}
