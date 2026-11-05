import CryptoKit
import Foundation

public enum MaskError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidObservation, unexpectedInterval, capacityExceeded
    case invalidState, reentrantCall, nonfiniteInput, nonfiniteResult, insufficientData
}

/// Operational evidence, not a phoneme label or a diagnosis of voice quality.
public enum MaskSourceKind: String, Sendable, Hashable, Codable {
    case externalAnnotation, energyEligibility, spectralFlatnessSpeechActivity
    case consumerLearnedSpeechActivity, acquisitionDiagnostics, algorithmDiagnostics
}

/// Every numerical choice belongs in parameters. Learned sources additionally
/// require the consumer's model name and version; their labels are speech activity.
public struct MaskProvenance: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let kind: MaskSourceKind
    public let identifier: VersionedIdentifier
    public let parameters: [String: ProfileSetting]
    public let modelName: String?
    public let modelVersion: String?

    public init(
        kind: MaskSourceKind, identifier: VersionedIdentifier,
        parameters: [String: ProfileSetting] = [:], modelName: String? = nil,
        modelVersion: String? = nil
    ) throws {
        guard parameters.count <= 128, parameters.keys.allSatisfy(validContractIdentifier) else {
            throw MaskError.invalidConfiguration
        }
        if kind == .consumerLearnedSpeechActivity {
            guard let modelName, let modelVersion,
                !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                modelName.utf8.count <= 4096, modelVersion.utf8.count <= 4096
            else { throw MaskError.invalidConfiguration }
        } else if modelName != nil || modelVersion != nil {
            throw MaskError.invalidConfiguration
        }
        schemaVersion = 1
        self.kind = kind
        self.identifier = identifier
        self.parameters = try parameters.mapValues { try $0.validated() }
        self.modelName = modelName?.precomposedStringWithCanonicalMapping
        self.modelVersion = modelVersion?.precomposedStringWithCanonicalMapping
    }

    public func identity() throws -> ProfileIdentity {
        let bytes = try canonicalContractJSON(self)
        return try ProfileIdentity(
            identifier: identifier,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, kind, identifier, parameters, modelName, modelVersion
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            kind: c.decode(MaskSourceKind.self, forKey: .kind),
            identifier: c.decode(VersionedIdentifier.self, forKey: .identifier),
            parameters: c.decode([String: ProfileSetting].self, forKey: .parameters),
            modelName: c.decodeIfPresent(String.self, forKey: .modelName),
            modelVersion: c.decodeIfPresent(String.self, forKey: .modelVersion))
    }
}

/// Tags are independent, overlapping observations. Speech detection can coexist
/// with clipping or low periodicity; neither is silently converted into silence.
public enum MaskTag: String, Sendable, Hashable, Codable, CaseIterable {
    case missingAcquisition, silence, suspectedExternalNoise, clipping
    case speechDetected, nonSpeechDetected, lowPeriodicityConfidence, algorithmInsufficiency
    case energyEligible, energyIneligible
}

/// Selection is distinct from evidence. Unspecified evidence does not vote either way.
public enum MaskSelectionVote: String, Sendable, Hashable, Codable {
    case selected, rejected, unspecified
}

public struct MaskObservation: Sendable, Hashable, Codable {
    public let source: SourceInterval
    /// Index in the owning plan's provenance table.
    public let provenanceIndex: Int
    public let selection: MaskSelectionVote
    public let tags: [MaskTag]

    public init(
        source: SourceInterval, provenanceIndex: Int, selection: MaskSelectionVote = .unspecified,
        tags: [MaskTag] = []
    ) throws {
        guard source.sampleCount > 0, provenanceIndex >= 0 else {
            throw MaskError.invalidObservation
        }
        self.source = source
        self.provenanceIndex = provenanceIndex
        self.selection = selection
        self.tags = Array(Set(tags)).sorted { $0.rawValue < $1.rawValue }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, provenanceIndex, selection, tags
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            source: c.decode(SourceInterval.self, forKey: .source),
            provenanceIndex: c.decode(Int.self, forKey: .provenanceIndex),
            selection: c.decode(MaskSelectionVote.self, forKey: .selection),
            tags: c.decode([MaskTag].self, forKey: .tags))
    }
}

public enum MaskSourceCombination: String, Sendable, Hashable, Codable {
    case all, any
}

/// Empty selectionSources means all acquired samples, subject only to explicit
/// rejectedTags. For a selected source, rejection wins overlapping positive votes;
/// lack of a vote does not select. Missing acquisition is always ineligible.
public struct MaskSelectionPolicy: Sendable, Hashable, Codable {
    public let selectionSources: [Int]
    public let combination: MaskSourceCombination
    public let rejectedTags: [MaskTag]

    public init(
        selectionSources: [Int] = [], combination: MaskSourceCombination = .all,
        rejectedTags: [MaskTag] = []
    ) throws {
        guard selectionSources.allSatisfy({ $0 >= 0 }), selectionSources.count <= 64 else {
            throw MaskError.invalidConfiguration
        }
        self.selectionSources = Array(Set(selectionSources)).sorted()
        self.combination = combination
        self.rejectedTags = Array(Set(rejectedTags)).sorted { $0.rawValue < $1.rawValue }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case selectionSources, combination, rejectedTags
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            selectionSources: c.decode([Int].self, forKey: .selectionSources),
            combination: c.decode(MaskSourceCombination.self, forKey: .combination),
            rejectedTags: c.decode([MaskTag].self, forKey: .rejectedTags))
    }
}

/// Owned control-plane input. Observations may overlap or arrive out of order;
/// resolution uses half-open intervals and the policy's explicit overlap rules.
/// This allocation-bearing construction is not a capture-callback operation.
public struct MaskPlan: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let source: SourceInterval
    public let provenances: [MaskProvenance]
    public let policy: MaskSelectionPolicy
    public let observations: [MaskObservation]
    public let effectiveDelaySeconds: Double
    public static let maximumObservationCount = 1_000_000

    public init(
        source: SourceInterval, provenances: [MaskProvenance], policy: MaskSelectionPolicy,
        observations: [MaskObservation], effectiveDelaySeconds: Double = 0
    ) throws {
        guard provenances.count <= 64, observations.count <= Self.maximumObservationCount else {
            throw MaskError.capacityExceeded
        }
        guard policy.selectionSources.allSatisfy({ $0 < provenances.count }) else {
            throw MaskError.invalidConfiguration
        }
        guard effectiveDelaySeconds.isFinite, effectiveDelaySeconds >= 0 else {
            throw MaskError.invalidConfiguration
        }
        for observation in observations {
            guard observation.provenanceIndex < provenances.count,
                observation.source.epoch == source.epoch,
                observation.source.sampleRate == source.sampleRate,
                observation.source.startSample >= source.startSample,
                observation.source.endSample <= source.endSample
            else { throw MaskError.invalidObservation }
        }
        schemaVersion = 1
        self.source = source
        self.provenances = provenances
        self.policy = policy
        self.observations = observations
        self.effectiveDelaySeconds = effectiveDelaySeconds == 0 ? 0 : effectiveDelaySeconds
    }

    public func canonicalJSON() throws -> Data { try canonicalContractJSON(self) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, source, provenances, policy, observations, effectiveDelaySeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            source: c.decode(SourceInterval.self, forKey: .source),
            provenances: c.decode([MaskProvenance].self, forKey: .provenances),
            policy: c.decode(MaskSelectionPolicy.self, forKey: .policy),
            observations: c.decode([MaskObservation].self, forKey: .observations),
            effectiveDelaySeconds: c.decode(Double.self, forKey: .effectiveDelaySeconds))
    }
}
