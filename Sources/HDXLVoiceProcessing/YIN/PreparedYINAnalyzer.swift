private final class YINStreamStorage<Sample: BinaryFloatingPoint & Sendable> {
    let framer: PCMFramer<Sample>
    let estimator: PreparedYIN<Sample>
    let tracker: PreparedYINTracker?

    init(profile: YINProfile, origin: AnalysisTiming, diagnostics: WorkerDiagnostics) throws {
        estimator = try PreparedYIN(profile.estimator, diagnostics: diagnostics)
        framer = try PCMFramer(
            configuration: profile.estimator.framingConfiguration(),
            epoch: origin.source.epoch, startSample: origin.source.startSample,
            diagnostics: diagnostics)
        tracker = try profile.tracker.map { _ in
            try PreparedYINTracker(profile, diagnostics: diagnostics)
        }
    }
}

/// Synchronous single-owner mono PCM worker. Chunking changes delivery, never the
/// integer frame grid or raw numerical estimates. Prepare/reconfigure on a worker;
/// do not call from a real-time capture callback. Ordinary resets reuse storage.
public final class PreparedYINAnalyzer<Sample: BinaryFloatingPoint & Sendable> {
    public private(set) var profile: YINProfile
    public private(set) var identity: ProfileIdentity
    /// Zero-length stream origin; its optional source/host clock anchors are rebased
    /// onto each output. effectiveDelaySeconds is an inherited minimum total delay.
    public private(set) var origin: AnalysisTiming
    public var epoch: StreamEpoch { origin.source.epoch }
    public private(set) var nextInputSample: Int64
    public var estimatorStatistics: YINExecutionStatistics? {
        storage?.estimator.executionStatistics
    }
    /// Framer ring/emission/window coefficients plus estimator buffers. Excludes
    /// object bookkeeping, the small tracker state and opaque vDSP setup tables.
    /// Cancellation releases storage after the current synchronous borrow returns.
    public var preparedBufferBytes: Int {
        guard let storage else { return 0 }
        return storage.estimator.executionStatistics.preparedBufferBytes
            + 3 * profile.estimator.requiredSampleCount * MemoryLayout<Sample>.stride
    }

    private enum State { case prepared, finished, cancelled, failed }
    private var state = State.prepared
    private var storage: YINStreamStorage<Sample>?
    private var busy = false
    private var callbackError: (any Error)?
    private var completion: YINCompletion?
    private let diagnostics: WorkerDiagnostics

    public convenience init(profile: YINProfile, epoch: StreamEpoch, startSample: Int64 = 0) throws
    {
        let source = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: Double(profile.estimator.sampleRate))
        try self.init(
            profile: profile, origin: AnalysisTiming(source: source, includedSampleCount: 0))
    }
    /// An origin has no samples or completion time. Supply actual source/host start
    /// anchors when known; absent clocks remain absent rather than being fabricated.
    public convenience init(profile: YINProfile, origin: AnalysisTiming) throws {
        try self.init(profile: profile, origin: origin, diagnostics: WorkerDiagnostics())
    }
    package init(profile: YINProfile, origin: AnalysisTiming, diagnostics: WorkerDiagnostics) throws
    {
        try Self.validate(origin: origin, profile: profile)
        let identity = try profile.identity()
        let storage = try YINStreamStorage<Sample>(
            profile: profile, origin: origin, diagnostics: diagnostics)
        self.profile = profile
        self.identity = identity
        self.origin = origin
        self.nextInputSample = origin.source.startSample
        self.storage = storage
        self.diagnostics = diagnostics
    }

    /// Invalid chunks are rejected before consumption. An optional completion time
    /// applies to frames emitted by this call and must follow the chunk's end on
    /// the supplied host clock. It is not reused as a later finish-call timestamp.
    /// Cancellation from emit is supported; the returned report names the consumed prefix.
    @discardableResult public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        completedHostNanoseconds: UInt64? = nil,
        emit: (BorrowedYINAnalysisOutput) -> Void
    ) throws -> FramingProcessReport {
        guard !busy else { throw YINError.reentrantCall }
        guard state == .prepared, let storage else { throw YINError.invalidState }
        guard interval.epoch == epoch, interval.startSample == nextInputSample,
            interval.sampleRate == Double(profile.estimator.sampleRate),
            interval.sampleCount == Int64(samples.count)
        else { throw YINError.unexpectedContext }
        for sample in samples where !sample.isFinite { throw YINError.invalidInput }
        try validateClock(endSample: interval.endSample, completed: completedHostNanoseconds)
        busy = true
        defer {
            busy = false
            callbackError = nil
        }
        do {
            let report = try withExtendedLifetime(storage) {
                try storage.framer.process(samples, interval: interval) { frame, support in
                    consume(
                        frame, support: support, completed: completedHostNanoseconds,
                        storage: storage, emit: emit)
                }
            }
            nextInputSample = storage.framer.nextInputSample
            if let callbackError { throw callbackError }
            return report
        } catch {
            nextInputSample = storage.framer.nextInputSample
            state = .failed
            diagnostics.event(.error, validity: .failed)
            throw error
        }
    }

    /// Emits at most the earliest nonempty partial frame, unavailable with its
    /// actual support, unless the profile discards it. Repeated finish is idempotent.
    @discardableResult public func finish(
        completedHostNanoseconds: UInt64? = nil,
        emit: (BorrowedYINAnalysisOutput) -> Void
    ) throws -> YINCompletion {
        guard !busy else { throw YINError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw YINError.invalidState
        }
        if let completion { return completion }
        try validateClock(endSample: nextInputSample, completed: completedHostNanoseconds)
        busy = true
        defer {
            busy = false
            callbackError = nil
        }
        do {
            let framing = try withExtendedLifetime(storage) {
                try storage.framer.finish { frame, support in
                    consume(
                        frame, support: support, completed: completedHostNanoseconds,
                        storage: storage, emit: emit)
                }
            }
            if let callbackError { throw callbackError }
            let result = YINCompletion(framing: framing, isCancelled: state == .cancelled)
            if state != .cancelled {
                state = .finished
                completion = result
            }
            return result
        } catch {
            state = .failed
            diagnostics.event(.error, validity: .failed)
            throw error
        }
    }

    private func consume(
        _ samples: UnsafeBufferPointer<Sample>, support: PCMFrameSupport, completed: UInt64?,
        storage: YINStreamStorage<Sample>, emit: (BorrowedYINAnalysisOutput) -> Void
    ) {
        guard callbackError == nil, state != .cancelled else { return }
        nextInputSample = storage.framer.nextInputSample
        do {
            let timing = try frameTiming(source: support.source, completed: completed)
            try storage.estimator.analyze(samples, timing: timing, frameIndex: support.frameIndex) {
                raw in
                do {
                    let tracked = try storage.tracker?.process(raw)
                    emit(BorrowedYINAnalysisOutput(raw: raw, tracked: tracked))
                } catch { callbackError = error }
            }
        } catch { callbackError = error }
        if callbackError != nil { storage.framer.cancel() }
    }

    /// Discard pending PCM and tracking history. New epoch indices start at zero.
    /// Supply a new optional clock origin; the old epoch's clock is never guessed.
    public func reset(for discontinuity: SourceDiscontinuity, clockOrigin: AnalysisTiming? = nil)
        throws
    {
        guard !busy else { throw YINError.reentrantCall }
        guard discontinuity.previousEpoch == epoch else { throw YINError.unexpectedContext }
        if let missing = discontinuity.missingSource {
            guard missing.startSample == nextInputSample,
                missing.sampleRate == Double(profile.estimator.sampleRate)
            else { throw YINError.unexpectedContext }
        }
        let newOrigin = try Self.newOrigin(
            profile: profile, epoch: discontinuity.nextEpoch, supplied: clockOrigin)
        if let storage {
            try storage.framer.reset(for: discontinuity)
            try storage.tracker?.reset()
        } else {
            let prepared = try YINStreamStorage<Sample>(
                profile: profile, origin: newOrigin, diagnostics: diagnostics)
            storage = prepared
            diagnostics.reset()
        }
        origin = newOrigin
        nextInputSample = 0
        completion = nil
        state = .prepared
    }

    /// Validate and prepare the complete replacement before changing any state.
    public func reconfigure(
        to profile: YINProfile, epoch: StreamEpoch, clockOrigin: AnalysisTiming? = nil
    ) throws {
        guard !busy else { throw YINError.reentrantCall }
        _ = try SourceDiscontinuity(
            previousEpoch: self.epoch, nextEpoch: epoch,
            reason: self.epoch.streamID == epoch.streamID ? .profileChange : .newSource)
        let newOrigin = try Self.newOrigin(profile: profile, epoch: epoch, supplied: clockOrigin)
        let identity = try profile.identity()
        let prepared = try YINStreamStorage<Sample>(
            profile: profile, origin: newOrigin, diagnostics: diagnostics)
        self.profile = profile
        self.identity = identity
        self.origin = newOrigin
        self.storage = prepared
        nextInputSample = 0
        completion = nil
        state = .prepared
        diagnostics.reset()
        diagnostics.event(.configurationChange)
    }

    /// Idempotent and safe from emit. Current borrowed output remains alive until
    /// emit returns; no subsequent frame or partial tail is emitted after cancel.
    public func cancel() {
        guard state != .cancelled else { return }
        if let storage {
            nextInputSample = storage.framer.nextInputSample
            storage.framer.cancel()
        }
        storage = nil
        completion = nil
        state = .cancelled
    }

    private static func validate(origin: AnalysisTiming, profile: YINProfile) throws {
        guard origin.source.sampleRate == Double(profile.estimator.sampleRate),
            origin.source.sampleCount == 0, origin.includedSampleCount == 0,
            origin.completedHostNanoseconds == nil
        else { throw YINError.unexpectedContext }
    }
    private static func newOrigin(
        profile: YINProfile, epoch: StreamEpoch, supplied: AnalysisTiming?
    ) throws -> AnalysisTiming {
        let result =
            try supplied
            ?? AnalysisTiming(
                source: SourceInterval(
                    epoch: epoch, startSample: 0, sampleCount: 0,
                    sampleRate: Double(profile.estimator.sampleRate)),
                includedSampleCount: 0)
        try validate(origin: result, profile: profile)
        guard result.source.epoch == epoch, result.source.startSample == 0 else {
            throw YINError.unexpectedContext
        }
        return result
    }

    private func frameTiming(source: SourceInterval, completed: UInt64?) throws -> AnalysisTiming {
        let offset = source.startSample - origin.source.startSample
        return try AnalysisTiming(
            source: source, includedSampleCount: source.sampleCount,
            sourceStartSeconds: origin.sourceStartSeconds.map {
                $0 + Double(offset) / source.sampleRate
            },
            hostStartNanoseconds: shiftedHost(by: offset), completedHostNanoseconds: completed,
            effectiveDelaySeconds: origin.effectiveDelaySeconds)
    }
    private func validateClock(endSample: Int64, completed: UInt64?) throws {
        let offset = endSample - origin.source.startSample
        if let start = origin.sourceStartSeconds {
            guard (start + Double(offset) / origin.source.sampleRate).isFinite else {
                throw ContractError.invalidTiming
            }
        }
        if let hostEnd = try shiftedHost(by: offset), let completed {
            guard completed >= hostEnd else { throw ContractError.invalidTiming }
        }
    }
    private func shiftedHost(by samples: Int64) throws -> UInt64? {
        guard let anchor = origin.hostStartNanoseconds else { return nil }
        guard samples >= 0 else { throw ContractError.invalidTiming }
        let rate = UInt64(profile.estimator.sampleRate)
        let count = UInt64(samples)
        let whole = (count / rate).multipliedReportingOverflow(by: 1_000_000_000)
        let fraction = ((count % rate) * 1_000_000_000 + rate / 2) / rate
        let delta = whole.partialValue.addingReportingOverflow(fraction)
        let result = anchor.addingReportingOverflow(delta.partialValue)
        guard !whole.overflow, !delta.overflow, !result.overflow else {
            throw ContractError.invalidTiming
        }
        return result.partialValue
    }
}
