/// Work counters describe implementation work, not acquired audio coverage.
public struct JitterRollingExecutionStatistics: Sendable, Hashable {
    public let preparedBufferBytes: Int
    public let appendedPeriodCount: UInt64
    public let analyzedQueryCount: UInt64
    public let retainedPeriodCount: Int
    public let retainedInputCount: Int
    public let sumTreeNodeUpdateCount: UInt64
}

/// Incremental, single-owner statistics for exploratory rolling queries. Period
/// coordinates are relative to the fixed `origin`, NOT each append's dependency.
/// Preserve raw rejected intervals and give independently tracked runs different
/// IDs. No waveform, F0 contour or caller buffer is retained.
///
/// Appends update at most five contribution leaves. Each leaf update/expiration
/// costs O(log capacity); totals take constant time. Query clock advances may
/// expire many leaves, with amortized O(log capacity) work per observation.
public final class PreparedRollingJitter {
    public let configuration: JitterConfiguration
    public let identity: ProfileIdentity
    public let maximumPeriodCount: Int
    public let variant: JitterVariant?
    public let provenance: JitterInputProvenance
    public private(set) var origin: SourceInterval
    private let storage: JitterRollingStorage
    private let requested: JitterRequestedVariants
    private let diagnostics: WorkerDiagnostics
    private var busy = false
    private var queryClock: Int64
    private var upstreamEnd: Int64
    private var latestPeriodEnd: Double?
    private var appendedCount: UInt64 = 0
    private var analyzedCount: UInt64 = 0

    public var executionStatistics: JitterRollingExecutionStatistics {
        JitterRollingExecutionStatistics(
            preparedBufferBytes: storage.preparedBytes, appendedPeriodCount: appendedCount,
            analyzedQueryCount: analyzedCount, retainedPeriodCount: storage.count,
            retainedInputCount: storage.inputCount, sumTreeNodeUpdateCount: storage.nodeUpdateCount)
    }

    public convenience init(
        configuration: JitterConfiguration, origin: SourceInterval, maximumPeriodCount: Int,
        variant: JitterVariant? = nil, provenance: JitterInputProvenance = .init()
    ) throws {
        try self.init(
            configuration: configuration, origin: origin,
            maximumPeriodCount: maximumPeriodCount, variant: variant, provenance: provenance,
            diagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: JitterConfiguration, origin: SourceInterval, maximumPeriodCount: Int,
        variant: JitterVariant? = nil, provenance: JitterInputProvenance = .init(),
        diagnostics: WorkerDiagnostics
    ) throws {
        guard configuration.applicability == .exploratoryRolling, origin.sampleCount == 0,
            origin.sampleRate == Double(configuration.sampleRate),
            provenance.kind == .suppliedPeriods
        else { throw JitterError.invalidConfiguration }
        self.configuration = configuration
        self.origin = origin
        self.maximumPeriodCount = maximumPeriodCount
        self.variant = variant
        self.provenance = provenance
        self.diagnostics = diagnostics
        identity = try configuration.identity()
        requested = variant.map(JitterRequestedVariants.init) ?? .all
        storage = try JitterRollingStorage(
            configuration: configuration,
            capacity: maximumPeriodCount, requested: requested)
        queryClock = origin.startSample
        upstreamEnd = origin.startSample
    }

    /// Clears history and counters, optionally starting a new continuity epoch.
    /// Invalid replacement origins leave the old state intact.
    public func reset(origin replacement: SourceInterval? = nil) throws {
        guard !busy else { throw JitterError.reentrantCall }
        let next = replacement ?? origin
        guard next.sampleCount == 0, next.sampleRate == Double(configuration.sampleRate) else {
            throw JitterError.unexpectedContext
        }
        busy = true
        defer { busy = false }
        origin = next
        queryClock = next.startSample
        upstreamEnd = next.startSample
        latestPeriodEnd = nil
        appendedCount = 0
        analyzedCount = 0
        storage.reset()
        diagnostics.reset()
    }

    /// Append one complete observed period. Times are relative to `origin`.
    /// Dependency is the entire upstream support (e.g. a pulse-tracking block),
    /// not merely the period endpoints. All validation/capacity checks precede
    /// mutation. A rejected call may be retried after correcting the input.
    public func append(_ period: JitterPeriodInput, dependency: SourceInterval) throws {
        guard !busy else { throw JitterError.reentrantCall }
        guard dependency.epoch == origin.epoch, dependency.sampleRate == origin.sampleRate,
            dependency.startSample >= origin.startSample,
            period.startSeconds >= (latestPeriodEnd ?? 0),
            period.endSeconds <= relativeSeconds(dependency.endSample),
            period.startSeconds >= relativeSeconds(dependency.startSample)
                || period.rejections.contains(.missingAcquisition),
            appendedCount < .max
        else { throw JitterError.unexpectedContext }
        let clock = max(queryClock, max(upstreamEnd, dependency.endSample))
        let cutoff = relativeSeconds(windowStart(at: clock))
        let expired = storage.expirationCount(before: cutoff)
        let selected = period.startSeconds >= cutoff
        guard storage.count - expired + (selected ? 1 : 0) <= maximumPeriodCount else {
            throw JitterError.capacityExceeded
        }
        storage.expire(expired)
        storage.append(period, dependency: dependency, selected: selected)
        latestPeriodEnd = period.endSeconds
        upstreamEnd = max(upstreamEnd, dependency.endSample)
        appendedCount += 1
    }

    /// Minimum conservative source envelope needed for this query. It includes
    /// the window, each retained input's upstream support, and connected left
    /// denominator context. This read does not advance or expire state.
    public func requiredDependency(atSourceSample clock: Int64) throws -> SourceInterval {
        guard !busy else { throw JitterError.reentrantCall }
        return try dependency(at: clock)
    }

    /// The caller supplies acquisition coverage and host/source anchors for the
    /// returned dependency envelope. They cannot be reconstructed from overlapping
    /// upstream blocks. Period flags remain immutable; reset/replay after edits.
    public func result(
        atSourceSample clock: Int64, dependencyTiming: AnalysisTiming,
        sourceUnavailability: UnavailabilityReason? = nil
    ) throws -> JitterAnalysisResult {
        guard !busy else { throw JitterError.reentrantCall }
        let required = try dependency(at: clock)
        let timing = dependencyTiming
        guard timing.source.epoch == origin.epoch,
            timing.source.sampleRate == origin.sampleRate,
            timing.source.startSample >= origin.startSample,
            timing.source.startSample <= required.startSample,
            timing.source.endSample >= required.endSample,
            analyzedCount < .max
        else { throw JitterError.unexpectedContext }
        let start = windowStart(at: clock)
        let window = try SourceInterval(
            epoch: origin.epoch, startSample: start,
            sampleCount: clock - start, sampleRate: origin.sampleRate)
        let query = try JitterQueryRange(
            startSeconds: Double(start - timing.source.startSample) / origin.sampleRate,
            endSeconds: Double(clock - timing.source.startSample) / origin.sampleRate)
        let expired = storage.expirationCount(before: relativeSeconds(start))
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 50
        metadata.frameSequence = analyzedCount
        metadata.sampleCount = UInt32(clamping: timing.source.sampleCount)
        metadata.elapsedProcessingCount = appendedCount
        busy = true
        defer { busy = false }
        let result = diagnostics.withFrame(metadata, stage: .perturbation) {
            storage.expire(expired)
            let excluded = timing.includedSampleCount == 0
            let raw = storage.result(requested: requested, excluded: excluded)
            let stale =
                storage.count == 0
                && latestPeriodEnd.map { $0 <= relativeSeconds(start) } == true
            return JitterAnalysisResult(
                raw: raw, configuration: configuration, identity: identity, timing: timing,
                query: query, provenance: provenance, inputCount: storage.inputCount,
                sourceRejections: storage.rejectionCounts(excluded: excluded),
                sourceUnavailability: sourceUnavailability ?? (stale ? .stale : nil),
                requested: requested, sampleAlignedQuery: window)
        }
        queryClock = clock
        analyzedCount += 1
        return result
    }

    private func dependency(at clock: Int64) throws -> SourceInterval {
        guard clock >= queryClock, clock >= upstreamEnd else { throw JitterError.unexpectedContext }
        let start = windowStart(at: clock)
        let expired = storage.expirationCount(before: relativeSeconds(start))
        let dependencyStart = min(start, storage.dependencyStart(expiring: expired) ?? start)
        return try SourceInterval(
            epoch: origin.epoch, startSample: dependencyStart,
            sampleCount: clock - dependencyStart, sampleRate: origin.sampleRate)
    }

    private func windowStart(at clock: Int64) -> Int64 {
        max(origin.startSample, clock - Int64(configuration.rollingWindowSampleCount!))
    }

    private func relativeSeconds(_ sample: Int64) -> Double {
        Double(sample - origin.startSample) / origin.sampleRate
    }
}
