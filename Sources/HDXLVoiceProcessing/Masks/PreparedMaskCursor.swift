/// Raw diagnostics retain acquired samples even when selection rejects them.
public enum MaskAnalysisScope: String, Sendable, Hashable, Codable {
    case allEligible, selected
}

/// Region boundaries are mandatory reset/finalization boundaries for consumers.
/// Buffers retain their original sample positions; adjacent callback deliveries
/// must never be concatenated across a changed regionIndex.
public struct MaskRegionContext: Sendable, Hashable {
    public let source: SourceInterval
    public let region: SourceInterval
    public let regionIndex: Int
    public let startsRegion: Bool
    public let endsRegion: Bool
}

public struct MaskProcessReport: Sendable, Hashable {
    public let consumedSampleCount: Int
    public let emittedSampleCount: Int
    public let emittedChunkCount: Int
    public let isCancelled: Bool
}

/// Single-owner synchronous routing of original PCM through a prepared mask.
/// No PCM is retained or joined, and process/skip/reset-to-start allocate no buffers.
/// The consumer must reset its kernel on startsRegion and finalize on endsRegion.
/// Selection construction and owned metadata export belong outside this hot path.
public final class PreparedMaskCursor<Sample: BinaryFloatingPoint & Sendable> {
    public let timeline: MaskTimeline
    public let scope: MaskAnalysisScope
    public private(set) var nextInputSample: Int64
    public private(set) var isCancelled = false
    private let regions: [SourceInterval]
    private var regionIndex = 0
    private var busy = false
    private let diagnostics: WorkerDiagnostics
    private var diagnosticSequence: UInt64 = 0

    public convenience init(timeline: MaskTimeline, scope: MaskAnalysisScope) {
        self.init(timeline: timeline, scope: scope, diagnostics: WorkerDiagnostics())
    }

    package init(timeline: MaskTimeline, scope: MaskAnalysisScope, diagnostics: WorkerDiagnostics) {
        self.diagnostics = diagnostics
        self.timeline = timeline
        self.scope = scope
        regions = scope == .selected ? timeline.selectedRegions : timeline.eligibleRegions
        nextInputSample = timeline.plan.source.startSample
    }

    @discardableResult
    public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (UnsafeBufferPointer<Sample>, MaskRegionContext) -> Void
    ) throws -> MaskProcessReport {
        guard !busy else { throw MaskError.reentrantCall }
        guard !isCancelled else { throw MaskError.invalidState }
        try validate(interval)
        guard interval.sampleCount == Int64(samples.count) else {
            throw MaskError.unexpectedInterval
        }
        for sample in samples where !sample.isFinite { throw MaskError.nonfiniteInput }
        busy = true
        defer { busy = false }
        var consumed = 0
        var emitted = 0
        var chunks = 0
        while consumed < samples.count && !isCancelled {
            while regionIndex < regions.count, regions[regionIndex].endSample <= nextInputSample {
                regionIndex += 1
            }
            guard regionIndex < regions.count else {
                nextInputSample = interval.endSample
                consumed = samples.count
                break
            }
            let region = regions[regionIndex]
            if nextInputSample < region.startSample {
                let skip = min(interval.endSample, region.startSample) - nextInputSample
                consumed += Int(skip)
                nextInputSample += skip
                continue
            }
            let end = min(interval.endSample, region.endSample)
            let count = Int(end - nextInputSample)
            var metadata = DiagnosticMetadata()
            metadata.profileToken = 3402
            metadata.frameSequence = diagnosticSequence
            metadata.sampleCount = UInt32(clamping: count)
            diagnosticSequence = saturatingAdd(diagnosticSequence)
            let context = try diagnostics.withFrame(metadata) {
                try diagnostics.withInterval(.maskRouting) {
                    let part = try SourceInterval(
                        epoch: interval.epoch, startSample: nextInputSample,
                        sampleCount: Int64(count), sampleRate: interval.sampleRate)
                    return MaskRegionContext(
                        source: part, region: region, regionIndex: regionIndex,
                        startsRegion: part.startSample == region.startSample,
                        endsRegion: end == region.endSample)
                }
            }
            let buffer = UnsafeBufferPointer(rebasing: samples[consumed..<(consumed + count)])
            consumed += count
            nextInputSample = end
            emitted += count
            chunks += 1
            emit(buffer, context)
        }
        return MaskProcessReport(
            consumedSampleCount: consumed, emittedSampleCount: emitted,
            emittedChunkCount: chunks, isCancelled: isCancelled)
    }

    /// Advance over genuinely absent acquisition without inventing placeholder PCM.
    /// Every skipped sample must be marked missingAcquisition in the resolved plan.
    public func skipMissingAcquisition(_ interval: SourceInterval) throws {
        guard !busy else { throw MaskError.reentrantCall }
        guard !isCancelled else { throw MaskError.invalidState }
        try validate(interval)
        guard interval.sampleCount > 0 else { return }
        var low = 0
        var high = timeline.eligibleRegions.count
        while low < high {
            let middle = low + (high - low) / 2
            if timeline.eligibleRegions[middle].endSample <= interval.startSample {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low < timeline.eligibleRegions.count,
            timeline.eligibleRegions[low].startSample < interval.endSample
        {
            throw MaskError.unexpectedInterval
        }
        nextInputSample = interval.endSample
    }

    /// Replay the same immutable timeline. New source epochs require a new cursor.
    public func resetToStart() throws {
        guard !busy else { throw MaskError.reentrantCall }
        nextInputSample = timeline.plan.source.startSample
        regionIndex = 0
        isCancelled = false
        diagnosticSequence = 0
        diagnostics.reset()
    }

    /// Supported from emit; the current borrowed slice remains valid until return.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        diagnostics.event(.cancelled, validity: .cancelled)
    }

    private func validate(_ interval: SourceInterval) throws {
        let source = timeline.plan.source
        guard interval.epoch == source.epoch, interval.sampleRate == source.sampleRate,
            interval.startSample == nextInputSample, interval.endSample <= source.endSample
        else { throw MaskError.unexpectedInterval }
    }
}
