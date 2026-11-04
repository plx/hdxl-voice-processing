public struct LevelProcessReport: Sendable, Hashable {
    public let consumedSampleCount: Int
    public let emittedWindowCount: Int
    public let isCancelled: Bool
}

public enum LevelEndDisposition: String, Sendable, Hashable {
    case empty, complete, discardedPartial, unavailablePartial
}

public struct LevelCompletion: Sendable, Hashable {
    public let observedSource: SourceInterval
    public let completeWindowCount: UInt64
    /// May overlap preceding complete windows; never add it to obtain unique coverage.
    public let tailSource: SourceInterval?
    public let disposition: LevelEndDisposition
    public let isCancelled: Bool
}

public struct LevelExecutionStatistics: Sendable, Hashable {
    public let preparedBufferBytes: Int
    public let unweightedRebaseCount: UInt64
    public let weightedRebaseCount: UInt64
    public let unweightedFallbackWindowCount: UInt64
    public let weightedFallbackWindowCount: UInt64
}

/// Synchronous single-owner analysis worker. Deliberately not Sendable; serialize access.
/// Input is original finite mono PCM. Do not call from the real-time capture callback.
/// Setup owns bounded buffers; process, finish, and ordinary reset reuse them. Results own no PCM.
public final class PreparedLevelAnalyzer<Sample: BinaryFloatingPoint & Sendable> {
    public private(set) var configuration: LevelConfiguration
    public private(set) var identity: ProfileIdentity
    public private(set) var epoch: StreamEpoch
    public private(set) var nextInputSample: Int64
    public var executionStatistics: LevelExecutionStatistics {
        LevelExecutionStatistics(
            preparedBufferBytes: storage?.bufferBytes ?? 0,
            unweightedRebaseCount: storage?.unweighted.rebaseCount ?? 0,
            weightedRebaseCount: storage?.weighted?.rebaseCount ?? 0,
            unweightedFallbackWindowCount: storage?.unweighted.fallbackWindows ?? 0,
            weightedFallbackWindowCount: storage?.weighted?.fallbackWindows ?? 0)
    }

    private enum State { case prepared, finished, cancelled, failed }
    private var state = State.prepared
    private var storage: LevelAnalyzerStorage?
    private let diagnostics: WorkerDiagnostics
    private var origin: Int64
    private var nextFrameStart: Int64?
    private var completeWindows: UInt64 = 0
    private var completion: LevelCompletion?
    private var busy = false

    public convenience init(
        configuration: LevelConfiguration, epoch: StreamEpoch, startSample: Int64 = 0
    ) throws {
        try self.init(
            configuration: configuration, epoch: epoch, startSample: startSample,
            diagnostics: WorkerDiagnostics())
    }
    package init(
        configuration: LevelConfiguration, epoch: StreamEpoch, startSample: Int64 = 0,
        diagnostics: WorkerDiagnostics
    ) throws {
        try Self.validatePrecision(configuration)
        _ = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: Double(configuration.sampleRate))
        let identity = try configuration.identity()
        self.configuration = configuration
        self.identity = identity
        self.epoch = epoch
        self.nextInputSample = startSample
        self.origin = startSample
        self.nextFrameStart = startSample
        self.storage = LevelAnalyzerStorage(configuration)
        self.diagnostics = diagnostics
    }
    private static func validatePrecision(_ configuration: LevelConfiguration) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw LevelError.precisionMismatch }
    }

    /// Reject invalid metadata/nonfinite input before consuming any part of the chunk.
    /// A numeric filter overflow fails the worker until reset; prior emitted windows stay valid.
    @discardableResult
    public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (LevelWindowResult) -> Void
    ) throws -> LevelProcessReport {
        guard !busy else { throw LevelError.reentrantCall }
        guard state == .prepared, let storage else { throw LevelError.invalidState }
        guard interval.epoch == epoch, interval.startSample == nextInputSample,
            interval.sampleRate == Double(configuration.sampleRate),
            interval.sampleCount == Int64(samples.count)
        else { throw LevelError.unexpectedInterval }
        for sample in samples where !sample.isFinite {
            throw LevelError.nonfiniteInput(try LevelInputDiagnostics.inspect(samples))
        }
        busy = true
        defer { busy = false }
        var consumed = 0
        var emitted = 0
        do {
            while consumed < samples.count && state == .prepared {
                let sum = nextFrameStart?.addingReportingOverflow(Int64(configuration.windowLength))
                let frameEnd = sum.flatMap { $0.overflow ? nil : $0.partialValue }
                let count =
                    frameEnd.map { Int(min(Int64(samples.count - consumed), $0 - nextInputSample)) }
                    ?? (samples.count - consumed)
                for i in 0..<count { storage.pending.append(Double(samples[consumed + i])) }
                storage.pendingCount += count
                consumed += count
                nextInputSample += Int64(count)
                if let frameEnd, nextInputSample == frameEnd, let start = nextFrameStart {
                    let result = try makeWindow(
                        storage, start: start, count: configuration.windowLength)
                    completeWindows += 1
                    let next = start.addingReportingOverflow(Int64(configuration.hopLength))
                    nextFrameStart = next.overflow ? nil : next.partialValue
                    emitted += 1
                    withExtendedLifetime(storage) { emit(result) }
                }
            }
        } catch {
            state = .failed
            diagnostics.event(.error, validity: .failed)
            throw error
        }
        return LevelProcessReport(
            consumedSampleCount: consumed, emittedWindowCount: emitted,
            isCancelled: state == .cancelled)
    }

    /// No invented padding. At most the earliest incomplete grid window is emitted unavailable.
    @discardableResult
    public func finish(emit: (LevelWindowResult) -> Void) throws -> LevelCompletion {
        guard !busy else { throw LevelError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw LevelError.invalidState
        }
        if let completion { return completion }
        busy = true
        defer { busy = false }
        let observed = try SourceInterval(
            epoch: epoch, startSample: origin,
            sampleCount: nextInputSample - origin,
            sampleRate: Double(configuration.sampleRate))
        let tail: SourceInterval?
        if let start = nextFrameStart, start < nextInputSample {
            tail = try SourceInterval(
                epoch: epoch, startSample: start, sampleCount: nextInputSample - start,
                sampleRate: Double(configuration.sampleRate))
        } else {
            tail = nil
        }
        let disposition: LevelEndDisposition
        if observed.sampleCount == 0 {
            disposition = .empty
        } else if tail != nil {
            disposition =
                configuration.partialWindowPolicy == .discard
                ? .discardedPartial : .unavailablePartial
        } else {
            disposition = .complete
        }
        do {
            let result = try tail.flatMap { source in
                configuration.partialWindowPolicy == .emitUnavailable
                    ? try makeWindow(
                        storage, start: source.startSample, count: Int(source.sampleCount)) : nil
            }
            state = .finished
            if let result { withExtendedLifetime(storage) { emit(result) } }
            let report = LevelCompletion(
                observedSource: observed, completeWindowCount: completeWindows,
                tailSource: tail, disposition: disposition, isCancelled: state == .cancelled)
            if state == .finished { completion = report }
            return report
        } catch {
            state = .failed
            diagnostics.event(.error, validity: .failed)
            throw error
        }
    }

    private func makeWindow(_ storage: LevelAnalyzerStorage, start: Int64, count: Int) throws
        -> LevelWindowResult
    {
        let complete = count == configuration.windowLength
        let warming = start - origin < Int64(configuration.weighting.warmupSampleCount)
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 32
        metadata.frameSequence = completeWindows
        metadata.sampleCount = UInt32(count)
        metadata.validity = complete && !warming ? .available : .warmup
        return try diagnostics.withFrame(metadata) {
            diagnostics.withInterval(.levelEnergy) {
                for i in 0..<storage.pendingCount {
                    storage.unweighted.append(
                        storage.pending.suffixValue(i, count: storage.pendingCount))
                }
            }
            if var filter = storage.filter, let weighted = storage.weighted {
                try diagnostics.withInterval(.kWeighting) {
                    for i in 0..<storage.pendingCount {
                        weighted.append(
                            try filter.process(
                                storage.pending.suffixValue(i, count: storage.pendingCount)))
                    }
                }
                storage.filter = filter
            }
            storage.pendingCount = 0
            return try diagnostics.withInterval(.levelEnergy) {
                let source = try SourceInterval(
                    epoch: epoch, startSample: start, sampleCount: Int64(count),
                    sampleRate: Double(configuration.sampleRate))
                let input = try storage.unweighted.diagnostics(count: count)
                let unweighted: LevelEnergyOutcome =
                    complete
                    ? .available(try storage.unweighted.energy()) : .unavailable(.insufficientData)
                let limited = storage.filter?.precisionLimited ?? false
                let weighted: LevelEnergyOutcome?
                if let accumulator = storage.weighted {
                    if !complete || warming {
                        weighted = .unavailable(.insufficientData)
                    } else if limited {
                        weighted = .unavailable(.unsupportedRange)
                    } else {
                        weighted = .available(try accumulator.energy())
                    }
                } else {
                    weighted = nil
                }
                return try LevelWindowResult(
                    configuration: configuration, profile: identity, epochOriginSample: origin,
                    frameIndex: completeWindows, source: source, input: input,
                    unweighted: unweighted, weighted: weighted, weightedPrecisionLimited: limited)
            }
        }
    }

    public func reset(for discontinuity: SourceDiscontinuity) throws {
        guard !busy else { throw LevelError.reentrantCall }
        guard discontinuity.previousEpoch == epoch else { throw LevelError.unexpectedInterval }
        if let missing = discontinuity.missingSource {
            guard missing.startSample == nextInputSample,
                missing.sampleRate == Double(configuration.sampleRate)
            else { throw LevelError.unexpectedInterval }
        }
        let prepared = storage ?? LevelAnalyzerStorage(configuration)
        prepared.reset()
        storage = prepared
        restart(epoch: discontinuity.nextEpoch)
    }
    public func reconfigure(to configuration: LevelConfiguration, epoch: StreamEpoch) throws {
        guard !busy else { throw LevelError.reentrantCall }
        try Self.validatePrecision(configuration)
        let reason: ResetReason =
            epoch.streamID == self.epoch.streamID ? .profileChange : .newSource
        _ = try SourceDiscontinuity(previousEpoch: self.epoch, nextEpoch: epoch, reason: reason)
        let identity = try configuration.identity()
        let prepared = LevelAnalyzerStorage(configuration)
        self.configuration = configuration
        self.identity = identity
        self.storage = prepared
        restart(epoch: epoch)
    }
    public func cancel() {
        if state != .cancelled { diagnostics.event(.cancelled, validity: .cancelled) }
        state = .cancelled
        storage = nil
        completion = nil
    }
    private func restart(epoch: StreamEpoch) {
        self.epoch = epoch
        origin = 0
        nextInputSample = 0
        nextFrameStart = 0
        completeWindows = 0
        completion = nil
        state = .prepared
        diagnostics.reset()
    }
}
