import Foundation

struct SessionArchiveProfileEntry {
    let recipe: SessionArchiveProfile
    let identity: ProfileIdentity
    let descriptors: Set<MeasurementDescriptor>
}

/// Bounded metadata and one last timestamp per series. No frame history, raw
/// media, or intermediate arrays are retained. All mutations happen after their
/// validation, so a rejected host record does not consume a catalog index.
struct SessionArchiveCatalog {
    let limits: SessionArchiveLimits
    private(set) var profiles: [SessionArchiveProfileEntry] = []
    private(set) var sources: [SessionArchiveSource] = []
    private(set) var series: [SessionArchiveSeries] = []
    private(set) var retainedMetadataBytes = 0
    private(set) var entryCount = 0
    private var profileIdentities: Set<ProfileIdentity> = []
    private var sourceOrigins: Set<AnalysisScheduleOrigin> = []
    private var seriesKeys: Set<SeriesKey> = []
    private var timestamps: [UInt32: SessionArchiveTimestamp] = [:]
    private var closedSourceEnds: [UInt32: Int64] = [:]
    private var incomingGaps: Set<UInt32> = []
    private var observedEnds: [UInt32: Int64] = [:]
    // Replay metadata may precede an incoming gap without publishing results.
    // Keep its extent separate from observedEnds so that ordering stays valid.
    private var replayEnds: [UInt32: Int64] = [:]

    private struct SeriesKey: Hashable {
        let profile: UInt32
        let source: UInt32
        let descriptor: MeasurementDescriptor
        let mask: SessionArchiveMask?
        init(_ series: SessionArchiveSeries) {
            profile = series.profileIndex
            source = series.sourceIndex
            descriptor = series.measurement
            mask = series.mask
        }
    }

    init(limits: SessionArchiveLimits) { self.limits = limits }

    func checkBudget(payloadBytes: Int) throws {
        guard entryCount < limits.maximumCatalogEntries,
            payloadBytes >= 0, payloadBytes <= limits.maximumRecordBytes,
            payloadBytes <= limits.maximumCatalogBytes - retainedMetadataBytes
        else { throw SessionArchiveError.catalogLimitExceeded }
    }

    /// For bounded calibration/media metadata as well as the three tables below.
    mutating func reserveMetadata(payloadBytes: Int) throws {
        try checkBudget(payloadBytes: payloadBytes)
        retainedMetadataBytes += payloadBytes
        entryCount += 1
    }

    @discardableResult
    mutating func add(_ profile: SessionArchiveProfile, payloadBytes: Int) throws -> UInt32 {
        try checkBudget(payloadBytes: payloadBytes)
        let identity = try profile.identity()
        guard !profileIdentities.contains(identity) else {
            throw SessionArchiveError.duplicateIdentity
        }
        let descriptors = try profile.descriptors()
        let index = UInt32(profiles.count)
        try reserveMetadata(payloadBytes: payloadBytes)
        profiles.append(
            SessionArchiveProfileEntry(
                recipe: profile, identity: identity, descriptors: descriptors))
        profileIdentities.insert(identity)
        return index
    }

    @discardableResult
    mutating func add(_ source: SessionArchiveSource, payloadBytes: Int) throws -> UInt32 {
        try checkBudget(payloadBytes: payloadBytes)
        guard !sourceOrigins.contains(source.origin) else {
            throw SessionArchiveError.duplicateIdentity
        }
        let index = UInt32(sources.count)
        try reserveMetadata(payloadBytes: payloadBytes)
        sources.append(source)
        sourceOrigins.insert(source.origin)
        return index
    }

    @discardableResult
    mutating func add(_ item: SessionArchiveSeries, payloadBytes: Int) throws -> UInt32 {
        try checkBudget(payloadBytes: payloadBytes)
        guard Int(item.profileIndex) < profiles.count, Int(item.sourceIndex) < sources.count else {
            throw SessionArchiveError.outOfOrder
        }
        let profile = profiles[Int(item.profileIndex)]
        if let rate = profile.recipe.sourceSampleRate {
            guard rate == sources[Int(item.sourceIndex)].origin.source.sampleRate else {
                throw SessionArchiveError.incompatibleProfile
            }
        }
        guard profile.descriptors.contains(item.measurement) else {
            if profile.descriptors.contains(where: {
                $0.kind == item.measurement.kind && $0.algorithm == item.measurement.algorithm
            }) {
                throw SessionArchiveError.incompatibleUnit
            }
            throw SessionArchiveError.incompatibleProfile
        }
        if case .schedule = profile.recipe {
            guard item.isScheduled else { throw SessionArchiveError.invalidMetadata }
        } else if item.isScheduled {
            throw SessionArchiveError.incompatibleProfile
        }
        let key = SeriesKey(item)
        guard !seriesKeys.contains(key) else { throw SessionArchiveError.duplicateIdentity }
        let index = UInt32(series.count)
        try reserveMetadata(payloadBytes: payloadBytes)
        series.append(item)
        seriesKeys.insert(key)
        return index
    }

    func context(for index: UInt32) throws -> (
        SessionArchiveSeries, SessionArchiveProfileEntry, SessionArchiveSource
    ) {
        guard Int(index) < series.count else { throw SessionArchiveError.outOfOrder }
        let item = series[Int(index)]
        return (item, profiles[Int(item.profileIndex)], sources[Int(item.sourceIndex)])
    }

    func validate(_ record: SessionArchiveMeasurement, seriesIndex: UInt32) throws {
        let (item, profile, source) = try context(for: seriesIndex)
        guard closedSourceEnds[item.sourceIndex] == nil else {
            throw SessionArchiveError.outOfOrder
        }
        guard record.result.profile == profile.identity else {
            throw SessionArchiveError.incompatibleProfile
        }
        guard record.result.measurement == item.measurement else {
            throw record.result.measurement.kind == item.measurement.kind
                && record.result.measurement.algorithm == item.measurement.algorithm
                ? SessionArchiveError.incompatibleUnit : SessionArchiveError.incompatibleProfile
        }
        guard record.timestamp.clock == item.clock, item.isScheduled == (record.scheduled != nil)
        else {
            throw SessionArchiveError.invalidMetadata
        }
        try validate(record.result.timing.source, source: source)
        if let sample = record.timestamp.sourceSample, sample < source.origin.source.startSample {
            throw SessionArchiveError.invalidMetadata
        }
        guard
            record.result.intermediatePolicy.maximumScalarCount <= limits.maximumIntermediateScalars
        else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        for intermediate in record.result.intermediates {
            try validate(intermediate.source, source: source)
        }
        if let scheduled = record.scheduled {
            let dependency = scheduled.dependencyTiming.source
            try validate(dependency, source: source)
            let measured = record.result.timing.source
            guard dependency.startSample <= measured.startSample,
                dependency.endSample >= measured.endSample
            else {
                throw SessionArchiveError.invalidMetadata
            }
            let counts = scheduled.dependencyCoverage
            let expected = item.mask?.scope == .selected ? counts.selected : counts.eligible
            // A kernel can use fewer samples than the acquired/selected support
            // (for example unavailable K-weighted warmup). Preserve both counts.
            guard scheduled.dependencyTiming.includedSampleCount <= expected else {
                throw SessionArchiveError.invalidMetadata
            }
            if item.mask == nil {
                guard counts.eligible == counts.source, counts.selected == counts.source,
                    MaskTag.allCases.allSatisfy({ counts.samples(tag: $0) == 0 })
                else { throw SessionArchiveError.invalidMetadata }
            }
        }
        if let previous = timestamps[seriesIndex] { try record.timestamp.follows(previous) }
    }

    /// Call only after validate and a successful wire append/decode. Keeping this
    /// separate avoids accepting a timestamp when an output size check fails.
    mutating func accepted(_ record: SessionArchiveMeasurement, seriesIndex: UInt32) {
        timestamps[seriesIndex] = record.timestamp
        let sourceIndex = series[Int(seriesIndex)].sourceIndex
        var end = max(
            record.result.timing.source.endSample,
            record.scheduled?.dependencyTiming.source.endSample ?? 0)
        for intermediate in record.result.intermediates {
            end = max(end, intermediate.source.endSample)
        }
        observedEnds[sourceIndex] = max(observedEnds[sourceIndex] ?? 0, end)
    }

    func validate(_ gap: SessionArchiveGap) throws {
        guard Int(gap.previousSourceIndex) < sources.count,
            Int(gap.nextSourceIndex) < sources.count,
            closedSourceEnds[gap.previousSourceIndex] == nil,
            closedSourceEnds[gap.nextSourceIndex] == nil,
            !incomingGaps.contains(gap.nextSourceIndex), observedEnds[gap.nextSourceIndex] == nil
        else { throw SessionArchiveError.outOfOrder }
        let previous = sources[Int(gap.previousSourceIndex)].origin
        let next = sources[Int(gap.nextSourceIndex)].origin
        try validate(gap.observedSource, source: sources[Int(gap.previousSourceIndex)])
        guard gap.observedSource.startSample == previous.source.startSample,
            gap.observedSource.endSample
                >= (observedEnds[gap.previousSourceIndex] ?? previous.source.startSample),
            gap.observedSource.endSample
                >= (replayEnds[gap.previousSourceIndex] ?? previous.source.startSample)
        else { throw SessionArchiveError.invalidMetadata }
        do {
            _ = try SourceDiscontinuity(
                previousEpoch: previous.continuityEpoch, nextEpoch: next.continuityEpoch,
                reason: gap.reason)
        } catch { throw SessionArchiveError.invalidMetadata }
        if let missing = gap.missingSource, previous.source.epoch == next.source.epoch {
            guard next.source.startSample == missing.endSample else {
                throw SessionArchiveError.invalidMetadata
            }
        }
    }

    mutating func accepted(_ gap: SessionArchiveGap) {
        closedSourceEnds[gap.previousSourceIndex] = gap.observedSource.endSample
        incomingGaps.insert(gap.nextSourceIndex)
    }

    func validateReplayMapping(_ mapping: SessionArchiveMediaMapping) throws {
        if let end = closedSourceEnds[mapping.sourceIndex] {
            guard mapping.source.endSample <= end else { throw SessionArchiveError.invalidMetadata }
        }
    }

    mutating func acceptedReplayMapping(_ mapping: SessionArchiveMediaMapping) {
        replayEnds[mapping.sourceIndex] = max(
            replayEnds[mapping.sourceIndex] ?? 0, mapping.source.endSample)
    }

    private func validate(_ interval: SourceInterval, source: SessionArchiveSource) throws {
        guard interval.epoch == source.origin.source.epoch,
            interval.sampleRate == source.origin.source.sampleRate,
            interval.startSample >= source.origin.source.startSample
        else { throw SessionArchiveError.invalidMetadata }
    }
}

/// Archive metadata uses only canonical bytes. Besides deterministic fixtures,
/// this rejects duplicate JSON keys and normalized-away alternate spellings.
/// The outer framing checks the byte ceiling before invoking a decoder.
func decodeSessionMetadata<Value: Codable>(_ type: Value.Type, from payload: Data) throws -> Value {
    do {
        let value = try JSONDecoder().decode(type, from: payload)
        guard try canonicalContractJSON(value) == payload else {
            throw SessionArchiveError.malformedRecord
        }
        return value
    } catch let error as SessionArchiveError { throw error } catch ContractError
        .unsupportedSchemaVersion
    { throw SessionArchiveError.unsupportedVersion } catch ContractError.invalidUnit {
        throw SessionArchiveError.incompatibleUnit
    } catch { throw SessionArchiveError.malformedRecord }
}
