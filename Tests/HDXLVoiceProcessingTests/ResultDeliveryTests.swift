import Dispatch
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

@Test func deliveryLimitsAndClosedSubscriptions() async throws {
    #expect(throws: ResultDeliveryError.invalidCapacity) {
        try BoundedResultPublisher<Int>(maximumSubscribers: 0)
    }
    let publisher = try BoundedResultPublisher<Int>(maximumSubscribers: 1)
    #expect(throws: ResultDeliveryError.invalidCapacity) {
        try publisher.subscribe(.newest(capacity: 0))
    }
    #expect(throws: ResultDeliveryError.invalidCapacity) {
        try publisher.subscribe(.failOnOverflow(capacity: 4097))
    }
    let first = try publisher.subscribe()
    #expect(throws: ResultDeliveryError.subscriberLimit) { try publisher.subscribe() }
    first.cancel()
    #expect(publisher.activeSubscriberCount == 0)
    let second = try publisher.subscribe()
    publisher.finish()
    #expect(publisher.activeSubscriberCount == 0)
    #expect(second.termination == .finished)
    let late = try publisher.subscribe()
    var iterator = late.makeAsyncIterator()
    #expect(try await iterator.next() == nil)
    #expect(publisher.publish(1).isFinished)
}

@Test func deliveryNewestHasExactIndependentCoalescingAndLag() async throws {
    let time = Mutex<UInt64>(100)
    let publisher = try BoundedResultPublisher<Int>(
        maximumSubscribers: 2, replayLatest: false, clock: { time.withLock { $0 } })
    let slow = try publisher.subscribe(.newest(capacity: 2))
    let newest = try publisher.subscribe(.newest(capacity: 1))
    for value in 0..<10 { publisher.publish(value) }
    #expect(slow.statistics.buffered == 2)
    #expect(slow.statistics.highWater == 2)
    #expect(slow.statistics.coalesced == 8)
    #expect(newest.statistics.coalesced == 9)
    time.withLock { $0 = 190 }
    publisher.finish()
    var iterator = slow.makeAsyncIterator()
    let first = try #require(await iterator.next())
    #expect(first.value == 8 && first.publication == 8)
    #expect(first.publishedAtHostNanoseconds == 100)
    #expect(first.observedAtHostNanoseconds == 190)
    #expect(first.statistics.lastSubscriberLagNanoseconds == 90)
    #expect(first.statistics.coalesced == 8 && first.statistics.rejected == 0)
    #expect(try await iterator.next()?.value == 9)
    #expect(try await iterator.next() == nil)
    #expect(slow.statistics.delivered == 2)
    var other = newest.makeAsyncIterator()
    #expect(try await other.next()?.value == 9)
    #expect(try await other.next() == nil)
}

@Test func deliveryOverflowFailsOnlyThatSubscriberAfterAcceptedValues() async throws {
    let publisher = try BoundedResultPublisher<Int>()
    let strict = try publisher.subscribe(.failOnOverflow(capacity: 2))
    let display = try publisher.subscribe()
    publisher.publish(0)
    publisher.publish(1)
    let result = publisher.publish(2)
    #expect(result.acceptedSubscribers == 1 && result.overflowedSubscribers == 1)
    #expect(result.coalescedSubscribers == 1)
    #expect(publisher.activeSubscriberCount == 1)
    #expect(strict.termination == .failed(.overflow(rejectedPublication: 2)))
    var iterator = strict.makeAsyncIterator()
    #expect(try await iterator.next()?.value == 0)
    #expect(try await iterator.next()?.value == 1)
    await #expect(throws: ResultDeliveryError.overflow(rejectedPublication: 2)) {
        try await iterator.next()
    }
    #expect(try await iterator.next() == nil)
    #expect(strict.statistics.rejected == 1 && strict.statistics.coalesced == 0)
    publisher.publish(3)
    publisher.finish()
    var displayIterator = display.makeAsyncIterator()
    #expect(try await displayIterator.next()?.value == 3)
    #expect(try await displayIterator.next() == nil)
}

@Test func deliveryReplayIsExplicitAndDoesNotRepublishToExistingConsumers() async throws {
    let publisher = try BoundedResultPublisher<Int>(replayLatest: true)
    for value in 0..<100 { #expect(publisher.publish(value).acceptedSubscribers == 0) }
    let first = try publisher.subscribe(.failOnOverflow(capacity: 2))
    let second = try publisher.subscribe()
    #expect(first.statistics.accepted == 1 && second.statistics.accepted == 1)
    publisher.publish(100)
    publisher.finish()
    var iterator = first.makeAsyncIterator()
    let replay = try #require(await iterator.next())
    #expect(replay.value == 99 && replay.publication == 99)
    #expect(try await iterator.next()?.value == 100)
    #expect(try await iterator.next() == nil)
    let empty = try BoundedResultPublisher<Int>()
    empty.publish(123)
    let noReplay = try empty.subscribe()
    #expect(noReplay.statistics.buffered == 0)
    empty.finish()
}

@MainActor @Test func deliveryWaitingConsumerCancellationCompletesOnce() async throws {
    let publisher = try BoundedResultPublisher<Int>()
    let subscription = try publisher.subscribe()
    var entered = false
    let consumer = Task<Void, any Error> { @MainActor in
        var iterator = subscription.makeAsyncIterator()
        entered = true
        await #expect(throws: ResultDeliveryError.cancelled) { try await iterator.next() }
        let afterCancellation = try await iterator.next()
        #expect(afterCancellation == nil)
    }
    while !entered { await Task.yield() }
    subscription.cancel()
    subscription.cancel()
    try await consumer.value
    #expect(subscription.termination == .failed(.cancelled))
    #expect(publisher.activeSubscriberCount == 0)
    #expect(publisher.publish(1).acceptedSubscribers == 0)
}

@Test func deliveryAlreadyCancelledTaskCannotRegisterAWaiter() async throws {
    let publisher = try BoundedResultPublisher<Int>()
    let subscription = try publisher.subscribe()
    let consumer = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        var iterator = subscription.makeAsyncIterator()
        await #expect(throws: ResultDeliveryError.cancelled) { try await iterator.next() }
    }
    await consumer.value
    #expect(subscription.termination == .failed(.cancelled))
    #expect(publisher.activeSubscriberCount == 0)
}

@MainActor @Test func deliveryRejectsConcurrentIteratorsWithoutStealingWaiter() async throws {
    let publisher = try BoundedResultPublisher<Int>()
    let subscription = try publisher.subscribe()
    var entered = false
    let consumer = Task { @MainActor in
        var iterator = subscription.makeAsyncIterator()
        entered = true
        return try await iterator.next()
    }
    while !entered { await Task.yield() }
    var other = subscription.makeAsyncIterator()
    await #expect(throws: ResultDeliveryError.concurrentIteration) { try await other.next() }
    publisher.publish(42)
    #expect(try await consumer.value?.value == 42)
    subscription.cancel()
}

@Test func deliveryPublisherDeinitDrainsThenReportsReleaseOnce() async throws {
    var publisher: BoundedResultPublisher<Int>? = try BoundedResultPublisher()
    let subscription = try #require(publisher).subscribe(.failOnOverflow(capacity: 2))
    publisher?.publish(1)
    publisher?.publish(2)
    publisher = nil
    #expect(subscription.termination == .failed(.publisherReleased))
    var iterator = subscription.makeAsyncIterator()
    #expect(try await iterator.next()?.value == 1)
    #expect(try await iterator.next()?.value == 2)
    await #expect(throws: ResultDeliveryError.publisherReleased) { try await iterator.next() }
    #expect(try await iterator.next() == nil)
}

private final class DeliveryLifetimeProbe: Sendable {}

@Test func deliveryAbandonedSubscriptionReleasesBufferedPayloads() throws {
    let publisher = try BoundedResultPublisher<DeliveryLifetimeProbe>()
    var subscription: ResultSubscription<DeliveryLifetimeProbe>? = try publisher.subscribe()
    weak var observed: DeliveryLifetimeProbe?
    do {
        let value = DeliveryLifetimeProbe()
        observed = value
        publisher.publish(value)
    }
    #expect(observed != nil)
    #expect(subscription?.statistics.buffered == 1)
    subscription = nil
    #expect(observed == nil)
    #expect(publisher.activeSubscriberCount == 0)
}

@Test func deliveryCancellationDiscardsBuffersAndFirstTerminalReasonWins() async throws {
    let publisher = try BoundedResultPublisher<Int>()
    let subscription = try publisher.subscribe(.failOnOverflow(capacity: 4))
    for value in 0..<4 { publisher.publish(value) }
    publisher.finish()
    publisher.finish(.failed(.publisherReleased))
    subscription.cancel()
    #expect(subscription.statistics.discardedOnCancellation == 4)
    #expect(subscription.statistics.buffered == 0)
    #expect(subscription.termination == .finished)
    var iterator = subscription.makeAsyncIterator()
    #expect(try await iterator.next() == nil)
}

@Test func deliverySubscriptionChurnCannotExhaustActiveCapacity() throws {
    let publisher = try BoundedResultPublisher<Int>(maximumSubscribers: 1)
    for value in 0..<1000 {
        let subscription = try publisher.subscribe()
        #expect(publisher.publish(value).acceptedSubscribers == 1)
        #expect(subscription.statistics.accepted == 1)
    }
    #expect(publisher.activeSubscriberCount == 0)
}

@MainActor @Test func deliveryConcurrentOverloadIsBoundedAndOrdered() async throws {
    let publisher = try BoundedResultPublisher<Int>()
    let subscription = try publisher.subscribe(.newest(capacity: 4))
    let consumer = Task.detached {
        var previous = -1
        var count: UInt64 = 0
        for try await receipt in subscription {
            #expect(receipt.value > previous)
            #expect(receipt.statistics.buffered <= 4)
            previous = receipt.value
            count += 1
            await Task.yield()
        }
        return (previous, count)
    }
    for value in 0..<10_000 {
        publisher.publish(value)
        if value % 32 == 0 { await Task.yield() }
    }
    publisher.finish()
    let (last, count) = try await consumer.value
    let statistics = subscription.statistics
    #expect(last == 9999)
    #expect(count == statistics.delivered)
    #expect(statistics.accepted == 10_000)
    #expect(statistics.delivered + statistics.coalesced == 10_000)
    #expect(statistics.highWater <= 4 && statistics.buffered == 0)
    #expect(statistics.rejected == 0)
}

@MainActor @Test func deliveryIteratorCopiesCannotOverlapObservation() async throws {
    let shouldPause = Mutex(false)
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let publisher = try BoundedResultPublisher<Int>(
        maximumSubscribers: 1, replayLatest: false,
        clock: {
            let pause = shouldPause.withLock { value in
                let pause = value
                value = false
                return pause
            }
            if pause {
                entered.withLock { $0 = true }
                release.wait()
            }
            return 100
        })
    let subscription = try publisher.subscribe(.failOnOverflow(capacity: 2))
    let original = subscription.makeAsyncIterator()
    publisher.publish(1)
    shouldPause.withLock { $0 = true }
    let first = Task.detached {
        var iterator = original
        return try await iterator.next()
    }
    defer { release.signal() }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !entered.withLock({ $0 }) {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(1))
    }
    var copy = original
    await #expect(throws: ResultDeliveryError.concurrentIteration) { try await copy.next() }
    // Observation diagnostics/consumer work cannot hold the producer's mailbox lock.
    #expect(publisher.publish(2).acceptedSubscribers == 1)
    release.signal()
    #expect(try await first.value?.value == 1)
    #expect(try await copy.next()?.value == 2)
    publisher.finish()
}
