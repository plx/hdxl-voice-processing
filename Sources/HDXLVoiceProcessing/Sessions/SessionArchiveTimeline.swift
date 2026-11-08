import Foundation

/// The original source and analysis continuity clocks both survive persistence.
/// Device/route descriptions are explicit host reports, never collected here.
public struct SessionArchiveSource: Sendable, Hashable, Codable {
    public let origin: AnalysisScheduleOrigin
    public let acquisition: SessionAcquisitionMetadata

    public init(origin: AnalysisScheduleOrigin, acquisition: SessionAcquisitionMetadata) {
        self.origin = origin
        self.acquisition = acquisition
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case origin, acquisition }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            origin: c.decode(AnalysisScheduleOrigin.self, forKey: .origin),
            acquisition: c.decode(SessionAcquisitionMetadata.self, forKey: .acquisition))
    }
}

/// A portable copy of all population evidence, including overlapping tags.
/// These are counts over one dependency interval, not totals obtained by summing
/// overlapping timeline records. No voicing or health inference is added.
public struct SessionArchiveCoverage: Sendable, Hashable {
    public let source: Int64
    public let eligible: Int64
    public let selected: Int64
    private let tags: [MaskTag: Int64]
    public var missing: Int64 { source - eligible }
    public var excludedEligible: Int64 { eligible - selected }

    public init(source: Int64, eligible: Int64, selected: Int64, tags: [MaskTag: Int64] = [:])
        throws
    {
        guard source >= 0, (0...source).contains(eligible), (0...eligible).contains(selected),
            tags.values.allSatisfy({ (0...source).contains($0) }),
            tags[.missingAcquisition, default: 0] == source - eligible
        else { throw SessionArchiveError.invalidMetadata }
        self.source = source
        self.eligible = eligible
        self.selected = selected
        self.tags = tags.filter { $0.value != 0 }
    }

    public init(_ value: AnalysisCoverageCounts) throws {
        try self.init(
            source: value.source, eligible: value.eligible, selected: value.selected,
            tags: Dictionary(
                uniqueKeysWithValues: MaskTag.allCases.map { ($0, value.samples(tag: $0)) }))
    }

    public func samples(tag: MaskTag) -> Int64 { tags[tag, default: 0] }
}

/// Immutable series-level mask metadata. Nil on a series explicitly means that
/// the export has no mask annotations; it does not mean all samples were voiced.
public struct SessionArchiveMask: Sendable, Hashable, Codable {
    public let planIdentity: ProfileIdentity
    public let scope: MaskAnalysisScope
    public let policy: MaskSelectionPolicy
    public let sources: [MaskProvenance]
    public let effectiveDelaySeconds: Double

    public init(
        planIdentity: ProfileIdentity, scope: MaskAnalysisScope, policy: MaskSelectionPolicy,
        sources: [MaskProvenance], effectiveDelaySeconds: Double
    ) throws {
        guard sources.count <= 64,
            policy.selectionSources.allSatisfy({ $0 < sources.count }),
            effectiveDelaySeconds.isFinite, effectiveDelaySeconds >= 0
        else { throw SessionArchiveError.invalidMetadata }
        self.planIdentity = planIdentity
        self.scope = scope
        self.policy = policy
        self.sources = sources
        self.effectiveDelaySeconds = effectiveDelaySeconds == 0 ? 0 : effectiveDelaySeconds
    }

    public init(_ value: AnalysisMaskProvenance) throws {
        try self.init(
            planIdentity: value.planIdentity, scope: value.scope, policy: value.policy,
            sources: value.sources, effectiveDelaySeconds: value.effectiveDelaySeconds)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case planIdentity, scope, policy, sources, effectiveDelaySeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            planIdentity: c.decode(ProfileIdentity.self, forKey: .planIdentity),
            scope: c.decode(MaskAnalysisScope.self, forKey: .scope),
            policy: c.decode(MaskSelectionPolicy.self, forKey: .policy),
            sources: c.decode([MaskProvenance].self, forKey: .sources),
            effectiveDelaySeconds: c.decode(Double.self, forKey: .effectiveDelaySeconds))
    }
}

public enum SessionArchiveClock: String, Sendable, Hashable, Codable {
    case sourceSamples, secondsFromOrigin
}

/// Placement is distinct from dependency support. Use integer source samples
/// when available. Scheduled exports retain their original floating-point center
/// without converting a potentially very large absolute source index to Double.
public struct SessionArchiveTimestamp: Sendable, Hashable {
    public let sourceSample: Int64?
    public let secondsFromOrigin: Double?
    public var clock: SessionArchiveClock {
        sourceSample == nil ? .secondsFromOrigin : .sourceSamples
    }

    public init(sourceSample: Int64) throws {
        guard sourceSample >= 0 else { throw SessionArchiveError.invalidMetadata }
        self.sourceSample = sourceSample
        secondsFromOrigin = nil
    }

    public init(secondsFromOrigin: Double) throws {
        guard secondsFromOrigin.isFinite, secondsFromOrigin >= 0 else {
            throw SessionArchiveError.invalidMetadata
        }
        sourceSample = nil
        self.secondsFromOrigin = secondsFromOrigin == 0 ? 0 : secondsFromOrigin
    }

    func follows(_ other: Self) throws {
        guard clock == other.clock else { throw SessionArchiveError.invalidMetadata }
        if self == other { throw SessionArchiveError.duplicateTimestamp }
        let later: Bool
        if let sourceSample, let previous = other.sourceSample {
            later = sourceSample > previous
        } else {
            later = secondsFromOrigin! > other.secondsFromOrigin!
        }
        guard later else { throw SessionArchiveError.outOfOrder }
    }
}

/// Catalog indices are zero-based within their respective record kinds. The
/// complete tuple defines one population/metric series. Duplicate tuples are
/// rejected, preventing a second index from bypassing timestamp validation.
public struct SessionArchiveSeries: Sendable, Hashable, Codable {
    public let profileIndex: UInt32
    public let sourceIndex: UInt32
    public let measurement: MeasurementDescriptor
    public let clock: SessionArchiveClock
    public let isScheduled: Bool
    public let mask: SessionArchiveMask?

    public init(
        profileIndex: UInt32, sourceIndex: UInt32, measurement: MeasurementDescriptor,
        clock: SessionArchiveClock, isScheduled: Bool = false, mask: SessionArchiveMask? = nil
    ) throws {
        guard !isScheduled || clock == .secondsFromOrigin, isScheduled || mask == nil else {
            throw SessionArchiveError.invalidMetadata
        }
        self.profileIndex = profileIndex
        self.sourceIndex = sourceIndex
        self.measurement = measurement
        self.clock = clock
        self.isScheduled = isScheduled
        self.mask = mask
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case profileIndex, sourceIndex, measurement, clock, isScheduled, mask
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard c.contains(.mask) else { throw SessionArchiveError.invalidMetadata }
        try self.init(
            profileIndex: c.decode(UInt32.self, forKey: .profileIndex),
            sourceIndex: c.decode(UInt32.self, forKey: .sourceIndex),
            measurement: c.decode(MeasurementDescriptor.self, forKey: .measurement),
            clock: c.decode(SessionArchiveClock.self, forKey: .clock),
            isScheduled: c.decode(Bool.self, forKey: .isScheduled),
            mask: c.decodeIfPresent(SessionArchiveMask.self, forKey: .mask))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileIndex, forKey: .profileIndex)
        try c.encode(sourceIndex, forKey: .sourceIndex)
        try c.encode(measurement, forKey: .measurement)
        try c.encode(clock, forKey: .clock)
        try c.encode(isScheduled, forKey: .isScheduled)
        try c.encode(mask, forKey: .mask)
    }
}

/// The rest of ScheduledMeasurementExport: origin and mask live in the catalog,
/// while dependency timing, population evidence and batching remain per frame.
public struct SessionArchiveScheduledMetadata: Sendable, Hashable {
    public let dependencyTiming: AnalysisTiming
    public let dependencyCoverage: SessionArchiveCoverage
    public let frameCenterSecondsFromOrigin: Double
    public let workerBatchingUpperBoundSeconds: Double

    public init(
        dependencyTiming: AnalysisTiming, dependencyCoverage: SessionArchiveCoverage,
        frameCenterSecondsFromOrigin: Double, workerBatchingUpperBoundSeconds: Double
    ) throws {
        guard dependencyCoverage.source == dependencyTiming.source.sampleCount,
            frameCenterSecondsFromOrigin.isFinite, frameCenterSecondsFromOrigin >= 0,
            workerBatchingUpperBoundSeconds.isFinite, workerBatchingUpperBoundSeconds >= 0
        else { throw SessionArchiveError.invalidMetadata }
        self.dependencyTiming = dependencyTiming
        self.dependencyCoverage = dependencyCoverage
        self.frameCenterSecondsFromOrigin =
            frameCenterSecondsFromOrigin == 0 ? 0 : frameCenterSecondsFromOrigin
        self.workerBatchingUpperBoundSeconds =
            workerBatchingUpperBoundSeconds == 0 ? 0 : workerBatchingUpperBoundSeconds
    }
}

/// One owned record, not an accumulating session array. A caller retaining these
/// records must apply its own history budget. Construction performs no IO.
public struct SessionArchiveMeasurement: Sendable, Hashable {
    public let timestamp: SessionArchiveTimestamp
    public let result: MeasurementResult
    public let scheduled: SessionArchiveScheduledMetadata?

    public init(timestamp: SessionArchiveTimestamp, result: MeasurementResult) {
        self.timestamp = timestamp
        self.result = result
        scheduled = nil
    }

    public init(
        _ export: ScheduledMeasurementExport, source: SessionArchiveSource,
        series: SessionArchiveSeries
    ) throws {
        guard source.origin == export.origin, series.measurement == export.result.measurement,
            series.isScheduled, series.mask == (try export.mask.map(SessionArchiveMask.init))
        else { throw SessionArchiveError.invalidMetadata }
        try self.init(
            timestamp: SessionArchiveTimestamp(
                secondsFromOrigin: export.frameCenterSecondsFromOrigin),
            result: export.result,
            scheduled: SessionArchiveScheduledMetadata(
                dependencyTiming: export.dependencyTiming,
                dependencyCoverage: SessionArchiveCoverage(export.dependencyCoverage),
                frameCenterSecondsFromOrigin: export.frameCenterSecondsFromOrigin,
                workerBatchingUpperBoundSeconds: export.workerBatchingUpperBoundSeconds))
    }

    init(
        timestamp: SessionArchiveTimestamp, result: MeasurementResult,
        scheduled: SessionArchiveScheduledMetadata?
    ) throws {
        if let scheduled {
            guard timestamp.secondsFromOrigin == scheduled.frameCenterSecondsFromOrigin else {
                throw SessionArchiveError.invalidMetadata
            }
        }
        self.timestamp = timestamp
        self.result = result
        self.scheduled = scheduled
    }
}
