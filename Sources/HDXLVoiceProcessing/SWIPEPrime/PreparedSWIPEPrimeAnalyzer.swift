private final class SWIPEPrimeStreamStorage<Sample: BinaryFloatingPoint & Sendable> {
    let framer: PCMFramer<Sample>
    let estimator: PreparedSWIPEPrime<Sample>

    init(
        configuration: SWIPEPrimeConfiguration, origin: AnalysisTiming,
        diagnostics: WorkerDiagnostics
    ) throws {
        estimator = try PreparedSWIPEPrime(configuration, diagnostics: diagnostics)
        framer = try PCMFramer(
            configuration: configuration.framingConfiguration(),
            epoch: origin.source.epoch, startSample: origin.source.startSample,
            diagnostics: diagnostics)
    }
}

/// Synchronous single-owner mono PCM worker. Chunking changes delivery, never the
/// integer frame grid or numerical estimates. Prepare/reconfigure on a worker;
/// do not call from a real-time capture callback. Ordinary resets reuse storage.
public final class PreparedSWIPEPrimeAnalyzer<Sample: BinaryFloatingPoint & Sendable> {
    public private(set) var configuration: SWIPEPrimeConfiguration
    public private(set) var identity: ProfileIdentity
    /// Zero-length stream origin; its optional source/host clock anchors are rebased
    /// onto each output. effectiveDelaySeconds is an inherited minimum total delay.
    public private(set) var origin: AnalysisTiming
    public var epoch: StreamEpoch { origin.source.epoch }
    public private(set) var nextInputSample: Int64
    public var estimatorStatistics: SWIPEPrimeExecutionStatistics? {
        storage?.estimator.executionStatistics
    }
    /// Framer ring/emission/window coefficients plus estimator buffers. Excludes
    /// object bookkeeping and opaque vDSP setup tables.
    /// Cancellation releases storage after the current synchronous borrow returns.
    public var preparedBufferBytes: Int {
        guard let storage else { return 0 }
        return storage.estimator.executionStatistics.preparedBufferBytes
            + storage.framer.preparedBufferBytes
    }

    private enum State { case prepared, finished, cancelled, failed }
    private var state = State.prepared
    private var storage: SWIPEPrimeStreamStorage<Sample>?
    private var busy = false
    private var callbackError: (any Error)?
    private var completion: SWIPEPrimeCompletion?
    private let diagnostics: WorkerDiagnostics

    public convenience init(
        configuration: SWIPEPrimeConfiguration, epoch: StreamEpoch, startSample: Int64 = 0
    ) throws {
        let source = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: Double(configuration.sampleRate))
        try self.init(
            configuration: configuration,
            origin: AnalysisTiming(source: source, includedSampleCount: 0))
    }
    /// An origin has no samples or completion time. Supply actual source/host start
    /// anchors when known; absent clocks remain absent rather than being fabricated.
    public convenience init(configuration: SWIPEPrimeConfiguration, origin: AnalysisTiming) throws {
        try self.init(
            configuration: configuration, origin: origin, diagnostics: WorkerDiagnostics())
    }
    package init(
        configuration: SWIPEPrimeConfiguration, origin: AnalysisTiming,
        diagnostics: WorkerDiagnostics
    ) throws {
        try Self.validate(origin: origin, configuration: configuration)
        let identity = try configuration.identity()
        let storage = try SWIPEPrimeStreamStorage<Sample>(
            configuration: configuration, origin: origin, diagnostics: diagnostics)
        self.configuration = configuration
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
        emit: (BorrowedSWIPEPrimeOutput) -> Void
    ) throws -> FramingProcessReport {
        guard !busy else { throw SWIPEPrimeError.reentrantCall }
        guard state == .prepared, let storage else { throw SWIPEPrimeError.invalidState }
        guard interval.epoch == epoch, interval.startSample == nextInputSample,
            interval.sampleRate == Double(configuration.sampleRate),
            interval.sampleCount == Int64(samples.count)
        else { throw SWIPEPrimeError.unexpectedContext }
        for sample in samples where !sample.isFinite { throw SWIPEPrimeError.invalidInput }
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
    /// actual support, unless the configuration discards it. Repeated finish is idempotent.
    @discardableResult public func finish(
        completedHostNanoseconds: UInt64? = nil,
        emit: (BorrowedSWIPEPrimeOutput) -> Void
    ) throws -> SWIPEPrimeCompletion {
        guard !busy else { throw SWIPEPrimeError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw SWIPEPrimeError.invalidState
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
            let result = SWIPEPrimeCompletion(framing: framing, isCancelled: state == .cancelled)
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
        storage: SWIPEPrimeStreamStorage<Sample>, emit: (BorrowedSWIPEPrimeOutput) -> Void
    ) {
        guard callbackError == nil, state != .cancelled else { return }
        nextInputSample = storage.framer.nextInputSample
        do {
            let timing = try frameTiming(source: support.source, completed: completed)
            try storage.estimator.analyze(
                samples, timing: timing, frameIndex: support.frameIndex, emit: emit)
        } catch { callbackError = error }
        if callbackError != nil { storage.framer.cancel() }
    }

    /// Discard pending PCM. New epoch indices start at zero.
    /// Supply a new optional clock origin; the old epoch's clock is never guessed.
    public func reset(for discontinuity: SourceDiscontinuity, clockOrigin: AnalysisTiming? = nil)
        throws
    {
        guard !busy else { throw SWIPEPrimeError.reentrantCall }
        guard discontinuity.previousEpoch == epoch else { throw SWIPEPrimeError.unexpectedContext }
        if let missing = discontinuity.missingSource {
            guard missing.startSample == nextInputSample,
                missing.sampleRate == Double(configuration.sampleRate)
            else { throw SWIPEPrimeError.unexpectedContext }
        }
        let newOrigin = try Self.newOrigin(
            configuration: configuration, epoch: discontinuity.nextEpoch, supplied: clockOrigin)
        if let storage {
            try storage.framer.reset(for: discontinuity)
        } else {
            let prepared = try SWIPEPrimeStreamStorage<Sample>(
                configuration: configuration, origin: newOrigin, diagnostics: diagnostics)
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
        to configuration: SWIPEPrimeConfiguration, epoch: StreamEpoch,
        clockOrigin: AnalysisTiming? = nil
    ) throws {
        guard !busy else { throw SWIPEPrimeError.reentrantCall }
        _ = try SourceDiscontinuity(
            previousEpoch: self.epoch, nextEpoch: epoch,
            reason: self.epoch.streamID == epoch.streamID ? .profileChange : .newSource)
        let newOrigin = try Self.newOrigin(
            configuration: configuration, epoch: epoch, supplied: clockOrigin)
        let identity = try configuration.identity()
        let prepared = try SWIPEPrimeStreamStorage<Sample>(
            configuration: configuration, origin: newOrigin, diagnostics: diagnostics)
        self.configuration = configuration
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

    private static func validate(origin: AnalysisTiming, configuration: SWIPEPrimeConfiguration)
        throws
    {
        guard origin.source.sampleRate == Double(configuration.sampleRate),
            origin.source.sampleCount == 0, origin.includedSampleCount == 0,
            origin.completedHostNanoseconds == nil
        else { throw SWIPEPrimeError.unexpectedContext }
    }
    private static func newOrigin(
        configuration: SWIPEPrimeConfiguration, epoch: StreamEpoch, supplied: AnalysisTiming?
    ) throws -> AnalysisTiming {
        let result =
            try supplied
            ?? AnalysisTiming(
                source: SourceInterval(
                    epoch: epoch, startSample: 0, sampleCount: 0,
                    sampleRate: Double(configuration.sampleRate)),
                includedSampleCount: 0)
        try validate(origin: result, configuration: configuration)
        guard result.source.epoch == epoch, result.source.startSample == 0 else {
            throw SWIPEPrimeError.unexpectedContext
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
        let rate = UInt64(configuration.sampleRate)
        let count = UInt64(samples)
        let whole = (count / rate).multipliedReportingOverflow(by: 1_000_000_000)
        let numerator = (count % rate) * 1_000_000_000
        var fraction = numerator / rate
        let twiceRemainder = (numerator % rate) * 2
        // Match the shared acquisition clock exactly, including half-nanosecond
        // ties, without converting a growing absolute sample index to Double.
        if twiceRemainder > rate || (twiceRemainder == rate && fraction % 2 == 1) {
            fraction += 1
        }
        let delta = whole.partialValue.addingReportingOverflow(fraction)
        let result = anchor.addingReportingOverflow(delta.partialValue)
        guard !whole.overflow, !delta.overflow, !result.overflow else {
            throw ContractError.invalidTiming
        }
        return result.partialValue
    }
}
