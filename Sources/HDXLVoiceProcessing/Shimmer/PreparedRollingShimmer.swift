private struct ShimmerRollingEntry {
    let amplitude: ShimmerAmplitudeInput
    let dependency: SourceInterval
}

public struct ShimmerRollingExecutionStatistics: Sendable, Hashable {
    public let preparedBufferBytes: Int
    public let appendedAmplitudeCount: UInt64
    public let analyzedQueryCount: UInt64
    public let retainedAmplitudeCount: Int
    /// Records evaluated across result calls, excluding cheap append/expiration work.
    public let evaluatedAmplitudeCount: UInt64
}

/// Bounded incremental input for exploratory rolling measurements. Amplitude
/// times are relative to the fixed origin, not to each append's dependency.
/// Give independent tracks different run IDs and retain missing sequence indices.
///
/// Append and expiration are amortized O(1) per observation. Each result performs
/// an O(n) scan of its retained window with fresh compensated sums and peak
/// scaling, avoiding accumulation drift and stale denominator normalization.
/// Buffers are allocated during preparation; no waveform/F0 data is retained.
public final class PreparedRollingShimmer {
    public let configuration: ShimmerConfiguration
    public let identity: ProfileIdentity
    public let maximumAmplitudeCount: Int
    public let variant: ShimmerVariant?
    public let provenance: ShimmerInputProvenance
    public private(set) var origin: SourceInterval
    private let entries: UnsafeMutableBufferPointer<ShimmerRollingEntry?>
    private let records: UnsafeMutableBufferPointer<ShimmerKernelAmplitude>
    private let requested: ShimmerRequestedVariants
    private let diagnostics: WorkerDiagnostics
    private var head = 0
    private var count = 0
    private var busy = false
    private var queryClock: Int64
    private var upstreamEnd: Int64
    private var latestTime: Double?
    private var appendedCount: UInt64 = 0
    private var analyzedCount: UInt64 = 0
    private var evaluatedCount: UInt64 = 0

    public var executionStatistics: ShimmerRollingExecutionStatistics {
        ShimmerRollingExecutionStatistics(
            preparedBufferBytes: maximumAmplitudeCount
                * (MemoryLayout<ShimmerRollingEntry?>.stride
                    + MemoryLayout<ShimmerKernelAmplitude>.stride),
            appendedAmplitudeCount: appendedCount, analyzedQueryCount: analyzedCount,
            retainedAmplitudeCount: count, evaluatedAmplitudeCount: evaluatedCount)
    }

    public convenience init(
        configuration: ShimmerConfiguration, origin: SourceInterval,
        maximumAmplitudeCount: Int, variant: ShimmerVariant? = nil,
        provenance: ShimmerInputProvenance = .init()
    ) throws {
        try self.init(
            configuration: configuration, origin: origin,
            maximumAmplitudeCount: maximumAmplitudeCount, variant: variant, provenance: provenance,
            diagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: ShimmerConfiguration, origin: SourceInterval,
        maximumAmplitudeCount: Int, variant: ShimmerVariant? = nil,
        provenance: ShimmerInputProvenance = .init(), diagnostics: WorkerDiagnostics
    ) throws {
        guard configuration.applicability == .exploratoryRolling, origin.sampleCount == 0,
            origin.sampleRate == Double(configuration.sampleRate),
            provenance.kind == .suppliedAmplitudes
        else { throw ShimmerError.invalidConfiguration }
        guard (1...ShimmerConfiguration.maximumAmplitudeCount).contains(maximumAmplitudeCount)
        else {
            throw ShimmerError.capacityExceeded
        }
        self.configuration = configuration
        identity = try configuration.identity()
        self.origin = origin
        self.maximumAmplitudeCount = maximumAmplitudeCount
        self.variant = variant
        self.provenance = provenance
        self.diagnostics = diagnostics
        requested = variant.map(ShimmerRequestedVariants.init) ?? .all
        queryClock = origin.startSample
        upstreamEnd = origin.startSample
        entries = .allocate(capacity: maximumAmplitudeCount)
        entries.initialize(repeating: nil)
        records = .allocate(capacity: maximumAmplitudeCount)
        records.initialize(
            repeating: ShimmerKernelAmplitude(
                timeSeconds: 0, amplitude: 0,
                selected: false, reliable: false, connectsToPrevious: false))
    }

    deinit {
        entries.deinitialize()
        entries.deallocate()
        records.deinitialize()
        records.deallocate()
    }

    public func reset(origin replacement: SourceInterval? = nil) throws {
        guard !busy else { throw ShimmerError.reentrantCall }
        let next = replacement ?? origin
        guard next.sampleCount == 0, next.sampleRate == Double(configuration.sampleRate) else {
            throw ShimmerError.unexpectedContext
        }
        busy = true
        defer { busy = false }
        expire(count)
        head = 0
        origin = next
        queryClock = next.startSample
        upstreamEnd = next.startSample
        latestTime = nil
        appendedCount = 0
        analyzedCount = 0
        evaluatedCount = 0
        diagnostics.reset()
    }

    /// Validate before mutation. Dependency is the entire upstream support, e.g.
    /// the pulse-tracking block. Overlapping supports are permitted; observations
    /// themselves must arrive once in strictly increasing time order.
    public func append(_ amplitude: ShimmerAmplitudeInput, dependency: SourceInterval) throws {
        guard !busy else { throw ShimmerError.reentrantCall }
        guard dependency.epoch == origin.epoch, dependency.sampleRate == origin.sampleRate,
            dependency.startSample >= origin.startSample,
            latestTime.map({ amplitude.timeSeconds > $0 && (amplitude.timeSeconds - $0).isFinite })
                ?? true,
            amplitude.timeSeconds <= relativeSeconds(dependency.endSample),
            amplitude.timeSeconds >= relativeSeconds(dependency.startSample)
                || amplitude.rejections.contains(.missingAcquisition), appendedCount < .max
        else { throw ShimmerError.unexpectedContext }
        let clock = max(queryClock, max(upstreamEnd, dependency.endSample))
        let cutoff = relativeSeconds(windowStart(at: clock))
        let expired = expirationCount(before: cutoff)
        let selected = amplitude.timeSeconds >= cutoff
        guard count - expired + (selected ? 1 : 0) <= maximumAmplitudeCount else {
            throw ShimmerError.capacityExceeded
        }
        expire(expired)
        if selected {
            entries[(head + count) % maximumAmplitudeCount] = ShimmerRollingEntry(
                amplitude: amplitude, dependency: dependency)
            count += 1
        }
        latestTime = amplitude.timeSeconds
        upstreamEnd = max(upstreamEnd, dependency.endSample)
        appendedCount += 1
    }

    /// Includes the window and the complete upstream support of retained records.
    /// This read does not expire history or advance the clock.
    public func requiredDependency(atSourceSample clock: Int64) throws -> SourceInterval {
        guard !busy else { throw ShimmerError.reentrantCall }
        return try dependency(at: clock)
    }

    public func result(
        atSourceSample clock: Int64, dependencyTiming: AnalysisTiming,
        sourceUnavailability: UnavailabilityReason? = nil
    ) throws -> ShimmerAnalysisResult {
        guard !busy else { throw ShimmerError.reentrantCall }
        let required = try dependency(at: clock)
        let timing = dependencyTiming
        guard timing.source.epoch == origin.epoch, timing.source.sampleRate == origin.sampleRate,
            timing.source.startSample >= origin.startSample,
            timing.source.startSample <= required.startSample,
            timing.source.endSample >= required.endSample,
            analyzedCount < .max, UInt64(count) <= UInt64.max - evaluatedCount
        else { throw ShimmerError.unexpectedContext }
        let start = windowStart(at: clock)
        let window = try SourceInterval(
            epoch: origin.epoch, startSample: start,
            sampleCount: clock - start, sampleRate: origin.sampleRate)
        let query = try ShimmerQueryRange(
            startSeconds: Double(start - timing.source.startSample) / origin.sampleRate,
            endSeconds: Double(clock - timing.source.startSample) / origin.sampleRate)
        let expired = expirationCount(before: relativeSeconds(start))
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 51
        metadata.frameSequence = analyzedCount
        metadata.sampleCount = UInt32(clamping: timing.source.sampleCount)
        metadata.elapsedProcessingCount = appendedCount
        busy = true
        defer { busy = false }
        let output = diagnostics.withFrame(metadata, stage: .perturbation) {
            expire(expired)
            var reasons = ShimmerRejectionCounts()
            for i in 0..<count {
                let a = entry(i).amplitude
                var flags = a.rejections
                if timing.includedSampleCount == 0 { flags.insert(.excluded) }
                let connected: Bool
                if i > 0 {
                    let previous = entry(i - 1).amplitude
                    connected =
                        previous.runID == a.runID && previous.sequenceIndex < .max
                        && previous.sequenceIndex + 1 == a.sequenceIndex
                } else {
                    connected = false
                }
                records[i] = ShimmerKernelAmplitude(
                    timeSeconds: a.timeSeconds, amplitude: a.amplitude ?? 0,
                    selected: true, reliable: a.amplitude != nil && flags.isEmpty,
                    connectsToPrevious: connected)
                reasons.add(flags)
            }
            let raw = ShimmerKernel.evaluate(
                UnsafeBufferPointer(start: records.baseAddress, count: count),
                configuration: configuration, requested: requested)
            let stale = count == 0 && latestTime.map { $0 < relativeSeconds(start) } == true
            return ShimmerAnalysisResult(
                raw: raw, configuration: configuration, identity: identity,
                timing: timing, query: query, provenance: provenance, inputCount: count,
                sourceRejections: reasons,
                sourceUnavailability: sourceUnavailability ?? (stale ? .stale : nil),
                requested: requested, sampleAlignedQuery: window)
        }
        queryClock = clock
        analyzedCount += 1
        evaluatedCount += UInt64(count)
        return output
    }

    private func entry(_ index: Int) -> ShimmerRollingEntry {
        entries[(head + index) % maximumAmplitudeCount]!
    }

    private func expirationCount(before cutoff: Double) -> Int {
        var expired = 0
        while expired < count && entry(expired).amplitude.timeSeconds < cutoff { expired += 1 }
        return expired
    }

    private func expire(_ number: Int) {
        for _ in 0..<number {
            entries[head] = nil
            head = (head + 1) % maximumAmplitudeCount
            count -= 1
        }
    }

    private func dependency(at clock: Int64) throws -> SourceInterval {
        guard clock >= queryClock, clock >= upstreamEnd else {
            throw ShimmerError.unexpectedContext
        }
        let start = windowStart(at: clock)
        let expired = expirationCount(before: relativeSeconds(start))
        var dependencyStart = start
        for i in expired..<count {
            dependencyStart = min(dependencyStart, entry(i).dependency.startSample)
        }
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
