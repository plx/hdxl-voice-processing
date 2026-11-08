import Foundation

/// An explicit recipe for replaying one archived series from original PCM.
/// The profile, origin, descriptor and mask provenance come from that series;
/// this record supplies the file mapping and, when needed, the full original
/// mask plan. A mask fingerprint alone is insufficient to reconstruct selection.
public struct SessionArchiveReplayPlan: Sendable, Hashable, Codable {
    public static let maximumMaskObservations = 4096
    public let seriesIndex: UInt32
    public let mediaReferenceIndex: UInt32
    public let mappingIndex: UInt32
    public let mask: MaskPlan?

    public init(
        seriesIndex: UInt32, mediaReferenceIndex: UInt32, mappingIndex: UInt32,
        mask: MaskPlan? = nil
    ) throws {
        guard (mask?.observations.count ?? 0) <= Self.maximumMaskObservations else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        self.seriesIndex = seriesIndex
        self.mediaReferenceIndex = mediaReferenceIndex
        self.mappingIndex = mappingIndex
        self.mask = mask
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case seriesIndex, mediaReferenceIndex, mappingIndex, mask
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard c.contains(.mask) else { throw SessionArchiveError.invalidMetadata }
        try self.init(
            seriesIndex: c.decode(UInt32.self, forKey: .seriesIndex),
            mediaReferenceIndex: c.decode(UInt32.self, forKey: .mediaReferenceIndex),
            mappingIndex: c.decode(UInt32.self, forKey: .mappingIndex),
            mask: c.decodeIfPresent(MaskPlan.self, forKey: .mask))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seriesIndex, forKey: .seriesIndex)
        try c.encode(mediaReferenceIndex, forKey: .mediaReferenceIndex)
        try c.encode(mappingIndex, forKey: .mappingIndex)
        try c.encode(mask, forKey: .mask)
    }
}

struct SessionArchiveReplayState {
    private(set) var plans: [SessionArchiveReplayPlan] = []
    private var seriesIndices: [UInt32: UInt32] = [:]

    func index(for seriesIndex: UInt32) -> UInt32? { seriesIndices[seriesIndex] }

    func plan(at index: UInt32) throws -> SessionArchiveReplayPlan {
        guard Int(index) < plans.count else { throw SessionArchiveError.outOfOrder }
        return plans[Int(index)]
    }

    mutating func add(
        _ plan: SessionArchiveReplayPlan, catalog: inout SessionArchiveCatalog,
        media: SessionArchiveMediaState
    ) throws -> UInt32 {
        guard seriesIndices[plan.seriesIndex] == nil else {
            throw SessionArchiveError.duplicateIdentity
        }
        let (series, profile, source) = try catalog.context(for: plan.seriesIndex)
        guard series.isScheduled, case .schedule(let recipe) = profile.recipe else {
            throw SessionArchiveError.incompatibleProfile
        }
        let reference = try media.reference(at: plan.mediaReferenceIndex)
        guard Int(plan.mappingIndex) < reference.mappings.count else {
            throw SessionArchiveError.outOfOrder
        }
        let mapping = reference.mappings[Int(plan.mappingIndex)]
        guard mapping.sourceIndex == series.sourceIndex,
            mapping.source.startSample == source.origin.source.startSample,
            recipe.inputFormat == reference.decoder.decodedPCM
        else { throw SessionArchiveError.incompatibleProfile }
        try catalog.validateReplayMapping(mapping)
        if let mask = plan.mask {
            guard let provenance = series.mask else { throw SessionArchiveError.invalidMetadata }
            let prepared = try PreparedAnalysisMask(
                timeline: MaskTimeline(mask), scope: provenance.scope)
            guard try SessionArchiveMask(prepared.provenance) == provenance else {
                throw SessionArchiveError.incompatibleProfile
            }
            // One series has one continuity origin. Its mapping must stay within
            // one acquired/selected region, never concatenate across a mask gap.
            try prepared.validateRegion(mapping.source)
        } else if series.mask != nil {
            throw SessionArchiveError.invalidMetadata
        }
        let index = UInt32(plans.count)
        plans.append(plan)
        seriesIndices[plan.seriesIndex] = index
        catalog.acceptedReplayMapping(mapping)
        return index
    }
}
