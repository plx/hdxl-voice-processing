/// Cached raw sample storage. The ring retains at most one frame of input.
private final class FramerStorage<Sample: BinaryFloatingPoint & Sendable> {
    let window: PreparedWindow<Sample>
    let ring: UnsafeMutablePointer<Sample>
    let emission: UnsafeMutablePointer<Sample>
    let capacity: Int
    var cursor = 0

    init(_ specification: WindowSpecification) throws {
        window = try PreparedWindow(specification)
        capacity = specification.sampleCount
        ring = .allocate(capacity: capacity)
        emission = .allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
        emission.initialize(repeating: 0, count: capacity)
    }
    deinit {
        ring.deinitialize(count: capacity)
        emission.deinitialize(count: capacity)
        ring.deallocate()
        emission.deallocate()
    }
    func append(_ input: UnsafeBufferPointer<Sample>) {
        var offset = 0
        while offset < input.count {
            let count = min(input.count - offset, capacity - cursor)
            ring.advanced(by: cursor).update(
                from: input.baseAddress!.advanced(by: offset), count: count)
            cursor = (cursor + count) % capacity
            offset += count
        }
    }
    func borrowSuffix(count: Int) -> UnsafeBufferPointer<Sample> {
        let start = (cursor - count + capacity) % capacity
        let first = min(count, capacity - start)
        emission.update(from: ring.advanced(by: start), count: first)
        if first < count { emission.advanced(by: first).update(from: ring, count: count - first) }
        return UnsafeBufferPointer(start: emission, count: count)
    }
}

/// Single-owner synchronous worker primitive, deliberately not Sendable or a scalar PCMProcessor.
/// Input is finite mono analysis PCM, with channel selection/resampling already resolved upstream.
/// Prepare allocates two frame-sized buffers and cached coefficients. Process/reset reuse them.
/// The emitter borrows unwindowed samples only for its call; copy explicitly to retain them.
/// Window/de-mean/pre-emphasis ordering belongs to the consuming algorithm's declared profile.
/// Do not invoke from a real-time capture callback. Serialize all access externally.
public final class PCMFramer<Sample: BinaryFloatingPoint & Sendable> {
    public private(set) var configuration: FramingConfiguration
    public private(set) var identity: ProfileIdentity
    public private(set) var epoch: StreamEpoch
    public private(set) var nextInputSample: Int64
    public var preparedWindow: PreparedWindow<Sample>? { storage?.window }

    private enum State { case prepared, finished, cancelled }
    private var state = State.prepared
    private var storage: FramerStorage<Sample>?
    private let diagnostics: WorkerDiagnostics
    private var origin: Int64
    private var nextFrameStart: Int64?
    private var completeFrames: UInt64 = 0
    private var completion: FramingCompletion?
    private var busy = false

    public convenience init(
        configuration: FramingConfiguration, epoch: StreamEpoch, startSample: Int64 = 0
    ) throws {
        try self.init(
            configuration: configuration, epoch: epoch, startSample: startSample,
            diagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: FramingConfiguration, epoch: StreamEpoch, startSample: Int64 = 0,
        diagnostics: WorkerDiagnostics
    ) throws {
        _ = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: configuration.window.sampleRate)
        let first = try configuration.frameStartSample(ordinal: 0, epochStart: startSample)
        let identity = try configuration.identity()
        let prepared = try FramerStorage<Sample>(configuration.window)
        self.configuration = configuration
        self.identity = identity
        self.epoch = epoch
        self.nextInputSample = startSample
        self.origin = startSample
        self.nextFrameStart = first
        self.storage = prepared
        self.diagnostics = diagnostics
    }

    /// Reject the entire input before mutation for invalid samples or mismatched metadata.
    /// Cancellation from the emitter is supported; the report identifies the consumed prefix.
    @discardableResult
    public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (UnsafeBufferPointer<Sample>, PCMFrameSupport) -> Void
    ) throws -> FramingProcessReport {
        guard !busy else { throw FramingError.reentrantCall }
        guard state == .prepared, let storage else { throw FramingError.invalidState }
        guard interval.epoch == epoch, interval.startSample == nextInputSample,
            interval.sampleRate == configuration.window.sampleRate,
            interval.sampleCount == Int64(samples.count)
        else { throw FramingError.unexpectedInterval }
        for value in samples where !value.isFinite { throw FramingError.nonfiniteSample }
        busy = true
        defer { busy = false }
        var consumed = 0
        var emitted = 0
        while consumed < samples.count && state == .prepared {
            let end = nextFrameStart?.addingReportingOverflow(Int64(storage.capacity))
            let frameEnd = end.flatMap { $0.overflow ? nil : $0.partialValue }
            let count =
                frameEnd.map { Int(min(Int64(samples.count - consumed), $0 - nextInputSample)) }
                ?? (samples.count - consumed)
            storage.append(UnsafeBufferPointer(rebasing: samples[consumed..<(consumed + count)]))
            consumed += count
            nextInputSample += Int64(count)
            if let frameEnd, nextInputSample == frameEnd, let start = nextFrameStart {
                let support = try makeSupport(start: start, count: storage.capacity)
                let buffer = borrow(storage, count: storage.capacity, index: completeFrames)
                completeFrames += 1
                advanceGrid(from: start)
                emitted += 1
                // Explicit lifetime: optimized ARC must not release storage before emit cancels.
                withExtendedLifetime(storage) { emit(buffer, support) }
            }
        }
        return FramingProcessReport(
            consumedSampleCount: consumed, emittedFrameCount: emitted,
            isCancelled: state == .cancelled)
    }

    /// Emit at most one earliest incomplete grid frame, with actual support and insufficientData.
    /// Never pad the callback. Repeated finish returns the same report without another emission.
    @discardableResult
    public func finish(
        emit: (UnsafeBufferPointer<Sample>, PCMFrameSupport) -> Void
    ) throws -> FramingCompletion {
        guard !busy else { throw FramingError.reentrantCall }
        guard state != .cancelled, let storage else { throw FramingError.invalidState }
        if let completion { return completion }
        let observed = try SourceInterval(
            epoch: epoch, startSample: origin,
            sampleCount: nextInputSample - origin, sampleRate: configuration.window.sampleRate)
        var tail: PCMFrameSupport?
        if let start = nextFrameStart, start < nextInputSample {
            tail = try makeSupport(start: start, count: Int(nextInputSample - start))
        }
        let disposition: FramingEndDisposition
        if observed.sampleCount == 0 {
            disposition = .empty
        } else if tail != nil {
            disposition =
                configuration.partialWindowPolicy == .discard
                ? .discardedPartial : .unavailablePartial
        } else {
            disposition = completeFrames == 0 ? .noEligibleFrame : .complete
        }
        let result = FramingCompletion(
            observedSource: observed, completeFrameCount: completeFrames,
            tailSource: tail?.source, disposition: disposition)
        completion = result
        state = .finished
        if let tail, configuration.partialWindowPolicy == .emitUnavailable {
            busy = true
            defer { busy = false }
            withExtendedLifetime(storage) {
                emit(
                    borrow(storage, count: Int(tail.source.sampleCount), index: completeFrames),
                    tail)
            }
        }
        return result
    }

    /// Discard pending support; next input starts at zero in the new continuity epoch.
    /// A known missing interval must start at the next expected old-epoch input position.
    public func reset(for discontinuity: SourceDiscontinuity) throws {
        guard !busy else { throw FramingError.reentrantCall }
        guard discontinuity.previousEpoch == epoch else { throw FramingError.unexpectedInterval }
        if let missing = discontinuity.missingSource {
            guard missing.startSample == nextInputSample,
                missing.sampleRate == configuration.window.sampleRate
            else { throw FramingError.unexpectedInterval }
        }
        let prepared = try storage ?? FramerStorage<Sample>(configuration.window)
        storage = prepared
        restart(epoch: discontinuity.nextEpoch)
    }

    /// Transactional control operation. A different stream must begin at epoch zero.
    public func reconfigure(to configuration: FramingConfiguration, epoch: StreamEpoch) throws {
        guard !busy else { throw FramingError.reentrantCall }
        let reason: ResetReason =
            epoch.streamID == self.epoch.streamID ? .profileChange : .newSource
        _ = try SourceDiscontinuity(previousEpoch: self.epoch, nextEpoch: epoch, reason: reason)
        let identity = try configuration.identity()
        let prepared = try FramerStorage<Sample>(configuration.window)
        self.configuration = configuration
        self.identity = identity
        self.storage = prepared
        restart(epoch: epoch)
    }

    /// Idempotent. A current synchronous emission keeps its borrowed storage until it returns.
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
        nextFrameStart = Int64(configuration.firstFrameOffsetSamples)
        completeFrames = 0
        completion = nil
        storage?.cursor = 0
        state = .prepared
        diagnostics.reset()
    }
    private func makeSupport(start: Int64, count: Int) throws -> PCMFrameSupport {
        PCMFrameSupport(
            framingIdentity: identity, frameIndex: completeFrames,
            source: try SourceInterval(
                epoch: epoch, startSample: start, sampleCount: Int64(count),
                sampleRate: configuration.window.sampleRate),
            nominalSampleCount: configuration.window.sampleCount)
    }
    private func advanceGrid(from start: Int64) {
        let next = start.addingReportingOverflow(Int64(configuration.hopLength))
        nextFrameStart = next.overflow ? nil : next.partialValue
    }
    private func borrow(_ storage: FramerStorage<Sample>, count: Int, index: UInt64)
        -> UnsafeBufferPointer<Sample>
    {
        var metadata = DiagnosticMetadata()
        metadata.frameSequence = index
        metadata.sampleCount = UInt32(count)
        metadata.profileToken = 24
        metadata.validity = count == storage.capacity ? .available : .warmup
        return diagnostics.withFrame(metadata) {
            diagnostics.withInterval(.frameAssembly) { storage.borrowSuffix(count: count) }
        }
    }
}
