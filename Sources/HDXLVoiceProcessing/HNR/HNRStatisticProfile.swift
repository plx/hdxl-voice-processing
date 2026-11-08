import CryptoKit
import Foundation

/// A declared population, not an inferred diagnosis or phonation label. Activity
/// detection alone cannot establish voice-only selection.
public enum HNRPopulation: String, Sendable, Hashable, Codable {
    case allEligible, silenceExcluded, voiceOnly, customSelection
}

/// Numerical method, population provenance, complete-dependency selection and
/// aggregation participate in identity. Actual intervals remain in the mask plan.
public struct HNRStatisticProfile: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let measurement: HNRConfiguration
    public let population: HNRPopulation
    public let selection: MaskSelectionPolicy
    public let provenances: [MaskProvenance]
    public let aggregation: String
    public let supportPolicy: String
    public let regionPolicy: String

    public init(
        measurement: HNRConfiguration, population: HNRPopulation,
        selection: MaskSelectionPolicy, provenances: [MaskProvenance]
    ) throws {
        guard provenances.count <= 64,
            selection.selectionSources.allSatisfy({ $0 < provenances.count })
        else { throw HNRError.invalidConfiguration }
        switch population {
        case .allEligible:
            guard selection.selectionSources.isEmpty, selection.rejectedTags.isEmpty else {
                throw HNRError.invalidConfiguration
            }
        case .silenceExcluded:
            guard selection.selectionSources.isEmpty, selection.rejectedTags == [.silence] else {
                throw HNRError.invalidConfiguration
            }
        case .voiceOnly:
            guard !selection.selectionSources.isEmpty,
                selection.selectionSources.allSatisfy({
                    provenances[$0].kind == .externalAnnotation
                })
            else { throw HNRError.invalidConfiguration }
        case .customSelection: break
        }
        schemaVersion = 1
        self.measurement = measurement
        self.population = population
        self.selection = selection
        self.provenances = provenances
        aggregation = "equalAvailableFrameMeanUncappedDecibels"
        supportPolicy = "completeNormalizationDependencyWithinOneSelectedRegion"
        regionPolicy = "independentContiguousRegionsWithoutConcatenation"
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(
                name: "hnr-" + measurement.method.rawValue + "-" + population.rawValue
                    + "-frame-mean",
                version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    package func validate(_ timeline: MaskTimeline) throws {
        guard timeline.plan.policy == selection, timeline.plan.provenances == provenances,
            timeline.plan.source.sampleRate == Double(measurement.sampleRate)
        else { throw HNRError.unexpectedContext }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, measurement, population, selection, provenances
        case aggregation, supportPolicy, regionPolicy
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            measurement: c.decode(HNRConfiguration.self, forKey: .measurement),
            population: c.decode(HNRPopulation.self, forKey: .population),
            selection: c.decode(MaskSelectionPolicy.self, forKey: .selection),
            provenances: c.decode([MaskProvenance].self, forKey: .provenances))
        guard try c.decode(String.self, forKey: .aggregation) == aggregation,
            try c.decode(String.self, forKey: .supportPolicy) == supportPolicy,
            try c.decode(String.self, forKey: .regionPolicy) == regionPolicy
        else { throw HNRError.invalidConfiguration }
    }
}
