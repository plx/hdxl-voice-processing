import Foundation

/// An inspectable reference/verification receipt claimed by the exporting host.
/// Digests and passing ratios do not authenticate imported observations. This
/// type cannot be passed to PersonalTargetFitter as trusted validation evidence.
public struct SessionArchiveValidationClaim: Sendable, Hashable, Codable {
    public let schemaVersion = 1
    public let profile: ProfileIdentity
    public let analysisImplementation: VersionedIdentifier
    public let sourceIdentity: CalibrationDigest
    public let components: [PersonalTargetMetricValidation]

    public init(_ evidence: PersonalTargetValidationEvidence) {
        profile = evidence.profile
        analysisImplementation = evidence.analysisImplementation
        sourceIdentity = evidence.sourceIdentity
        components = evidence.components
    }

    public func identity() throws -> CalibrationDigest { try calibrationDigest(self) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, profile, analysisImplementation, sourceIdentity, components
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw SessionArchiveError.unsupportedVersion
        }
        profile = try c.decode(ProfileIdentity.self, forKey: .profile)
        analysisImplementation = try c.decode(
            VersionedIdentifier.self, forKey: .analysisImplementation)
        sourceIdentity = try c.decode(CalibrationDigest.self, forKey: .sourceIdentity)
        components = try c.decode([ArchivedMetricValidationDocument].self, forKey: .components).map(
            \.value)
        guard components.count == 3,
            Set(components.map(\.metric)) == Set([.cpps, .fundamentalFrequency, .levelDBFS]),
            components.map(\.metric.rawValue) == components.map(\.metric.rawValue).sorted()
        else { throw SessionArchiveError.invalidMetadata }
    }
}

private struct ArchivedMetricValidationDocument: Decodable {
    let value: PersonalTargetMetricValidation
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metric, referenceIdentity, reportIdentity, referenceCases, chunkComparisons,
            boundaryCases
        case maximumReferenceErrorToBudget, maximumChunkErrorToBudget, maximumBoundaryErrorToBudget
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        value = try PersonalTargetMetricValidation(
            metric: c.decode(ScheduledMetric.self, forKey: .metric),
            referenceIdentity: c.decode(CalibrationDigest.self, forKey: .referenceIdentity),
            reportIdentity: c.decode(CalibrationDigest.self, forKey: .reportIdentity),
            referenceCases: c.decode(Int.self, forKey: .referenceCases),
            chunkComparisons: c.decode(Int.self, forKey: .chunkComparisons),
            boundaryCases: c.decode(Int.self, forKey: .boundaryCases),
            maximumReferenceErrorToBudget: c.decode(
                Double.self, forKey: .maximumReferenceErrorToBudget),
            maximumChunkErrorToBudget: c.decode(Double.self, forKey: .maximumChunkErrorToBudget),
            maximumBoundaryErrorToBudget: c.decode(
                Double.self, forKey: .maximumBoundaryErrorToBudget))
    }
}
