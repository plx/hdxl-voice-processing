import Foundation
import HDXLVoiceProcessing

/// Retains the full plan, resolved exclusions and whole-timeline coverage. Selection
/// returns contributing original segments; it does not relabel that coverage as a
/// selection aggregate or concatenate selected audio.
public struct VisualizationSegmentationSnapshot: Sendable, Hashable {
    public let timeline: MaskTimeline
    public let limits: VisualizationLimits

    public init(_ timeline: MaskTimeline, limits: VisualizationLimits = .standard) throws {
        guard timeline.segments.count <= limits.maximumSegments,
            timeline.plan.observations.count <= limits.maximumSegments
        else { throw VisualizationError.capacityExceeded }
        var metadata = VisualizationMetadataBudget(limits)
        for provenance in timeline.plan.provenances { try metadata.charge(provenance) }
        self.timeline = timeline
        self.limits = limits
    }

    public func selected(by selection: VisualizationSelection) -> [MaskSegment] {
        timeline.segments.filter { selection.intersects($0.source) }
    }
}

public enum VisualizationProfileDefinition: Sendable, Hashable {
    case identityOnly
    case analysis(AnalysisProfile)
    case schedule(AnalysisScheduleProfile)
}

/// Canonical recipe text is prepared outside view evaluation. Identity-only records
/// explicitly have no recipe; inspection neither executes nor activates a profile.
public struct VisualizationProfileSnapshot: Sendable, Hashable {
    public let identity: ProfileIdentity
    public let definition: VisualizationProfileDefinition
    public let canonicalRecipe: String?

    public init(identity: ProfileIdentity) {
        self.identity = identity
        definition = .identityOnly
        canonicalRecipe = nil
    }

    public init(_ profile: AnalysisProfile, limits: VisualizationLimits = .standard) throws {
        var metadata = VisualizationMetadataBudget(limits)
        try metadata.charge(profile.identifier)
        try metadata.charge(profile.measurement.algorithm)
        try metadata.charge(profile.window)
        try metadata.charge(profile.preprocessing)
        try metadata.charge(profile.algorithmSettings)
        let data = try profile.canonicalJSON()
        guard data.count <= limits.maximumMetadataBytes else {
            throw VisualizationError.capacityExceeded
        }
        identity = try profile.identity()
        definition = .analysis(profile)
        canonicalRecipe = String(decoding: data, as: UTF8.self)
    }

    public init(_ profile: AnalysisScheduleProfile, limits: VisualizationLimits = .standard) throws
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(profile)
        guard data.count <= limits.maximumMetadataBytes else {
            throw VisualizationError.capacityExceeded
        }
        identity = try profile.identity()
        definition = .schedule(profile)
        canonicalRecipe = String(decoding: data, as: UTF8.self)
    }
}

public enum VisualizationDiagnosticValue: Sendable, Hashable, Identifiable {
    case counter(id: VersionedIdentifier, value: UInt64)
    case latency(id: VersionedIdentifier, summary: RuntimeLatencySummary)
    case delivery(id: VersionedIdentifier, statistics: ResultDeliveryStatistics)

    public var id: VersionedIdentifier {
        switch self {
        case .counter(let id, _), .latency(let id, _), .delivery(let id, _): id
        }
    }
}

/// Optional owned diagnostics supplied by a host. Collection is never enabled here.
/// Runtime latencies and delivery clocks remain distinct from acoustic source time;
/// missing/saturated latency summaries are retained without a fabricated zero mean.
public struct VisualizationDiagnosticsSnapshot: Sendable, Hashable {
    public let mode: RuntimeDiagnosticMode
    public let values: [VisualizationDiagnosticValue]
    public let source: SourceInterval?
    public let profile: ProfileIdentity?

    public init(
        mode: RuntimeDiagnosticMode, values: [VisualizationDiagnosticValue],
        source: SourceInterval? = nil, profile: ProfileIdentity? = nil,
        limits: VisualizationLimits = .standard
    ) throws {
        guard values.count <= limits.maximumMeasurements else {
            throw VisualizationError.capacityExceeded
        }
        var ids: Set<VersionedIdentifier> = []
        var metadata = VisualizationMetadataBudget(limits)
        if let profile { try metadata.charge(profile) }
        for value in values {
            guard ids.insert(value.id).inserted else {
                throw VisualizationError.invalidConfiguration
            }
            try metadata.charge(value.id)
        }
        self.mode = mode
        self.values = values
        self.source = source
        self.profile = profile
    }
}
