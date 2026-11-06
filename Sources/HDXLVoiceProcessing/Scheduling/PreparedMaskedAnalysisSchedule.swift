public enum MaskedScheduleOutcome: String, Sendable, Hashable {
    case completed, noEligibleSamples, noSelectedSamples, cancelled
}

/// Region aggregates are emitted individually; numerical means are not silently
/// combined across separate clips or unequal selected regions.
public struct MaskedScheduleCompletion: Sendable, Hashable {
    public let schedule: ProfileIdentity
    public let mask: AnalysisMaskProvenance
    public let observedSource: SourceInterval
    public let coverage: AnalysisCoverageCounts
    public let analyzedSampleCount: Int64
    public let completedRegionCount: Int
    public let outcome: MaskedScheduleOutcome
}

/// Routes a finite, immutable segmentation through the shared engine. The same
/// plan can be replayed from memory, a file or continuous delivery. Continuous
/// delivery still rejects whole-interval numerical profiles. No detector runs here.
/// Each selected/eligible region is finalized and reset separately; missing input
/// must be advanced with skipMissingAcquisition rather than placeholder zeros.
public final class PreparedMaskedAnalysisSchedule<Sample: BinaryFloatingPoint & Sendable> {
    public let profile: AnalysisScheduleProfile
    public let identity: ProfileIdentity
    public let mask: PreparedAnalysisMask
    public private(set) var origin: AnalysisScheduleOrigin
    public let mode: AnalysisScheduleMode
    public private(set) var nextInputSample: Int64
    public private(set) var analyzedSampleCount: Int64 = 0
    public private(set) var completedRegionCount = 0
    public var isCancelled: Bool { state == .cancelled }

    private enum State { case prepared, finished, cancelled, failed }
    private enum Input {
        case interleaved(UnsafeBufferPointer<Sample>)
        case planar(UnsafeBufferPointer<UnsafeBufferPointer<Sample>>)
    }
    private var state = State.prepared
    private var busy = false
    private let regions: [SourceInterval]
    private var regionIndex = 0
    private var worker: PreparedAnalysisSchedule<Sample>?
    private var planarSlices: UnsafeMutableBufferPointer<UnsafeBufferPointer<Sample>>
    private var completion: MaskedScheduleCompletion?

    /// Includes coverage prefix counts and channel descriptors. Immutable mask
    /// observations and native FFT setup/object overhead are reported separately.
    public var preparedBufferBytes: Int {
        (worker?.preparedBufferBytes ?? 0) + mask.preparedCountBytes
            + planarSlices.count * MemoryLayout<UnsafeBufferPointer<Sample>>.stride
    }

    public init(
        profile: AnalysisScheduleProfile, origin: AnalysisScheduleOrigin,
        mode: AnalysisScheduleMode, mask: PreparedAnalysisMask,
        sourceTileCapacity: Int = 256
    ) throws {
        let source = mask.timeline.plan.source
        guard origin.source.epoch == source.epoch,
            origin.source.startSample == source.startSample,
            origin.source.sampleRate == source.sampleRate,
            source.sampleCount <= PreparedAnalysisSchedule<Sample>.maximumSourceSamples
        else { throw AnalysisScheduleError.invalidConfiguration }
        try profile.validate(mode: mode)
        guard
            !origin.continuityEpoch.sequence.addingReportingOverflow(
                UInt64(max(0, mask.regions.count - 1))
            ).overflow
        else { throw ContractError.arithmeticOverflow }
        _ = try origin.hostNanoseconds(atAnalysisSample: source.sampleCount)
        _ = try origin.sourceSeconds(atAnalysisSample: source.sampleCount)
        _ = try origin.wallClockUnixSeconds(atAnalysisSample: source.sampleCount)
        self.profile = profile
        self.identity = try profile.identity()
        self.origin = origin
        self.mode = mode
        self.mask = mask
        self.regions = mask.regions
        self.nextInputSample = source.startSample
        // Validate even an empty selection (including precision, layout and capacity).
        let first = mask.regions.first
        let preparedOrigin = try Self.regionOrigin(
            first?.startSample ?? source.startSample,
            index: 0, origin: origin)
        self.worker = try PreparedAnalysisSchedule(
            profile: profile, origin: preparedOrigin, mode: mode,
            expectedSampleCount: first?.sampleCount ?? 0,
            sourceTileCapacity: sourceTileCapacity, mask: mask)
        self.planarSlices = .allocate(capacity: profile.inputFormat.channelCount)
        planarSlices.initialize(repeating: UnsafeBufferPointer(start: nil, count: 0))
    }

    deinit {
        planarSlices.deinitialize()
        planarSlices.deallocate()
    }

    @discardableResult public func processInterleaved(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (ScheduledFrame) -> Void,
        regionCompleted: (AnalysisScheduleCompletion) -> Void = { _ in }
    ) throws -> AnalysisScheduleProcessReport {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        let channels = profile.inputFormat.channelCount
        guard profile.inputFormat.layout == .interleaved,
            samples.count % channels == 0,
            Int64(samples.count / channels) == interval.sampleCount
        else { throw AnalysisScheduleError.unexpectedInput }
        for sample in samples where !sample.isFinite { throw AnalysisScheduleError.invalidInput }
        return try route(
            input: .interleaved(samples), interval: interval,
            emit: emit, regionCompleted: regionCompleted)
    }

    @discardableResult public func processPlanar(
        _ planes: UnsafeBufferPointer<UnsafeBufferPointer<Sample>>, interval: SourceInterval,
        emit: (ScheduledFrame) -> Void,
        regionCompleted: (AnalysisScheduleCompletion) -> Void = { _ in }
    ) throws -> AnalysisScheduleProcessReport {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        guard profile.inputFormat.layout == .planar,
            planes.count == profile.inputFormat.channelCount,
            planes.allSatisfy({ Int64($0.count) == interval.sampleCount })
        else { throw AnalysisScheduleError.unexpectedInput }
        for plane in planes {
            for sample in plane where !sample.isFinite { throw AnalysisScheduleError.invalidInput }
        }
        defer {
            for index in planarSlices.indices {
                planarSlices[index] = UnsafeBufferPointer(start: nil, count: 0)
            }
        }
        return try route(
            input: .planar(planes), interval: interval,
            emit: emit, regionCompleted: regionCompleted)
    }

    private func route(
        input: Input, interval: SourceInterval, emit: (ScheduledFrame) -> Void,
        regionCompleted: (AnalysisScheduleCompletion) -> Void
    ) throws -> AnalysisScheduleProcessReport {
        try validate(interval)
        guard try mask.coverage(of: interval).missing == 0 else {
            throw AnalysisScheduleError.invalidGap
        }
        // Check projected end clocks before advancing any region or discarding input.
        let end = interval.endSample - origin.source.startSample
        _ = try origin.hostNanoseconds(atAnalysisSample: end)
        _ = try origin.sourceSeconds(atAnalysisSample: end)
        _ = try origin.wallClockUnixSeconds(atAnalysisSample: end)
        busy = true
        defer { busy = false }
        var emitted = 0
        do {
            while nextInputSample < interval.endSample, state == .prepared {
                guard regionIndex < regions.count, let worker else {
                    nextInputSample = interval.endSample
                    break
                }
                let region = regions[regionIndex]
                if nextInputSample < region.startSample {
                    nextInputSample = min(interval.endSample, region.startSample)
                    continue
                }
                if worker.origin.source.startSample != region.startSample {
                    try worker.reset(
                        origin: Self.regionOrigin(
                            region.startSample, index: regionIndex, origin: origin),
                        expectedSampleCount: region.sampleCount)
                }
                let part = try SourceInterval(
                    epoch: interval.epoch, startSample: nextInputSample,
                    sampleCount: min(interval.endSample, region.endSample) - nextInputSample,
                    sampleRate: interval.sampleRate)
                let offset = Int(nextInputSample - interval.startSample)
                let report: AnalysisScheduleProcessReport
                switch input {
                case .interleaved(let samples):
                    let channels = profile.inputFormat.channelCount
                    report = try worker.processInterleaved(
                        UnsafeBufferPointer(
                            rebasing: samples[
                                (offset * channels)..<((offset + Int(part.sampleCount)) * channels)]
                        ),
                        interval: part, emit: emit)
                case .planar(let planes):
                    for index in planes.indices {
                        planarSlices[index] = UnsafeBufferPointer(
                            rebasing: planes[index][offset..<(offset + Int(part.sampleCount))])
                    }
                    report = try worker.processPlanar(
                        UnsafeBufferPointer(planarSlices), interval: part, emit: emit)
                }
                emitted += report.emittedFrames
                nextInputSample += Int64(report.consumedSourceSamples)
                analyzedSampleCount += Int64(report.consumedSourceSamples)
                if state == .prepared, nextInputSample == region.endSample {
                    let result = try worker.finish {
                        emitted += 1
                        emit($0)
                    }
                    if state == .prepared {
                        completedRegionCount += 1
                        regionIndex += 1
                        regionCompleted(result)
                    }
                }
            }
            return AnalysisScheduleProcessReport(
                consumedSourceSamples: Int(nextInputSample - interval.startSample),
                emittedFrames: emitted, isCancelled: isCancelled)
        } catch {
            if state != .cancelled { state = .failed }
            throw error
        }
    }

    public func skipMissingAcquisition(_ interval: SourceInterval) throws {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        try validate(interval)
        guard try mask.coverage(of: interval).eligible == 0 else {
            throw AnalysisScheduleError.invalidGap
        }
        nextInputSample = interval.endSample
    }

    /// All region tails were already emitted at their declared ends. The final
    /// coverage counts source positions once, including explicitly skipped loss.
    public func finish() throws -> MaskedScheduleCompletion {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        if let completion { return completion }
        guard state == .prepared || state == .cancelled else {
            throw AnalysisScheduleError.invalidState
        }
        guard isCancelled || nextInputSample == mask.timeline.plan.source.endSample else {
            throw AnalysisScheduleError.unexpectedInput
        }
        let source = try SourceInterval(
            epoch: origin.source.epoch, startSample: origin.source.startSample,
            sampleCount: nextInputSample - origin.source.startSample,
            sampleRate: origin.source.sampleRate)
        let coverage = try mask.coverage(of: source)
        let outcome: MaskedScheduleOutcome =
            isCancelled
            ? .cancelled
            : coverage.eligible == 0
                ? .noEligibleSamples
                : mask.provenance.scope == .selected && coverage.selected == 0
                    ? .noSelectedSamples
                    : .completed
        let result = MaskedScheduleCompletion(
            schedule: identity, mask: mask.provenance, observedSource: source,
            coverage: coverage, analyzedSampleCount: analyzedSampleCount,
            completedRegionCount: completedRegionCount, outcome: outcome)
        completion = result
        if !isCancelled { state = .finished }
        return result
    }

    public func cancel() {
        state = .cancelled
        completion = nil
        worker?.cancel()
    }

    /// Replays the same immutable source/mask from its start with a fresh analysis
    /// continuity epoch. Streaming scratch and coverage prefixes are reused.
    /// Finish first to retain the previous run's aggregates; otherwise pending work
    /// is discarded. Whole-interval size changes and cancelled workers reprepare.
    public func resetToStart() throws {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        guard let worker else { throw AnalysisScheduleError.invalidState }
        let nextEpoch = try worker.origin.continuityEpoch.successor()
        guard
            !nextEpoch.sequence.addingReportingOverflow(UInt64(max(0, regions.count - 1))).overflow
        else { throw ContractError.arithmeticOverflow }
        let nextOrigin = try AnalysisScheduleOrigin(
            source: origin.source, continuityEpoch: nextEpoch,
            sourceStartSeconds: origin.sourceStartSeconds,
            hostStartNanoseconds: origin.hostStartNanoseconds,
            wallClockStartUnixSeconds: origin.wallClockStartUnixSeconds)
        try worker.reset(
            origin: Self.regionOrigin(
                regions.first?.startSample ?? origin.source.startSample,
                index: 0, origin: nextOrigin), expectedSampleCount: regions.first?.sampleCount ?? 0)
        origin = nextOrigin
        nextInputSample = origin.source.startSample
        analyzedSampleCount = 0
        completedRegionCount = 0
        regionIndex = 0
        completion = nil
        state = .prepared
    }

    private func validate(_ interval: SourceInterval) throws {
        guard state == .prepared else { throw AnalysisScheduleError.invalidState }
        let source = mask.timeline.plan.source
        guard interval.epoch == source.epoch, interval.sampleRate == source.sampleRate,
            interval.startSample == nextInputSample, interval.endSample <= source.endSample
        else { throw AnalysisScheduleError.unexpectedInput }
    }

    private static func regionOrigin(_ start: Int64, index: Int, origin: AnalysisScheduleOrigin)
        throws -> AnalysisScheduleOrigin
    {
        let sequence = origin.continuityEpoch.sequence.addingReportingOverflow(UInt64(index))
        guard !sequence.overflow else { throw ContractError.arithmeticOverflow }
        let offset = start - origin.source.startSample
        return try AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: origin.source.epoch, startSample: start,
                sampleCount: 0, sampleRate: origin.source.sampleRate),
            continuityEpoch: StreamEpoch(
                streamID: origin.continuityEpoch.streamID,
                sequence: sequence.partialValue),
            sourceStartSeconds: origin.sourceSeconds(atAnalysisSample: offset),
            hostStartNanoseconds: origin.hostNanoseconds(atAnalysisSample: offset),
            wallClockStartUnixSeconds: origin.wallClockUnixSeconds(atAnalysisSample: offset))
    }
}
