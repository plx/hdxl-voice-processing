/// One synchronous worker for matching finite and continuous numerical profiles.
/// Input tiling makes dispatch independent of the caller's chunk partition. Prepare
/// and serialize on a worker; never call from capture, and never reenter from emit.
public final class PreparedAnalysisSchedule<Sample: BinaryFloatingPoint & Sendable> {
    public static var maximumSourceSamples: Int64 { 1 << 48 }
    public let profile: AnalysisScheduleProfile
    public let identity: ProfileIdentity
    public let mode: AnalysisScheduleMode
    public let sourceTileCapacity: Int
    public let mask: PreparedAnalysisMask?
    public private(set) var origin: AnalysisScheduleOrigin
    public private(set) var expectedSampleCount: Int64?
    public private(set) var receivedSampleCount: Int64 = 0
    public private(set) var emittedFrameCount: UInt64 = 0
    public var isCancelled: Bool { state == .cancelled }

    private enum State { case prepared, finished, cancelled, failed }
    private var state = State.prepared
    private var busy = false
    private var tile: UnsafeMutableBufferPointer<Sample>
    private var tileCount = 0
    private var dispatchedSampleCount: Int64 = 0
    private var levelWorker: PreparedLevelAnalyzer<Sample>?
    private var pitchWorker: PreparedYINAnalyzer<Sample>?
    private var previewWorker: PreparedPreviewCPPS<Sample>?
    private var intervalWorker: PreparedIntervalCPPS<Sample>?
    private var callbackError: (any Error)?
    private var completion: AnalysisScheduleCompletion?
    private let cppsIdentity: ProfileIdentity?

    public var preparedBufferBytes: Int {
        tile.count * MemoryLayout<Sample>.stride
            + (levelWorker?.executionStatistics.preparedBufferBytes ?? 0)
            + (pitchWorker?.preparedBufferBytes ?? 0)
            + (previewWorker?.scalarWorkspaceBytes ?? 0)
            + (previewWorker?.smoothingRecordWorkspaceBytes ?? 0)
            + (intervalWorker?.scalarWorkspaceBytes ?? 0)
            + (intervalWorker?.smoothingRecordWorkspaceBytes ?? 0)
    }

    public init(
        profile: AnalysisScheduleProfile, origin: AnalysisScheduleOrigin,
        mode: AnalysisScheduleMode, expectedSampleCount: Int64? = nil,
        sourceTileCapacity: Int = 256, mask: PreparedAnalysisMask? = nil
    ) throws {
        try Self.validate(
            profile: profile, origin: origin, mode: mode,
            expectedSampleCount: expectedSampleCount, capacity: sourceTileCapacity)
        self.profile = profile
        self.identity = try profile.identity()
        self.cppsIdentity = try profile.cpps?.identity()
        self.origin = origin
        self.mode = mode
        self.expectedSampleCount = expectedSampleCount
        self.sourceTileCapacity = sourceTileCapacity
        self.mask = mask
        try Self.validateMask(mask, origin: origin, count: expectedSampleCount)
        self.tile = .allocate(capacity: sourceTileCapacity)
        tile.initialize(repeating: 0)
        do { try prepareWorkers() } catch {
            tile.deinitialize()
            tile.deallocate()
            tile = .init(start: nil, count: 0)
            throw error
        }
    }

    deinit {
        tile.deinitialize()
        tile.deallocate()
    }

    private static func validate(
        profile: AnalysisScheduleProfile, origin: AnalysisScheduleOrigin,
        mode: AnalysisScheduleMode, expectedSampleCount: Int64?, capacity: Int
    ) throws {
        try profile.validate(mode: mode)
        guard
            (Sample.self == Float.self && profile.inputPrecision == .float32)
                || (Sample.self == Double.self && profile.inputPrecision == .float64)
        else { throw AnalysisScheduleError.precisionMismatch }
        guard origin.source.sampleRate == profile.inputFormat.sampleRate,
            (1...4096).contains(capacity),
            expectedSampleCount.map({ (0...maximumSourceSamples).contains($0) })
                ?? (mode == .continuous)
        else { throw AnalysisScheduleError.invalidConfiguration }
        if let count = expectedSampleCount {
            _ = try SourceInterval(
                epoch: origin.source.epoch, startSample: origin.source.startSample,
                sampleCount: count, sampleRate: origin.source.sampleRate)
            _ = try origin.hostNanoseconds(atAnalysisSample: count)
            _ = try origin.sourceSeconds(atAnalysisSample: count)
            _ = try origin.wallClockUnixSeconds(atAnalysisSample: count)
        }
    }

    private func localInterval(start: Int64, count: Int64) throws -> SourceInterval {
        try SourceInterval(
            epoch: origin.continuityEpoch, startSample: start,
            sampleCount: count, sampleRate: origin.source.sampleRate)
    }

    private static func validateMask(
        _ mask: PreparedAnalysisMask?, origin: AnalysisScheduleOrigin, count: Int64?
    ) throws {
        guard let mask else { return }
        let source = try SourceInterval(
            epoch: origin.source.epoch, startSample: origin.source.startSample,
            sampleCount: count ?? 0, sampleRate: origin.source.sampleRate)
        try mask.validateRegion(source)
    }

    private func prepareWorkers() throws {
        if let levels = profile.levels {
            levelWorker = try PreparedLevelAnalyzer(
                configuration: levels, epoch: origin.continuityEpoch)
        }
        if let pitch = profile.pitch {
            pitchWorker = try PreparedYINAnalyzer(profile: pitch, epoch: origin.continuityEpoch)
        }
        if let cpps = profile.cpps {
            if cpps.cepstrogram.previewHopLength != nil {
                previewWorker = try PreparedPreviewCPPS(
                    profile: cpps, epoch: origin.continuityEpoch)
            } else if let count = expectedSampleCount, count > 0 {
                intervalWorker = try PreparedIntervalCPPS(
                    profile: cpps, source: localInterval(start: 0, count: count))
            }
        }
    }

    /// Sets the first acquisition anchor once it becomes known. No sample or
    /// kernel state may have been consumed; the analysis continuity epoch stays
    /// unchanged. After input, use reset to establish a new continuity region.
    public func setOriginBeforeInput(_ next: AnalysisScheduleOrigin) throws {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        guard state == .prepared, receivedSampleCount == 0, emittedFrameCount == 0,
            next.continuityEpoch == origin.continuityEpoch
        else { throw AnalysisScheduleError.invalidState }
        try Self.validate(
            profile: profile, origin: next, mode: mode,
            expectedSampleCount: expectedSampleCount, capacity: sourceTileCapacity)
        try Self.validateMask(mask, origin: next, count: expectedSampleCount)
        origin = next
    }

    /// Interleaved native-precision PCM. The complete input is validated before
    /// state changes; arbitrarily sized input is converted through fixed scratch.
    @discardableResult public func processInterleaved(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (ScheduledFrame) -> Void
    ) throws -> AnalysisScheduleProcessReport {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        let channels = profile.inputFormat.channelCount
        guard profile.inputFormat.layout == .interleaved,
            samples.count % channels == 0,
            Int64(samples.count / channels) == interval.sampleCount
        else { throw AnalysisScheduleError.unexpectedInput }
        return try process(
            interval: interval,
            sampleAt: { frame, channel in
                samples[frame * channels + channel]
            }, emit: emit)
    }

    /// One borrowed plane per configured channel. Descriptors and samples remain
    /// borrowed only for this call; channel conversion uses the same fixed scratch.
    @discardableResult public func processPlanar(
        _ planes: UnsafeBufferPointer<UnsafeBufferPointer<Sample>>, interval: SourceInterval,
        emit: (ScheduledFrame) -> Void
    ) throws -> AnalysisScheduleProcessReport {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        guard profile.inputFormat.layout == .planar,
            planes.count == profile.inputFormat.channelCount,
            planes.allSatisfy({ Int64($0.count) == interval.sampleCount })
        else { throw AnalysisScheduleError.unexpectedInput }
        return try process(
            interval: interval,
            sampleAt: { frame, channel in
                planes[channel][frame]
            }, emit: emit)
    }

    private func process(
        interval: SourceInterval, sampleAt: (Int, Int) -> Sample,
        emit: (ScheduledFrame) -> Void
    ) throws -> AnalysisScheduleProcessReport {
        guard state == .prepared else { throw AnalysisScheduleError.invalidState }
        let channels = profile.inputFormat.channelCount
        guard interval.epoch == origin.source.epoch,
            interval.sampleRate == origin.source.sampleRate,
            interval.startSample == origin.source.startSample + receivedSampleCount,
            interval.sampleCount <= Int64(Int.max / channels),
            interval.sampleCount <= Self.maximumSourceSamples - receivedSampleCount,
            expectedSampleCount.map({ interval.sampleCount <= $0 - receivedSampleCount }) ?? true
        else { throw AnalysisScheduleError.unexpectedInput }
        for frame in 0..<Int(interval.sampleCount) {
            for channel in 0..<channels where !sampleAt(frame, channel).isFinite {
                throw AnalysisScheduleError.invalidInput
            }
        }
        let newCount = receivedSampleCount + interval.sampleCount
        try mask?.validateRegion(
            origin.sourceInterval(for: localInterval(start: 0, count: newCount)))
        _ = try origin.hostNanoseconds(atAnalysisSample: newCount)
        _ = try origin.sourceSeconds(atAnalysisSample: newCount)
        _ = try origin.wallClockUnixSeconds(atAnalysisSample: newCount)
        busy = true
        callbackError = nil
        let before = emittedFrameCount
        var consumed = 0
        defer {
            busy = false
            callbackError = nil
            releaseIfCancelled()
        }
        do {
            while consumed < Int(interval.sampleCount), state == .prepared {
                let amount = min(
                    sourceTileCapacity - tileCount, Int(interval.sampleCount) - consumed)
                for frame in 0..<amount {
                    if let channel = profile.channels.channelIndex {
                        tile[tileCount + frame] = sampleAt(consumed + frame, channel)
                    } else {
                        var peak = 0.0
                        for channel in 0..<channels {
                            peak = max(peak, abs(Double(sampleAt(consumed + frame, channel))))
                        }
                        var sum = 0.0
                        var correction = 0.0
                        if peak > 0 {
                            for channel in 0..<channels {
                                let value = Double(sampleAt(consumed + frame, channel)) / peak
                                let next = sum + value
                                correction +=
                                    abs(sum) >= abs(value)
                                    ? (sum - next) + value : (value - next) + sum
                                sum = next
                            }
                        }
                        // The exact normalized mean lies within [-1, 1]. Clamp only
                        // rounding beyond that bound before restoring extreme scale.
                        let normalized = max(-1, min(1, (sum + correction) / Double(channels)))
                        tile[tileCount + frame] = Sample(normalized * peak)
                    }
                }
                consumed += amount
                receivedSampleCount += Int64(amount)
                tileCount += amount
                if tileCount == sourceTileCapacity { try dispatchTile(emit: emit) }
            }
            return AnalysisScheduleProcessReport(
                consumedSourceSamples: consumed,
                emittedFrames: Int(emittedFrameCount - before), isCancelled: isCancelled)
        } catch {
            if state != .cancelled { state = .failed }
            throw error
        }
    }

    private func dispatchTile(emit: (ScheduledFrame) -> Void) throws {
        guard tileCount > 0 else { return }
        let input = UnsafeBufferPointer(rebasing: tile[0..<tileCount])
        let interval = try localInterval(start: dispatchedSampleCount, count: Int64(tileCount))
        if let levelWorker {
            _ = try levelWorker.process(input, interval: interval) { value in
                deliver(.levels(value), emit: emit)
            }
        }
        if state == .prepared, callbackError == nil, let pitchWorker {
            _ = try pitchWorker.process(input, interval: interval) { value in
                deliver(.pitch(raw: value.raw.result, tracked: value.tracked), emit: emit)
            }
        }
        if state == .prepared, callbackError == nil, let previewWorker {
            _ = try previewWorker.process(input, interval: interval) { value in
                deliver(.cpps(value.result), emit: emit)
            }
        }
        if state == .prepared, callbackError == nil, let intervalWorker {
            try intervalWorker.append(input, interval: interval)
        }
        dispatchedSampleCount += Int64(tileCount)
        tileCount = 0
        if let callbackError { throw callbackError }
    }

    private func deliver(_ value: ScheduledFrameValue, emit: (ScheduledFrame) -> Void) {
        guard state == .prepared, callbackError == nil else { return }
        do {
            let native: AnalysisTiming
            let center: Double
            switch value {
            case .levels(let value):
                if let history = value.filterHistorySource, let weighted = value.weightedTiming {
                    native = try AnalysisTiming(
                        source: history,
                        includedSampleCount: weighted.includedSampleCount,
                        effectiveDelaySeconds: weighted.effectiveDelaySeconds)
                } else {
                    native = value.unweightedTiming
                }
                center =
                    Double(value.source.startSample) / value.source.sampleRate
                    + value.source.durationSeconds / 2
            case .pitch(let raw, let tracked):
                native = tracked?.dependencyTiming ?? raw.timing
                center =
                    Double(raw.timing.source.startSample) / raw.timing.source.sampleRate
                    + raw.timing.source.durationSeconds / 2
            case .cpps(let value):
                native = value.context.timing
                center = value.context.centerSecondsFromOrigin
            }
            let timing = try origin.mappedTiming(native)
            emittedFrameCount += 1
            emit(
                ScheduledFrame(
                    schedule: identity, origin: origin, value: value, timing: timing,
                    coverage: try mask?.coverage(of: timing.source)
                        ?? .acquired(timing.source.sampleCount),
                    mask: mask?.provenance,
                    frameCenterSecondsFromOrigin: center,
                    workerBatchingUpperBoundSeconds: Double(sourceTileCapacity)
                        / origin.source.sampleRate))
        } catch { callbackError = error }
    }

    /// Flushes the actual final source tile, then each kernel's declared tail once.
    /// A finite source must be complete. Finish never substitutes zeros for missing PCM.
    @discardableResult public func finish(emit: (ScheduledFrame) -> Void) throws
        -> AnalysisScheduleCompletion
    {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        if let completion { return completion }
        guard state == .prepared else { throw AnalysisScheduleError.invalidState }
        guard expectedSampleCount.map({ $0 == receivedSampleCount }) ?? true else {
            throw AnalysisScheduleError.unexpectedInput
        }
        busy = true
        callbackError = nil
        defer {
            busy = false
            callbackError = nil
            releaseIfCancelled()
        }
        do {
            try dispatchTile(emit: emit)
            let levels =
                state == .prepared
                ? try levelWorker?.finish { value in
                    deliver(.levels(value), emit: emit)
                } : nil
            if let callbackError { throw callbackError }
            let pitch =
                state == .prepared
                ? try pitchWorker?.finish { value in
                    deliver(.pitch(raw: value.raw.result, tracked: value.tracked), emit: emit)
                } : nil
            if let callbackError { throw callbackError }
            var cpps: CPPSCompletion?
            if state == .prepared, let previewWorker {
                cpps = try previewWorker.finish { deliver(.cpps($0.result), emit: emit) }
            } else if state == .prepared, let intervalWorker {
                cpps = try intervalWorker.finish { deliver(.cpps($0.result), emit: emit) }
            } else if state == .prepared, let cppsIdentity, receivedSampleCount == 0 {
                cpps = try CPPSCompletion(
                    profile: cppsIdentity, source: localInterval(start: 0, count: 0),
                    frameCount: 0, availableFrameCount: 0, meanDB: nil,
                    unavailability: .insufficientData)
            }
            if let callbackError { throw callbackError }
            let observed = try origin.sourceInterval(
                for: localInterval(start: 0, count: receivedSampleCount))
            let result = try AnalysisScheduleCompletion(
                schedule: identity, origin: origin,
                observedSource: observed,
                coverage: mask?.coverage(of: observed) ?? .acquired(observed.sampleCount),
                mask: mask?.provenance,
                emittedFrames: emittedFrameCount, levels: levels, pitch: pitch, cpps: cpps,
                isCancelled: isCancelled)
            if state != .cancelled {
                state = .finished
                completion = result
            }
            return result
        } catch {
            if state != .cancelled { state = .failed }
            throw error
        }
    }

    /// Starts a separately analyzed continuity region. Ordinary streaming resets
    /// reuse scratch. A different whole-interval size prepares a replacement first;
    /// restart after cancellation allocates on this explicit control path.
    /// Finish before resetting only when the old region's labelled tail is wanted.
    @discardableResult public func reset(
        origin next: AnalysisScheduleOrigin, expectedSampleCount count: Int64? = nil,
        reason: ResetReason = .explicitReset, missingSource: SourceInterval? = nil
    ) throws -> AnalysisScheduleReset {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        try Self.validate(
            profile: profile, origin: next, mode: mode,
            expectedSampleCount: count, capacity: sourceTileCapacity)
        try Self.validateMask(mask, origin: next, count: count)
        let boundary = try SourceDiscontinuity(
            previousEpoch: origin.continuityEpoch, nextEpoch: next.continuityEpoch, reason: reason)
        let observed = try origin.sourceInterval(
            for: localInterval(start: 0, count: receivedSampleCount))
        if let missingSource {
            guard missingSource.sampleCount > 0, missingSource.epoch == origin.source.epoch,
                missingSource.sampleRate == origin.source.sampleRate,
                missingSource.startSample == observed.endSample,
                next.source.epoch != origin.source.epoch
                    || next.source.startSample == missingSource.endSample
            else { throw AnalysisScheduleError.invalidGap }
        }
        // All factories that can reject a new configuration run before old state
        // changes. Existing workers then reset with the already validated boundary.
        let newLevel: PreparedLevelAnalyzer<Sample>?
        if levelWorker == nil, let configuration = profile.levels {
            newLevel = try PreparedLevelAnalyzer(
                configuration: configuration, epoch: next.continuityEpoch)
        } else {
            newLevel = nil
        }
        let newPitch: PreparedYINAnalyzer<Sample>?
        if pitchWorker == nil, let profile = profile.pitch {
            newPitch = try PreparedYINAnalyzer(profile: profile, epoch: next.continuityEpoch)
        } else {
            newPitch = nil
        }
        let newPreview: PreparedPreviewCPPS<Sample>?
        if previewWorker == nil, let profile = profile.cpps,
            profile.cepstrogram.previewHopLength != nil
        {
            newPreview = try PreparedPreviewCPPS(profile: profile, epoch: next.continuityEpoch)
        } else {
            newPreview = nil
        }
        let nextInterval = try SourceInterval(
            epoch: next.continuityEpoch, startSample: 0, sampleCount: count ?? 0,
            sampleRate: next.source.sampleRate)
        let reuseInterval = intervalWorker != nil && count == expectedSampleCount
        let newInterval: PreparedIntervalCPPS<Sample>?
        if let profile = profile.cpps, profile.cepstrogram.previewHopLength == nil,
            let count, count > 0, !reuseInterval
        {
            newInterval = try PreparedIntervalCPPS(profile: profile, source: nextInterval)
        } else {
            newInterval = nil
        }

        try levelWorker?.reset(for: boundary)
        try pitchWorker?.reset(for: boundary)
        try previewWorker?.reset(for: boundary)
        if reuseInterval { try intervalWorker?.reset(source: nextInterval) }
        if let newLevel { levelWorker = newLevel }
        if let newPitch { pitchWorker = newPitch }
        if let newPreview { previewWorker = newPreview }
        if !reuseInterval { intervalWorker = newInterval }
        if tile.baseAddress == nil {
            tile = .allocate(capacity: sourceTileCapacity)
            tile.initialize(repeating: 0)
        }
        let report = AnalysisScheduleReset(
            previousOrigin: origin, nextOrigin: next, observedSource: observed,
            dispatchedSourceSamples: dispatchedSampleCount,
            pendingSourceSamplesDiscarded: tileCount, missingSource: missingSource, reason: reason)
        origin = next
        expectedSampleCount = count
        receivedSampleCount = 0
        dispatchedSampleCount = 0
        tileCount = 0
        emittedFrameCount = 0
        completion = nil
        callbackError = nil
        state = .prepared
        return report
    }

    /// Cooperative cancellation retains the active borrow until its callback returns.
    /// Other threads must not call this single-owner worker directly.
    public func cancel() {
        state = .cancelled
        completion = nil
        if !busy { releaseIfCancelled() }
    }

    private func releaseIfCancelled() {
        guard state == .cancelled else { return }
        levelWorker = nil
        pitchWorker = nil
        previewWorker = nil
        intervalWorker = nil
        if tile.baseAddress != nil {
            tile.deinitialize()
            tile.deallocate()
            tile = .init(start: nil, count: 0)
        }
        tileCount = 0
    }
}
