import Foundation

/// Exact decomposition of the requested binary64 hop in source samples. Integer
/// carry preserves fractional hops indefinitely without a growing floating clock.
public struct HNRCausalHop: Sendable, Hashable {
    public let wholeSamples: Int
    public let fractionNumerator: UInt64
    public let fractionDenominator: UInt64

    public init(configuration: HNRConfiguration) throws {
        guard configuration.normalization == .causalWindow else {
            throw HNRError.invalidConfiguration
        }
        // The public minimum is one sample. Canonicalize a sub-ulp product below
        // one rather than introducing a zero-sample advance at that boundary.
        let step = max(1, configuration.hopSeconds * Double(configuration.sampleRate))
        let bits = max(0, 52 - step.exponent)
        var denominator = UInt64(1) << bits
        var numerator = step.significandBitPattern & (denominator - 1)
        if numerator == 0 {
            denominator = 1
        } else {
            while numerator % 2 == 0 {
                numerator /= 2
                denominator /= 2
            }
        }
        wholeSamples = Int(step)
        fractionNumerator = numerator
        fractionDenominator = denominator
    }

    package func advance(phase: inout UInt64) -> Int {
        // Both operands are below a denominator of at most 2^52.
        phase += fractionNumerator
        let carry = phase >= fractionDenominator
        if carry { phase -= fractionDenominator }
        return wholeSamples + (carry ? 1 : 0)
    }
}

public struct BorrowedHNRStreamingOutput {
    public let frame: BorrowedHNRAnalysisOutput
    public let origin: AnalysisTiming
    /// Subtract source indices before conversion; large absolute source positions
    /// do not erase this stream-relative placement.
    public let centerSecondsFromStreamOrigin: Double
}

public struct HNRStreamingCompletion: Sendable, Hashable {
    public let framing: FramingCompletion
    public let availableFrameCount: UInt64
    public let unavailableFrameCount: UInt64
    public let isCancelled: Bool
}

private final class HNRStreamingStorage<Sample: BinaryFloatingPoint & Sendable> {
    let worker: PreparedHNR<Sample>
    let ring: UnsafeMutableBufferPointer<Sample>
    let emission: UnsafeMutableBufferPointer<Sample>
    var head = 0
    var count = 0

    init(configuration: HNRConfiguration, diagnostics: WorkerDiagnostics) throws {
        worker = try PreparedHNR(configuration, diagnostics: diagnostics)
        let capacity = configuration.causalWindowSampleCount
        ring = .allocate(capacity: capacity)
        emission = .allocate(capacity: capacity)
        ring.initialize(repeating: 0)
        emission.initialize(repeating: 0)
    }
    deinit {
        ring.deinitialize()
        ring.deallocate()
        emission.deinitialize()
        emission.deallocate()
    }
    func append(_ input: UnsafeBufferPointer<Sample>) {
        for i in input.indices { ring[(head + count + i) % ring.count] = input[i] }
        count += input.count
    }
    func borrow() -> UnsafeBufferPointer<Sample> {
        for i in 0..<count { emission[i] = ring[(head + i) % ring.count] }
        return UnsafeBufferPointer(start: emission.baseAddress, count: count)
    }
    func advance(by step: Int) {
        let removed = min(step, count)
        head = (head + removed) % ring.count
        count -= removed
    }
    func reset() {
        head = 0
        count = 0
    }
}

/// Single-owner synchronous causal worker. Input chunks change delivery, never
/// the exact fractional-hop grid or acquired normalization window. Prepare and
/// run on a worker, not inside a real-time audio capture callback.
public final class PreparedHNRStream<Sample: BinaryFloatingPoint & Sendable> {
    public private(set) var configuration: HNRConfiguration
    public private(set) var identity: ProfileIdentity
    public private(set) var origin: AnalysisTiming
    public private(set) var hop: HNRCausalHop
    public private(set) var nextInputSample: Int64
    public var epoch: StreamEpoch { origin.source.epoch }
    public var estimatorStatistics: HNRExecutionStatistics? { storage?.worker.executionStatistics }
    public var preparedBufferBytes: Int {
        guard let storage else { return 0 }
        return storage.worker.executionStatistics.preparedBufferBytes
            + 2 * storage.ring.count * MemoryLayout<Sample>.stride
    }

    private enum State { case prepared, finished, cancelled, failed }
    private var state = State.prepared
    private var storage: HNRStreamingStorage<Sample>?
    private var nextFrameStart: Int64?
    private var phase: UInt64 = 0
    private var completeFrames: UInt64 = 0
    private var availableFrames: UInt64 = 0
    private var unavailableFrames: UInt64 = 0
    private var busy = false
    private var completion: HNRStreamingCompletion?
    private let diagnostics: WorkerDiagnostics

    public convenience init(
        configuration: HNRConfiguration, epoch: StreamEpoch, startSample: Int64 = 0
    ) throws {
        let source = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: Double(configuration.sampleRate))
        try self.init(
            configuration: configuration,
            origin: AnalysisTiming(source: source, includedSampleCount: 0))
    }
    public convenience init(configuration: HNRConfiguration, origin: AnalysisTiming) throws {
        try self.init(
            configuration: configuration, origin: origin, diagnostics: WorkerDiagnostics())
    }
    package init(
        configuration: HNRConfiguration, origin: AnalysisTiming, diagnostics: WorkerDiagnostics
    ) throws {
        try Self.validate(configuration: configuration, origin: origin)
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.hop = try HNRCausalHop(configuration: configuration)
        self.origin = origin
        self.nextInputSample = origin.source.startSample
        self.nextFrameStart = origin.source.startSample
        self.storage = try HNRStreamingStorage(
            configuration: configuration, diagnostics: diagnostics)
        self.diagnostics = diagnostics
    }

    /// Validate the whole chunk and optional completion clock before consumption.
    /// Cancellation from emit returns the precise consumed prefix; the current
    /// borrowed view remains alive until emit returns.
    @discardableResult public func process(
        _ input: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        completedHostNanoseconds: UInt64? = nil, emit: (BorrowedHNRStreamingOutput) -> Void
    ) throws -> FramingProcessReport {
        guard !busy else { throw HNRError.reentrantCall }
        guard state == .prepared, let storage else { throw HNRError.invalidState }
        guard interval.epoch == epoch, interval.sampleRate == Double(configuration.sampleRate),
            interval.startSample == nextInputSample, interval.sampleCount == Int64(input.count)
        else { throw HNRError.unexpectedContext }
        for value in input where !value.isFinite { throw HNRError.invalidInput }
        try validateClock(endSample: interval.endSample, completed: completedHostNanoseconds)
        busy = true
        defer { busy = false }
        var consumed = 0
        var emitted = 0
        do {
            try withExtendedLifetime(storage) {
                while consumed < input.count && state == .prepared {
                    guard let start = nextFrameStart else {
                        nextInputSample = interval.endSample
                        consumed = input.count
                        break
                    }
                    if nextInputSample < start {
                        let skipped = Int(
                            min(start - nextInputSample, Int64(input.count - consumed)))
                        nextInputSample += Int64(skipped)
                        consumed += skipped
                        continue
                    }
                    let count = min(storage.ring.count - storage.count, input.count - consumed)
                    storage.append(
                        UnsafeBufferPointer(rebasing: input[consumed..<consumed + count]))
                    consumed += count
                    nextInputSample += Int64(count)
                    if storage.count == storage.ring.count {
                        guard completeFrames <= UInt64(Int.max) else {
                            throw HNRError.capacityExceeded
                        }
                        let source = try SourceInterval(
                            epoch: epoch, startSample: start,
                            sampleCount: Int64(storage.count),
                            sampleRate: Double(configuration.sampleRate))
                        let timing = try frameTiming(
                            source: source, completed: completedHostNanoseconds)
                        let frame = try configuration.causalFrameLayout(
                            frameIndex: Int(completeFrames))
                        let samples = storage.borrow()
                        let reference = try HNRNormalization.prepared(
                            samples, timing: timing, definition: .causalWindow,
                            frameSequence: completeFrames, diagnostics: diagnostics)
                        let placement =
                            Double(start - origin.source.startSample) / source.sampleRate
                            + frame.centerSecondsFromOrigin
                        try storage.worker.analyze(
                            UnsafeBufferPointer(rebasing: samples[frame.support]),
                            layout: frame, normalization: reference
                        ) { output in
                            completeFrames += 1
                            if output.result.selectedObservation == nil {
                                unavailableFrames += 1
                            } else {
                                availableFrames += 1
                            }
                            emitted += 1
                            emit(
                                BorrowedHNRStreamingOutput(
                                    frame: .frame(output), origin: origin,
                                    centerSecondsFromStreamOrigin: placement))
                        }
                        if state == .cancelled { break }
                        let step = hop.advance(phase: &phase)
                        let next = start.addingReportingOverflow(Int64(step))
                        nextFrameStart = next.overflow ? nil : next.partialValue
                        storage.advance(by: step)
                    }
                }
            }
        } catch {
            if state != .cancelled { state = .failed }
            diagnostics.event(.error, validity: .failed)
            throw error
        }
        return FramingProcessReport(
            consumedSampleCount: consumed, emittedFrameCount: emitted,
            isCancelled: state == .cancelled)
    }

    /// Emit at most the earliest nonempty incomplete window as unavailable, with
    /// actual acquired support. Never pad PCM. Repeated ordinary finish is idempotent.
    @discardableResult public func finish(
        completedHostNanoseconds: UInt64? = nil, emit: (BorrowedHNRStreamingOutput) -> Void
    ) throws -> HNRStreamingCompletion {
        guard !busy else { throw HNRError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw HNRError.invalidState
        }
        if let completion { return completion }
        try validateClock(endSample: nextInputSample, completed: completedHostNanoseconds)
        let observed = try SourceInterval(
            epoch: epoch, startSample: origin.source.startSample,
            sampleCount: nextInputSample - origin.source.startSample,
            sampleRate: Double(configuration.sampleRate))
        let tail: SourceInterval?
        if let start = nextFrameStart, storage.count > 0 {
            tail = try SourceInterval(
                epoch: epoch, startSample: start, sampleCount: Int64(storage.count),
                sampleRate: Double(configuration.sampleRate))
        } else {
            tail = nil
        }
        let disposition: FramingEndDisposition =
            observed.sampleCount == 0
            ? .empty
            : (tail == nil
                ? (completeFrames == 0 ? .noEligibleFrame : .complete) : .unavailablePartial)
        busy = true
        defer { busy = false }
        if let tail {
            let timing = try frameTiming(source: tail, completed: completedHostNanoseconds)
            unavailableFrames += 1
            withExtendedLifetime(storage) {
                emit(
                    BorrowedHNRStreamingOutput(
                        frame: .unavailable(
                            HNRUnavailableFrame(
                                profile: identity, frameIndex: completeFrames,
                                timing: timing, centerSourceSeconds: timing.displayTimeSeconds,
                                reason: .insufficientData)),
                        origin: origin,
                        centerSecondsFromStreamOrigin:
                            Double(tail.startSample - origin.source.startSample) / tail.sampleRate
                            + tail.durationSeconds / 2))
            }
        }
        let result = HNRStreamingCompletion(
            framing: FramingCompletion(
                observedSource: observed,
                completeFrameCount: completeFrames, tailSource: tail, disposition: disposition),
            availableFrameCount: availableFrames, unavailableFrameCount: unavailableFrames,
            isCancelled: state == .cancelled)
        if state != .cancelled {
            completion = result
            state = .finished
        }
        return result
    }

    public func reset(for discontinuity: SourceDiscontinuity, clockOrigin: AnalysisTiming? = nil)
        throws
    {
        guard !busy else { throw HNRError.reentrantCall }
        guard discontinuity.previousEpoch == epoch else { throw HNRError.unexpectedContext }
        if let missing = discontinuity.missingSource {
            guard missing.startSample == nextInputSample,
                missing.sampleRate == Double(configuration.sampleRate)
            else { throw HNRError.unexpectedContext }
        }
        let nextOrigin = try Self.newOrigin(
            configuration: configuration, epoch: discontinuity.nextEpoch, supplied: clockOrigin)
        let prepared =
            try storage
            ?? HNRStreamingStorage(configuration: configuration, diagnostics: diagnostics)
        prepared.reset()
        storage = prepared
        restart(origin: nextOrigin)
        diagnostics.reset()
    }

    /// Prepare a replacement transactionally; an invalid profile leaves old state intact.
    public func reconfigure(
        to configuration: HNRConfiguration, epoch: StreamEpoch,
        clockOrigin: AnalysisTiming? = nil
    ) throws {
        guard !busy else { throw HNRError.reentrantCall }
        _ = try SourceDiscontinuity(
            previousEpoch: self.epoch, nextEpoch: epoch,
            reason: self.epoch.streamID == epoch.streamID ? .profileChange : .newSource)
        let nextOrigin = try Self.newOrigin(
            configuration: configuration, epoch: epoch, supplied: clockOrigin)
        let nextIdentity = try configuration.identity()
        let nextHop = try HNRCausalHop(configuration: configuration)
        let prepared = try HNRStreamingStorage<Sample>(
            configuration: configuration, diagnostics: diagnostics)
        self.configuration = configuration
        identity = nextIdentity
        hop = nextHop
        storage = prepared
        restart(origin: nextOrigin)
        diagnostics.reset()
        diagnostics.event(.configurationChange)
    }

    /// Release ownership immediately; a local lifetime guard keeps a current emit
    /// alive until return. Reset/reconfiguration can prepare storage again afterward.
    public func cancel() {
        guard state != .cancelled else { return }
        storage = nil
        completion = nil
        state = .cancelled
        diagnostics.event(.cancelled, validity: .cancelled)
    }

    private func restart(origin: AnalysisTiming) {
        self.origin = origin
        nextInputSample = origin.source.startSample
        nextFrameStart = origin.source.startSample
        phase = 0
        completeFrames = 0
        availableFrames = 0
        unavailableFrames = 0
        completion = nil
        state = .prepared
    }
    private static func validate(configuration: HNRConfiguration, origin: AnalysisTiming) throws {
        guard configuration.normalization == .causalWindow else {
            throw HNRError.invalidConfiguration
        }
        guard origin.source.sampleRate == Double(configuration.sampleRate),
            origin.source.sampleCount == 0,
            origin.includedSampleCount == 0, origin.completedHostNanoseconds == nil
        else { throw HNRError.unexpectedContext }
    }
    private static func newOrigin(
        configuration: HNRConfiguration, epoch: StreamEpoch,
        supplied: AnalysisTiming?
    ) throws -> AnalysisTiming {
        let result =
            try supplied
            ?? AnalysisTiming(
                source: SourceInterval(
                    epoch: epoch, startSample: 0,
                    sampleCount: 0, sampleRate: Double(configuration.sampleRate)),
                includedSampleCount: 0)
        try validate(configuration: configuration, origin: result)
        guard result.source.epoch == epoch, result.source.startSample == 0 else {
            throw HNRError.unexpectedContext
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
            effectiveDelaySeconds: max(
                origin.effectiveDelaySeconds,
                Double(configuration.causalWindowSampleCount) / source.sampleRate / 2))
    }
    private func validateClock(endSample: Int64, completed: UInt64?) throws {
        let offset = endSample - origin.source.startSample
        if let seconds = origin.sourceStartSeconds {
            guard (seconds + Double(offset) / origin.source.sampleRate).isFinite else {
                throw ContractError.invalidTiming
            }
        }
        if let end = try shiftedHost(by: offset), let completed {
            guard completed >= end else { throw ContractError.invalidTiming }
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
        // Match the shared acquisition-clock projection, without converting a
        // growing absolute sample index to floating point: nearest, ties to even.
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
