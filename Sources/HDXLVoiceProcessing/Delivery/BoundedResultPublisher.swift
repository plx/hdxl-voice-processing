import Dispatch
import Foundation
import Synchronization

/// Single-owner worker/control publisher. Never invoke from a capture callback.
/// Bounds count publications, not arbitrary caller-defined payload bytes. Domain
/// snapshots must also bound their own contents. No task is created per publication.
public final class BoundedResultPublisher<Value: Sendable> {
    private struct Entry { weak var mailbox: ResultMailbox<Value>? }
    private let maximumSubscribers: Int
    private let replayLatest: Bool
    private let clock: @Sendable () -> UInt64
    private let diagnosticMode: RuntimeDiagnosticMode
    private let diagnosticSink: (any DiagnosticSink)?
    private let diagnostics: WorkerDiagnostics
    private var entries: [Entry] = []
    private var latest: ResultPublication<Value>?
    private var sequence: UInt64 = 0
    private var terminal: ResultDeliveryTermination?

    public convenience init(
        maximumSubscribers: Int = 16, replayLatest: Bool = false,
        diagnostics: RuntimeDiagnosticMode = .disabled
    ) throws {
        try self.init(
            maximumSubscribers: maximumSubscribers, replayLatest: replayLatest,
            diagnostics: diagnostics,
            clock: { DispatchTime.now().uptimeNanoseconds })
    }

    init(
        maximumSubscribers: Int, replayLatest: Bool,
        diagnostics: RuntimeDiagnosticMode = .disabled,
        diagnosticSink: (any DiagnosticSink)? = nil,
        clock: @escaping @Sendable () -> UInt64
    ) throws {
        guard (1...64).contains(maximumSubscribers) else {
            throw ResultDeliveryError.invalidCapacity
        }
        self.maximumSubscribers = maximumSubscribers
        self.replayLatest = replayLatest
        self.clock = clock
        self.diagnosticMode = diagnostics
        self.diagnosticSink = diagnosticSink
        self.diagnostics = WorkerDiagnostics(mode: diagnostics.facadeMode, sink: diagnosticSink)
        entries.reserveCapacity(maximumSubscribers)
    }

    deinit {
        for entry in entries { entry.mailbox?.finish(.failed(.publisherReleased)) }
    }

    public var activeSubscriberCount: Int {
        reap()
        return entries.count
    }

    /// One logical iterator per subscription. Copies share cancellation and storage.
    /// A late subscriber receives at most one replay when explicitly enabled.
    public func subscribe(
        _ policy: ResultDeliveryPolicy = .newest(capacity: 1)
    ) throws -> ResultSubscription<Value> {
        guard (1...4096).contains(policy.capacity) else {
            throw ResultDeliveryError.invalidCapacity
        }
        reap()
        guard terminal != nil || entries.count < maximumSubscribers else {
            throw ResultDeliveryError.subscriberLimit
        }
        let mailbox = ResultMailbox<Value>(
            policy: policy, clock: clock, diagnostics: diagnosticMode, sink: diagnosticSink)
        if let terminal {
            mailbox.finish(terminal)
        } else {
            entries.append(Entry(mailbox: mailbox))
            if let latest { _ = mailbox.offer(latest) }
        }
        return ResultSubscription(lease: ResultSubscriptionLease(mailbox))
    }

    /// Overflow fails only the affected subscriber; it cannot stop other consumers
    /// or alter numerical processing. Inspect the returned outcome for durable sinks.
    @discardableResult public func publish(_ value: Value) -> ResultPublicationReport {
        guard terminal == nil else { return report(publication: nil) }
        guard sequence != .max else {
            finish(.failed(.sequenceExhausted))
            return report(publication: nil)
        }
        let publication = ResultPublication(
            value: value, sequence: sequence, hostNanoseconds: clock())
        sequence += 1
        if replayLatest { latest = publication }
        var accepted = 0
        var coalesced = 0
        var overflowed = 0
        reap()
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 5401
        metadata.frameSequence = publication.sequence
        metadata.queueDepth = UInt32(entries.count)
        diagnostics.withFrame(metadata, stage: .resultPublication) {
            for entry in entries {
                switch entry.mailbox?.offer(publication) {
                case .accepted: accepted += 1
                case .coalesced:
                    accepted += 1
                    coalesced += 1
                case .overflow: overflowed += 1
                case .terminated, nil: break
                }
            }
            if overflowed > 0 { diagnostics.event(.drop, validity: .failed) }
        }
        reap()
        return ResultPublicationReport(
            publication: publication.sequence, acceptedSubscribers: accepted,
            coalescedSubscribers: coalesced, overflowedSubscribers: overflowed,
            isFinished: false)
    }

    /// The first terminal reason wins. Already accepted values drain before terminal
    /// delivery; explicit subscriber cancellation discards them immediately.
    public func finish(_ reason: ResultDeliveryTermination = .finished) {
        guard terminal == nil else { return }
        terminal = reason
        for entry in entries { entry.mailbox?.finish(reason) }
        entries.removeAll(keepingCapacity: true)
        latest = nil
    }

    private func reap() {
        entries.removeAll { $0.mailbox?.isTerminated != false }
    }

    private func report(publication: UInt64?) -> ResultPublicationReport {
        ResultPublicationReport(
            publication: publication, acceptedSubscribers: 0, coalescedSubscribers: 0,
            overflowedSubscribers: 0, isFinished: terminal != nil)
    }
}

public struct ResultSubscription<Value: Sendable>: AsyncSequence, Sendable {
    public typealias Element = ResultDelivery<Value>
    fileprivate let lease: ResultSubscriptionLease<Value>

    public var statistics: ResultDeliveryStatistics { lease.mailbox.statistics }
    public var termination: ResultDeliveryTermination? { lease.mailbox.termination }
    public func cancel() { lease.mailbox.cancel() }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lease: lease, identity: UUID())
    }

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        fileprivate let lease: ResultSubscriptionLease<Value>
        fileprivate let identity: UUID
        public mutating func next() async throws -> ResultDelivery<Value>? {
            try await lease.mailbox.next(iterator: identity)
        }
    }
}

private final class ResultSubscriptionLease<Value: Sendable>: Sendable {
    let mailbox: ResultMailbox<Value>
    init(_ mailbox: ResultMailbox<Value>) { self.mailbox = mailbox }
    deinit { mailbox.cancel() }
}

private struct ResultPublication<Value: Sendable>: Sendable {
    let value: Value
    let sequence: UInt64
    let hostNanoseconds: UInt64
}

private final class ResultMailbox<Value: Sendable>: Sendable {
    enum Offer { case accepted, coalesced, overflow, terminated }
    typealias Waiter = CheckedContinuation<ResultPublication<Value>?, any Error>
    private struct State: Sendable {
        var slots: [ResultPublication<Value>?]
        var head = 0
        var count = 0
        var highWater = 0
        var accepted: UInt64 = 0
        var delivered: UInt64 = 0
        var coalesced: UInt64 = 0
        var rejected: UInt64 = 0
        var discarded: UInt64 = 0
        var lastLag: UInt64?
        var maximumLag: UInt64?
        var iterator: UUID?
        var nextInProgress = false
        var waiter: Waiter?
        var terminal: ResultDeliveryTermination?
        var terminalDelivered = false

        func statistics() -> ResultDeliveryStatistics {
            ResultDeliveryStatistics(
                capacity: slots.count, buffered: count, highWater: highWater,
                accepted: accepted, delivered: delivered, coalesced: coalesced,
                rejected: rejected, discardedOnCancellation: discarded,
                lastSubscriberLagNanoseconds: lastLag, maximumSubscriberLagNanoseconds: maximumLag)
        }

        mutating func terminalResult() -> Result<ResultPublication<Value>?, any Error> {
            guard !terminalDelivered else { return .success(nil) }
            terminalDelivered = true
            if case .failed(let error) = terminal { return .failure(error) }
            return .success(nil)
        }
    }

    private let policy: ResultDeliveryPolicy
    private let clock: @Sendable () -> UInt64
    private let state: Mutex<State>
    // Only consumer observation uses this lock; producer offer/finish never takes it.
    private let observationDiagnostics: Mutex<WorkerDiagnostics>

    init(
        policy: ResultDeliveryPolicy, clock: @escaping @Sendable () -> UInt64,
        diagnostics: RuntimeDiagnosticMode, sink: (any DiagnosticSink)?
    ) {
        self.policy = policy
        self.clock = clock
        state = Mutex(State(slots: Array(repeating: nil, count: policy.capacity)))
        observationDiagnostics = Mutex(WorkerDiagnostics(mode: diagnostics.facadeMode, sink: sink))
    }

    var isTerminated: Bool { state.withLock { $0.terminal != nil } }
    var termination: ResultDeliveryTermination? { state.withLock { $0.terminal } }
    var statistics: ResultDeliveryStatistics { state.withLock { $0.statistics() } }

    func offer(_ publication: ResultPublication<Value>) -> Offer {
        var waiter: Waiter?
        let outcome: Offer = state.withLock { state in
            guard state.terminal == nil else { return .terminated }
            if let pending = state.waiter {
                state.waiter = nil
                waiter = pending
                state.accepted = saturatingAdd(state.accepted)
                return .accepted
            }
            var outcome = Offer.accepted
            if state.count == state.slots.count {
                switch policy {
                case .newest:
                    state.slots[state.head] = nil
                    state.head = (state.head + 1) % state.slots.count
                    state.count -= 1
                    state.coalesced = saturatingAdd(state.coalesced)
                    outcome = .coalesced
                case .failOnOverflow:
                    state.rejected = saturatingAdd(state.rejected)
                    state.terminal = .failed(.overflow(rejectedPublication: publication.sequence))
                    return .overflow
                }
            }
            state.slots[(state.head + state.count) % state.slots.count] = publication
            state.count += 1
            state.highWater = max(state.highWater, state.count)
            state.accepted = saturatingAdd(state.accepted)
            return outcome
        }
        waiter?.resume(returning: publication)
        return outcome
    }

    func finish(_ reason: ResultDeliveryTermination, discard: Bool = false) {
        var response: (Waiter, Result<ResultPublication<Value>?, any Error>)?
        state.withLock { state in
            if state.terminal == nil { state.terminal = reason }
            if discard {
                state.discarded = saturatingAdd(state.discarded, UInt64(state.count))
                for index in state.slots.indices { state.slots[index] = nil }
                state.count = 0
            }
            if let waiter = state.waiter {
                state.waiter = nil
                response = (waiter, state.terminalResult())
            }
        }
        if let (waiter, result) = response { waiter.resume(with: result) }
    }

    func cancel() { finish(.failed(.cancelled), discard: true) }

    func next(iterator: UUID) async throws -> ResultDelivery<Value>? {
        try state.withLock { state in
            guard !state.nextInProgress, state.iterator == nil || state.iterator == iterator else {
                throw ResultDeliveryError.concurrentIteration
            }
            state.iterator = iterator
            state.nextInProgress = true
        }
        defer { state.withLock { $0.nextInProgress = false } }
        let publication = try await withTaskCancellationHandler {
            if Task.isCancelled { cancel() }
            return try await withCheckedThrowingContinuation { (waiter: Waiter) in
                let response: Result<ResultPublication<Value>?, any Error>? = state.withLock {
                    state in
                    guard state.waiter == nil else {
                        return .failure(ResultDeliveryError.concurrentIteration)
                    }
                    if state.count > 0 {
                        let result = state.slots[state.head]!
                        state.slots[state.head] = nil
                        state.head = (state.head + 1) % state.slots.count
                        state.count -= 1
                        return .success(result)
                    }
                    if state.terminal != nil { return state.terminalResult() }
                    state.waiter = waiter
                    return nil
                }
                if let response { waiter.resume(with: response) }
            }
        } onCancel: {
            self.cancel()
        }
        guard let publication else { return nil }
        let observed = clock()
        let statistics = state.withLock { state in
            state.delivered = saturatingAdd(state.delivered)
            state.lastLag =
                observed >= publication.hostNanoseconds
                ? observed - publication.hostNanoseconds : nil
            if let lag = state.lastLag { state.maximumLag = max(state.maximumLag ?? 0, lag) }
            return state.statistics()
        }
        observationDiagnostics.withLock { diagnostics in
            var metadata = DiagnosticMetadata()
            metadata.profileToken = 5402
            metadata.frameSequence = publication.sequence
            metadata.queueDepth = UInt32(statistics.buffered)
            metadata.queueWaitNanoseconds = statistics.lastSubscriberLagNanoseconds
            diagnostics.withFrame(metadata, stage: .resultDelivery) {}
        }
        return ResultDelivery(
            value: publication.value, publication: publication.sequence,
            publishedAtHostNanoseconds: publication.hostNanoseconds,
            observedAtHostNanoseconds: observed, statistics: statistics)
    }
}
