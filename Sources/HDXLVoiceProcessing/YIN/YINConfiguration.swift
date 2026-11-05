import CryptoKit
import Foundation

public enum YINError: Error, Sendable, Equatable {
    case invalidConfiguration, precisionMismatch, invalidBufferSize, invalidInput
    case unexpectedContext, invalidState, reentrantCall, numericalFailure
}

public enum YINDifferenceBackend: String, Sendable, Hashable, Codable, CaseIterable {
    case scalar, fft
}

/// Fixed integration YIN steps 2--5, with an explicit raw-difference period
/// refinement. This is not the paper's step 6 neighboring-time estimator.
/// All numerical and support conventions are frozen in Tools/YIN/README.md.
public struct YINConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let arithmeticPrecision: AnalysisPrecision
    public let pitchFloorHz: Double
    public let pitchCeilingHz: Double
    public let integrationLength: Int
    public let hopLength: Int
    public let threshold: Double
    public let silenceRMSThreshold: Double
    public let differenceBackend: YINDifferenceBackend
    public let partialWindowPolicy: PartialWindowPolicy
    public let definition: String
    public let interpolation: String
    public let supportPolicy: String
    public let normalization: String
    public let neighboringTimeRefinement: String
    public let rangeBoundaryToleranceSamples: Double

    public var minimumPeriodSamples: Double { Double(sampleRate) / pitchCeilingHz }
    public var maximumPeriodSamples: Double { Double(sampleRate) / pitchFloorHz }
    public var firstCandidateLag: Int { Int(floor(minimumPeriodSamples)) }
    public var lastCandidateLag: Int { Int(ceil(maximumPeriodSamples)) }
    /// Includes the right interpolation neighbor, not just the largest candidate lag.
    public var maximumEvaluatedLag: Int { lastCandidateLag + 1 }
    public var requiredSampleCount: Int { integrationLength + maximumEvaluatedLag }
    public var supportDurationSeconds: Double { Double(requiredSampleCount) / Double(sampleRate) }
    /// Earliest delivery relative to the midpoint of the complete observed support.
    public var algorithmicDelaySeconds: Double { supportDurationSeconds / 2 }
    public var maximumCandidateCount: Int { lastCandidateLag - firstCandidateLag + 1 }

    public init(
        sampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        pitchFloorHz: Double = 50, pitchCeilingHz: Double = 700,
        integrationLength: Int? = nil, hopLength: Int,
        threshold: Double = 0.1, silenceRMSThreshold: Double = 1e-7,
        differenceBackend: YINDifferenceBackend = .fft,
        partialWindowPolicy: PartialWindowPolicy = .emitUnavailable
    ) throws {
        guard (4000...192_000).contains(sampleRate),
            pitchFloorHz.isFinite, pitchCeilingHz.isFinite,
            pitchFloorHz >= 20, pitchFloorHz < pitchCeilingHz,
            pitchCeilingHz <= Double(sampleRate) / 4,
            threshold.isFinite, threshold > 0, threshold < 1,
            silenceRMSThreshold.isFinite, (0...1).contains(silenceRMSThreshold)
        else { throw YINError.invalidConfiguration }
        let a = Double(sampleRate) / pitchCeilingHz
        let b = Double(sampleRate) / pitchFloorHz
        let lo = Int(floor(a))
        let hi = Int(ceil(b))
        let integration = integrationLength ?? hi
        guard hi >= lo + 1, ceil(a) <= floor(b),
            (hi...16_384).contains(integration),
            (1...(integration + hi + 1)).contains(hopLength)
        else { throw YINError.invalidConfiguration }
        self.schemaVersion = 1
        self.sampleRate = sampleRate
        self.inputPrecision = inputPrecision
        self.arithmeticPrecision = .float64
        self.pitchFloorHz = pitchFloorHz
        self.pitchCeilingHz = pitchCeilingHz
        self.integrationLength = integration
        self.hopLength = hopLength
        self.threshold = threshold
        self.silenceRMSThreshold = silenceRMSThreshold == 0 ? 0 : silenceRMSThreshold
        self.differenceBackend = differenceBackend
        self.partialWindowPolicy = partialWindowPolicy
        self.definition = "hdxl-yin-fixed-time-2002-steps2to5"
        self.interpolation = "cmndOrdinateRawDifferencePeriod"
        self.supportPolicy = "fixedIntegrationPlusMaximumLagAndNeighbor"
        self.normalization = "observedPeak"
        self.neighboringTimeRefinement = "disabled"
        self.rangeBoundaryToleranceSamples = 2e-6
    }

    public func identity() throws -> ProfileIdentity {
        try yinIdentity(self, name: definition)
    }

    public func framingConfiguration() throws -> FramingConfiguration {
        try FramingConfiguration(
            window: WindowSpecification(
                definition: .rectangular, sampleCount: requiredSampleCount,
                sampleRate: Double(sampleRate), precision: inputPrecision),
            hopLength: hopLength, partialWindowPolicy: partialWindowPolicy)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sampleRate, inputPrecision, arithmeticPrecision
        case pitchFloorHz, pitchCeilingHz, integrationLength, hopLength, threshold
        case silenceRMSThreshold, differenceBackend, partialWindowPolicy, definition
        case interpolation, supportPolicy, normalization, neighboringTimeRefinement
        case rangeBoundaryToleranceSamples
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            pitchFloorHz: c.decode(Double.self, forKey: .pitchFloorHz),
            pitchCeilingHz: c.decode(Double.self, forKey: .pitchCeilingHz),
            integrationLength: c.decode(Int.self, forKey: .integrationLength),
            hopLength: c.decode(Int.self, forKey: .hopLength),
            threshold: c.decode(Double.self, forKey: .threshold),
            silenceRMSThreshold: c.decode(Double.self, forKey: .silenceRMSThreshold),
            differenceBackend: c.decode(YINDifferenceBackend.self, forKey: .differenceBackend),
            partialWindowPolicy: c.decode(PartialWindowPolicy.self, forKey: .partialWindowPolicy))
        guard try c.decode(AnalysisPrecision.self, forKey: .arithmeticPrecision) == .float64,
            try c.decode(String.self, forKey: .definition) == definition,
            try c.decode(String.self, forKey: .interpolation) == interpolation,
            try c.decode(String.self, forKey: .supportPolicy) == supportPolicy,
            try c.decode(String.self, forKey: .normalization) == normalization,
            try c.decode(String.self, forKey: .neighboringTimeRefinement)
                == neighboringTimeRefinement,
            try c.decode(Double.self, forKey: .rangeBoundaryToleranceSamples)
                == rangeBoundaryToleranceSamples
        else { throw YINError.invalidConfiguration }
    }
}

/// A separate causal preference among already threshold-qualified YIN candidates.
/// It adds no lookahead and never replaces or erases the unsmoothed estimate.
public struct YINTrackerConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let definition: String
    public let continuityWeight: Double

    public init(continuityWeight: Double = 0.05) throws {
        guard continuityWeight.isFinite, (0...10).contains(continuityWeight) else {
            throw YINError.invalidConfiguration
        }
        schemaVersion = 1
        definition = "causal-yin-candidate-continuity"
        self.continuityWeight = continuityWeight == 0 ? 0 : continuityWeight
    }
    public func identity() throws -> ProfileIdentity {
        try yinIdentity(self, name: definition)
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, definition, continuityWeight
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(continuityWeight: c.decode(Double.self, forKey: .continuityWeight))
        guard try c.decode(String.self, forKey: .definition) == definition else {
            throw YINError.invalidConfiguration
        }
    }
}

/// Estimator and optional tracker identities remain independently inspectable.
public struct YINProfile: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let estimator: YINConfiguration
    public let tracker: YINTrackerConfiguration?

    public init(estimator: YINConfiguration, tracker: YINTrackerConfiguration? = nil) {
        schemaVersion = 1
        self.estimator = estimator
        self.tracker = tracker
    }
    public func identity() throws -> ProfileIdentity {
        try yinIdentity(self, name: "yin-estimator-and-optional-tracker")
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, estimator, tracker
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        guard c.contains(.tracker) else { throw YINError.invalidConfiguration }
        self.init(
            estimator: try c.decode(YINConfiguration.self, forKey: .estimator),
            tracker: try c.decodeIfPresent(YINTrackerConfiguration.self, forKey: .tracker))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(estimator, forKey: .estimator)
        try c.encode(tracker, forKey: .tracker)
    }
}

private func yinIdentity(_ value: some Encodable, name: String) throws -> ProfileIdentity {
    try ProfileIdentity(
        identifier: VersionedIdentifier(name: name, version: 1),
        sha256: SHA256.hash(data: canonicalContractJSON(value)).map {
            String(format: "%02x", $0)
        }.joined())
}
