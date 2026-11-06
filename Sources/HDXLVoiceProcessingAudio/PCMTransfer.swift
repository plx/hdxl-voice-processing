import HDXLVoiceProcessing
import Synchronization

/// A preallocated single-producer/single-consumer PCM handoff.
///
/// Prepare and finally release on a control/worker thread. The producer copies borrowed
/// input synchronously; a serial worker calls `withNext`. Neither side waits for the
/// other. Overflow drops the entire newest chunk. No capture callback invokes worker,
/// UI, actor, logging, or allocation APIs. See Architecture/0003-pcm-transfer.md.
///
/// Synchronization audit for this narrowly scoped unchecked conformance:
/// - immutable configuration and allocation addresses never change;
/// - producer state is exclusive under `producerControl`'s active bit;
/// - consumer state is exclusive under `consumerActive`;
/// - release/acquire cursors transfer ownership of each slot's bytes and metadata;
/// - final producer state is read only after acquiring closed-and-inactive control;
/// - storage lives until the final strong reference, after all borrowed calls return.
public final class PCMTransfer: @unchecked Sendable {
    public let configuration: PCMTransferConfiguration
    // Cache only trivial fixed-layout values used by capture. Core/SDK public
    // types can have resilient layouts and trigger metadata/value-witness calls.
    private let limits: Limits
    private struct Limits {
        let token: PCMTransferEpochToken
        let maximumFrames: UInt32
        let channels: Int
        let slotCount: Int
        let bytesPerSample: Int
        let bytesPerSlot: Int
        let interleaved: Bool
    }

    // A single word prevents shutdown from observing stale "inactive" independently
    // of closure. Admission is one compare-exchange, never a spin/retry loop.
    private static let active: UInt32 = 1
    private static let closed: UInt32 = 2
    private static let violation: UInt32 = 4
    private let producerControl = Atomic<UInt32>(0)
    private let consumerActive = Atomic<Bool>(false)
    private let published = Atomic<UInt64>(0)
    private let released = Atomic<UInt64>(0)
    private let callbacks = Atomic<UInt64>(0)
    private let accepted = Atomic<UInt64>(0)
    private let overflows = Atomic<UInt64>(0)
    private let oversized = Atomic<UInt64>(0)
    private let invalid = Atomic<UInt64>(0)
    private let dropped = Atomic<UInt64>(0)
    private let discarded = Atomic<UInt64>(0)
    private let highWater = Atomic<UInt64>(0)

    private let storage: UnsafeMutableRawPointer
    private let metadata: UnsafeMutablePointer<Chunk?>
    private let producer: UnsafeMutablePointer<Producer>
    private let consumer: UnsafeMutablePointer<Consumer>

    private struct Chunk {
        let sequence: UInt64
        let start: Int64
        let frames: UInt32
        let host: UInt64?
        let gap: PendingGap?
    }
    private struct Producer {
        var sequence: UInt64 = 0
        var expectedSourceEnd: Int64?
        var gap: PendingGap?
        var callbacks: UInt64 = 0
        var accepted: UInt64 = 0
        var overflows: UInt64 = 0
        var oversized: UInt64 = 0
        var invalid: UInt64 = 0
        var dropped: UInt64 = 0
        var highWater: UInt64 = 0
    }
    private struct Consumer {
        var blockGapDelivered = false
        var finalGapDelivered = false
        var faultHandled = false
    }
    private struct PendingGap {
        let reasons: PCMTransferGap.Reasons
        let interval: PCMTransferLostInterval?

        func merging(_ other: Self) -> Self {
            let combined: PCMTransferLostInterval?
            if let a = interval, let b = other.interval, a.endSample == b.startSample {
                combined = .init(startSample: a.startSample, endSample: b.endSample)
            } else {
                combined = nil
            }
            return .init(reasons: reasons.union(other.reasons), interval: combined)
        }
    }

    /// Allocates and touches every PCM page before capture starts.
    public init(configuration: PCMTransferConfiguration) {
        self.configuration = configuration
        limits = Limits(
            token: configuration.captureToken, maximumFrames: configuration.maximumFramesPerChunk,
            channels: configuration.format.channelCount, slotCount: configuration.slotCount,
            bytesPerSample: configuration.bytesPerSample, bytesPerSlot: configuration.bytesPerSlot,
            interleaved: configuration.format.layout == .interleaved)
        storage = .allocate(byteCount: configuration.pcmStorageBytes, alignment: 64)
        storage.initializeMemory(
            as: UInt8.self, repeating: 0, count: configuration.pcmStorageBytes)
        metadata = .allocate(capacity: configuration.slotCount)
        metadata.initialize(repeating: nil, count: configuration.slotCount)
        producer = .allocate(capacity: 1)
        producer.initialize(to: Producer())
        consumer = .allocate(capacity: 1)
        consumer.initialize(to: Consumer())
    }

    deinit {
        consumer.deinitialize(count: 1)
        consumer.deallocate()
        producer.deinitialize(count: 1)
        producer.deallocate()
        metadata.deinitialize(count: configuration.slotCount)
        metadata.deallocate()
        storage.deallocate()
    }

    /// Input must contain exactly `frameCount * channels * bytesPerSample` bytes.
    /// Bytes encode native-endian Float/Double matching the immutable configuration.
    /// Only one producer call may be active, including reentrant calls. A violation
    /// closes admission, rejects the overlapping call, and invalidates queued PCM.
    public func offerInterleaved(
        _ bytes: UnsafeRawBufferPointer, frameCount: UInt32, sourceStartSample: Int64,
        configurationToken: PCMTransferEpochToken, hostStartNanoseconds: UInt64? = nil
    ) -> PCMTransferOfferResult {
        offer(
            interleaved: bytes, planes: nil, frameCount: frameCount,
            sourceStartSample: sourceStartSample, token: configurationToken,
            host: hostStartNanoseconds)
    }

    /// One borrowed byte-buffer descriptor per channel, in configured channel order.
    /// Each plane has exactly `frameCount * bytesPerSample` bytes. Prepare descriptor
    /// storage off the callback. No layout conversion or channel mixing happens here.
    public func offerPlanar(
        _ planes: UnsafeBufferPointer<UnsafeRawBufferPointer>, frameCount: UInt32,
        sourceStartSample: Int64, configurationToken: PCMTransferEpochToken,
        hostStartNanoseconds: UInt64? = nil
    ) -> PCMTransferOfferResult {
        offer(
            interleaved: nil, planes: planes, frameCount: frameCount,
            sourceStartSample: sourceStartSample, token: configurationToken,
            host: hostStartNanoseconds)
    }

    @inline(never)
    private func offer(
        interleaved: UnsafeRawBufferPointer?,
        planes: UnsafeBufferPointer<UnsafeRawBufferPointer>?, frameCount: UInt32,
        sourceStartSample start: Int64, token: PCMTransferEpochToken, host: UInt64?
    ) -> PCMTransferOfferResult {
        let admission = producerControl.compareExchange(
            expected: 0, desired: Self.active, ordering: .acquiring)
        guard admission.exchanged else {
            if admission.original & Self.closed != 0 { return .closed }
            producerControl.bitwiseOr(
                Self.closed | Self.violation, ordering: .acquiringAndReleasing)
            return .concurrentProducer
        }
        defer { producerControl.bitwiseAnd(~Self.active, ordering: .releasing) }
        producer.pointee.callbacks = Self.add(producer.pointee.callbacks, 1)
        callbacks.store(producer.pointee.callbacks, ordering: .relaxed)
        guard token == limits.token else {
            producer.pointee.expectedSourceEnd = nil
            return drop(.configurationMismatch, frames: frameCount, interval: nil)
        }
        if frameCount == 0 { return .empty }
        guard producer.pointee.sequence < UInt64.max else {
            appendGap(.sequenceExhausted, interval: nil)
            producer.pointee.dropped = Self.add(producer.pointee.dropped, UInt64(frameCount))
            dropped.store(producer.pointee.dropped, ordering: .relaxed)
            producerControl.bitwiseOr(Self.closed, ordering: .relaxed)
            return .sequenceExhausted
        }
        let sequence = producer.pointee.sequence
        producer.pointee.sequence += 1
        let end = start.addingReportingOverflow(Int64(frameCount))
        guard start >= 0, !end.overflow else {
            producer.pointee.expectedSourceEnd = nil
            return drop(.invalidInput, frames: frameCount, interval: nil)
        }
        let interval = PCMTransferLostInterval(startSample: start, endSample: end.partialValue)
        if let expected = producer.pointee.expectedSourceEnd, expected != start {
            appendGap(
                .sourceDiscontinuity,
                interval: start > expected
                    ? .init(startSample: expected, endSample: start) : nil)
        }
        producer.pointee.expectedSourceEnd = end.partialValue
        guard frameCount <= limits.maximumFrames else {
            return drop(.droppedOversized, frames: frameCount, interval: interval)
        }
        let planeBytes = Int(frameCount) * limits.bytesPerSample
        let byteCount = planeBytes * limits.channels
        if limits.interleaved {
            guard let interleaved, interleaved.count == byteCount,
                interleaved.baseAddress != nil, planes == nil
            else { return drop(.invalidInput, frames: frameCount, interval: interval) }
        } else {
            guard let planes, planes.count == limits.channels,
                interleaved == nil
            else { return drop(.invalidInput, frames: frameCount, interval: interval) }
            for plane in planes {
                guard plane.count == planeBytes, plane.baseAddress != nil else {
                    return drop(.invalidInput, frames: frameCount, interval: interval)
                }
            }
        }
        let head = published.load(ordering: .relaxed)
        let tail = released.load(ordering: .acquiring)
        let depth = head &- tail
        guard depth < UInt64(limits.slotCount) else {
            return drop(.droppedCapacity, frames: frameCount, interval: interval)
        }
        let index = Int(head & UInt64(limits.slotCount - 1))
        let destination = storage.advanced(by: index * limits.bytesPerSlot)
        if let interleaved {
            destination.copyMemory(from: interleaved.baseAddress!, byteCount: byteCount)
        } else if let planes {
            for channel in 0..<limits.channels {
                destination.advanced(by: channel * planeBytes).copyMemory(
                    from: planes[channel].baseAddress!, byteCount: planeBytes)
            }
        }
        metadata[index] = Chunk(
            sequence: sequence, start: start, frames: frameCount, host: host,
            gap: producer.pointee.gap)
        producer.pointee.gap = nil
        published.store(head &+ 1, ordering: .releasing)
        producer.pointee.accepted = Self.add(producer.pointee.accepted, 1)
        producer.pointee.highWater = max(producer.pointee.highWater, depth + 1)
        accepted.store(producer.pointee.accepted, ordering: .relaxed)
        highWater.store(producer.pointee.highWater, ordering: .relaxed)
        return .accepted(sequence: sequence)
    }

    @inline(__always)
    private func appendGap(
        _ reasons: PCMTransferGap.Reasons, interval: PCMTransferLostInterval?
    ) {
        let next = PendingGap(reasons: reasons, interval: interval)
        producer.pointee.gap = producer.pointee.gap.map { $0.merging(next) } ?? next
    }

    @inline(__always)
    private func drop(
        _ result: PCMTransferOfferResult, frames: UInt32, interval: PCMTransferLostInterval?
    ) -> PCMTransferOfferResult {
        let reason: PCMTransferGap.Reasons
        switch result {
        case .droppedCapacity:
            reason = .capacity
            producer.pointee.overflows = Self.add(producer.pointee.overflows, 1)
            overflows.store(producer.pointee.overflows, ordering: .relaxed)
        case .droppedOversized:
            reason = .oversized
            producer.pointee.oversized = Self.add(producer.pointee.oversized, 1)
            oversized.store(producer.pointee.oversized, ordering: .relaxed)
        default:
            reason = result == .configurationMismatch ? .configurationMismatch : .invalidInput
            producer.pointee.invalid = Self.add(producer.pointee.invalid, 1)
            invalid.store(producer.pointee.invalid, ordering: .relaxed)
        }
        producer.pointee.dropped = Self.add(producer.pointee.dropped, UInt64(frames))
        dropped.store(producer.pointee.dropped, ordering: .relaxed)
        appendGap(reason, interval: interval)
        return result
    }

    /// Nonblocking, idempotent. An already admitted producer may finish its copy.
    /// Drain on the worker until `.finished`; retain the transport until native
    /// callbacks are quiescent. This method never frees storage or waits for them.
    public func close() {
        producerControl.bitwiseOr(Self.closed, ordering: .acquiringAndReleasing)
    }

    /// Delivers at most one event on the calling worker, never on the producer.
    /// Gaps precede affected blocks; a final pending gap precedes `.finished`.
    /// The block remains owned by this call until the closure returns. A slow closure
    /// can cause producer drops but cannot block capture or allow slot reuse.
    @discardableResult
    public func withNext(_ body: (PCMTransferEvent) -> Void) -> PCMTransferReadResult {
        guard
            consumerActive.compareExchange(
                expected: false, desired: true, ordering: .acquiring
            ).exchanged
        else { return .concurrentConsumer }
        defer { consumerActive.store(false, ordering: .releasing) }
        let control = producerControl.load(ordering: .acquiring)
        if control & Self.violation != 0 {
            guard control & Self.active == 0 else { return .empty }
            guard !consumer.pointee.faultHandled else { return .finished }
            // No future admission is possible. Discard pending PCM instead of
            // claiming temporal ordering after an unsupported producer collision.
            let head = published.load(ordering: .acquiring)
            var tail = released.load(ordering: .relaxed)
            var frames: UInt64 = 0
            while tail != head {
                let index = Int(tail & UInt64(configuration.slotCount - 1))
                frames = Self.add(frames, UInt64(metadata[index]!.frames))
                tail &+= 1
            }
            discarded.store(frames, ordering: .relaxed)
            released.store(head, ordering: .releasing)
            consumer.pointee.faultHandled = true
            let fault = PendingGap(reasons: .producerViolation, interval: nil)
            body(.gap(publicGap(producer.pointee.gap.map { $0.merging(fault) } ?? fault)))
            return .delivered
        }
        let tail = released.load(ordering: .relaxed)
        // This acquire follows the closed/inactive observation, so an admitted
        // final publication cannot be mistaken for an empty completed queue.
        let head = published.load(ordering: .acquiring)
        guard head != tail else {
            guard control & (Self.active | Self.closed) == Self.closed else { return .empty }
            if !consumer.pointee.finalGapDelivered, let gap = producer.pointee.gap {
                consumer.pointee.finalGapDelivered = true
                body(.gap(publicGap(gap)))
                return .delivered
            }
            return .finished
        }
        let index = Int(tail & UInt64(configuration.slotCount - 1))
        let chunk = metadata[index]!
        if let gap = chunk.gap, !consumer.pointee.blockGapDelivered {
            consumer.pointee.blockGapDelivered = true
            body(.gap(publicGap(gap)))
            return .delivered
        }
        let bytes = UnsafeRawBufferPointer(
            start: storage.advanced(by: index * configuration.bytesPerSlot),
            count: Int(chunk.frames) * configuration.format.channelCount
                * configuration.bytesPerSample)
        body(
            .block(
                .init(
                    sequence: chunk.sequence, sourceStartSample: chunk.start,
                    frameCount: chunk.frames,
                    hostStartNanoseconds: chunk.host, configurationEpoch: configuration.epoch,
                    bytes: bytes)))
        consumer.pointee.blockGapDelivered = false
        released.store(tail &+ 1, ordering: .releasing)
        return .delivered
    }

    /// Call off the audio callback. Diagnostics never inspect mutable producer state.
    public func snapshot() -> PCMTransferSnapshot {
        var depth: Int?
        for _ in 0..<3 {
            let before = released.load(ordering: .acquiring)
            let head = published.load(ordering: .acquiring)
            let after = released.load(ordering: .acquiring)
            let count = head &- before
            if before == after, count <= UInt64(configuration.slotCount) {
                depth = Int(count)
                break
            }
        }
        let control = producerControl.load(ordering: .acquiring)
        return PCMTransferSnapshot(
            admittedCallbacks: callbacks.load(ordering: .relaxed),
            acceptedChunks: accepted.load(ordering: .relaxed),
            overflowChunks: overflows.load(ordering: .relaxed),
            oversizedChunks: oversized.load(ordering: .relaxed),
            invalidChunks: invalid.load(ordering: .relaxed),
            droppedFrames: Self.add(
                dropped.load(ordering: .relaxed), discarded.load(ordering: .relaxed)),
            depth: depth, highWaterSlots: Int(highWater.load(ordering: .relaxed)),
            isClosed: control & Self.closed != 0,
            producerContractViolated: control & Self.violation != 0)
    }

    @inline(__always)
    private static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let sum = a.addingReportingOverflow(b)
        return sum.overflow ? .max : sum.partialValue
    }

    private func publicGap(_ gap: PendingGap) -> PCMTransferGap {
        .init(
            configurationEpoch: configuration.epoch, reasons: gap.reasons,
            missingSource: gap.interval)
    }

    // Internal deterministic test seams: no hook is reachable from an offer call.
    // Initialize only before publishing the object to any other thread.
    convenience init(
        configuration: PCMTransferConfiguration, initialCursor: UInt64, initialSequence: UInt64
    ) {
        self.init(configuration: configuration)
        published.store(initialCursor, ordering: .relaxed)
        released.store(initialCursor, ordering: .relaxed)
        producer.pointee.sequence = initialSequence
    }

    func withHeldProducerAdmissionForTesting(_ body: () -> Void) {
        precondition(
            producerControl.compareExchange(
                expected: 0, desired: Self.active, ordering: .acquiring
            ).exchanged)
        defer { producerControl.bitwiseAnd(~Self.active, ordering: .releasing) }
        body()
    }
}
