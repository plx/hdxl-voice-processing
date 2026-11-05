import CryptoKit
import Foundation

/// A population declaration, not an automatically inferred phonation label.
/// Voice-only requires explicit external selection annotations; an activity
/// detector alone cannot establish that a segment is voiced.
public enum CPPSPopulation: String, Sendable, Hashable, Codable {
    case allEligible, silenceExcluded, voiceOnly, customSelection
}

public enum CPPSAggregation: String, Sendable, Hashable, Codable {
    case equalFrameMean, regionDurationWeightedMean, rollingFrameMean
}

/// Numerical settings, population provenance and aggregation are all identity
/// inputs. Actual observation intervals remain in the separately exported mask plan.
public struct CPPSStatisticProfile: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let measurement: CPPSProfile
    public let population: CPPSPopulation
    public let selection: MaskSelectionPolicy
    public let provenances: [MaskProvenance]
    public let aggregation: CPPSAggregation
    public let rollingWindowSeconds: Double?

    public init(
        measurement: CPPSProfile, population: CPPSPopulation,
        selection: MaskSelectionPolicy, provenances: [MaskProvenance],
        aggregation: CPPSAggregation = .regionDurationWeightedMean,
        rollingWindowSeconds: Double? = nil
    ) throws {
        guard provenances.count <= 64,
            selection.selectionSources.allSatisfy({ $0 < provenances.count })
        else { throw CPPSError.invalidConfiguration }
        switch population {
        case .allEligible:
            guard selection.selectionSources.isEmpty, selection.rejectedTags.isEmpty else {
                throw CPPSError.invalidConfiguration
            }
        case .silenceExcluded:
            guard selection.selectionSources.isEmpty, selection.rejectedTags == [.silence] else {
                throw CPPSError.invalidConfiguration
            }
        case .voiceOnly:
            guard !selection.selectionSources.isEmpty,
                selection.selectionSources.allSatisfy({
                    provenances[$0].kind == .externalAnnotation
                })
            else { throw CPPSError.invalidConfiguration }
        case .customSelection: break
        }
        if aggregation == .rollingFrameMean {
            guard let rollingWindowSeconds, rollingWindowSeconds.isFinite,
                (1...5).contains(rollingWindowSeconds)
            else { throw CPPSError.invalidConfiguration }
        } else if rollingWindowSeconds != nil {
            throw CPPSError.invalidConfiguration
        }
        schemaVersion = 1
        self.measurement = measurement
        self.population = population
        self.selection = selection
        self.provenances = provenances
        self.aggregation = aggregation
        self.rollingWindowSeconds = rollingWindowSeconds
    }
    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(
                name: "cpps-" + population.rawValue
                    + "-" + aggregation.rawValue, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }
    package func validate(_ timeline: MaskTimeline) throws {
        guard timeline.plan.provenances == provenances, timeline.plan.policy == selection,
            timeline.plan.source.sampleRate
                == Double(measurement.cepstrogram.conditioning.sourceSampleRate)
        else { throw CPPSError.profileMismatch }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, measurement, population, selection, provenances, aggregation,
            rollingWindowSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        guard c.contains(.rollingWindowSeconds) else { throw CPPSError.invalidConfiguration }
        try self.init(
            measurement: c.decode(CPPSProfile.self, forKey: .measurement),
            population: c.decode(CPPSPopulation.self, forKey: .population),
            selection: c.decode(MaskSelectionPolicy.self, forKey: .selection),
            provenances: c.decode([MaskProvenance].self, forKey: .provenances),
            aggregation: c.decode(CPPSAggregation.self, forKey: .aggregation),
            rollingWindowSeconds: c.decodeIfPresent(Double.self, forKey: .rollingWindowSeconds))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(measurement, forKey: .measurement)
        try c.encode(population, forKey: .population)
        try c.encode(selection, forKey: .selection)
        try c.encode(provenances, forKey: .provenances)
        try c.encode(aggregation, forKey: .aggregation)
        try c.encode(rollingWindowSeconds, forKey: .rollingWindowSeconds)
    }
}
