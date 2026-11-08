import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func feedbackManyObserversCoalesceAndOverflowWithoutChangingPolicy() async throws {
    let target = try feedbackTestTarget()
    let clock = FeedbackTestClock()
    let configuration = try feedbackTestConfiguration()
    let policy = try PersonalTargetFeedback(
        target: target, configuration: configuration, maximumSubscribers: 64, clock: clock.now)
    let baseline = try PersonalTargetFeedback(
        target: target, configuration: configuration, clock: clock.now)
    let fast = try policy.subscribe(.failOnOverflow(capacity: 64))
    let stalled = try policy.subscribe(.failOnOverflow(capacity: 4))
    let displays = try (0..<62).map { _ in try policy.subscribe(.newest(capacity: 1)) }
    #expect(policy.activeSubscriberCount == 64)
    #expect(throws: ResultDeliveryError.subscriberLimit) { try policy.subscribe() }
    displays[0].cancel()
    let initial = policy.latest
    for _ in 0..<100 {
        let transient = try policy.subscribe()
        transient.cancel()
    }
    #expect(policy.latest == initial)
    #expect(policy.activeSubscriberCount == 63)
    for index in 0..<20 {
        let input = try feedbackTestEvidence(index: index, value: index.isMultiple(of: 2) ? 10 : 4)
        let actual = try feedbackTestUpdate(policy, clock, input)
        let expected = try feedbackTestUpdate(baseline, clock, input)
        #expect(actual == expected)
    }
    let final = policy.finish()
    #expect(final.reasons == [.finished])
    #expect(policy.activeSubscriberCount == 0)
    var fastIterator = fast.makeAsyncIterator()
    var count = 0
    while let item = try await fastIterator.next() {
        #expect(item.publication == UInt64(count))
        count += 1
    }
    #expect(count == 22)  // Initial replay, twenty observations, explicit completion.
    var stalledIterator = stalled.makeAsyncIterator()
    for sequence in 0..<4 {
        let item = try await stalledIterator.next()
        #expect(item?.publication == UInt64(sequence))
    }
    do {
        _ = try await stalledIterator.next()
        Issue.record("A stalled durable sink did not report overflow")
    } catch let error as ResultDeliveryError {
        #expect(error == .overflow(rejectedPublication: 4))
    }
    #expect(try await stalledIterator.next() == nil)
    for display in displays.dropFirst() {
        var iterator = display.makeAsyncIterator()
        let last = try await iterator.next()
        #expect(last?.value == final)
        #expect(last?.statistics.coalesced == 21)
        #expect(last?.statistics.highWater == 1)
        #expect(try await iterator.next() == nil)
    }
}

@Test func feedbackInstrumentationRecordsStateChangesWithoutPersonalValues() throws {
    let target = try feedbackTestTarget()
    var snapshots: [PersonalTargetFeedbackSnapshot] = []
    for mode in RuntimeDiagnosticMode.allCases {
        let clock = FeedbackTestClock()
        let sink = RecordingSink()
        let policy = try PersonalTargetFeedback(
            target: target, configuration: feedbackTestConfiguration(), diagnostics: mode,
            maximumSubscribers: 1, clock: clock.now, diagnosticSink: sink)
        for index in 0..<10 {
            _ = try feedbackTestUpdate(policy, clock, feedbackTestEvidence(index: index))
        }
        snapshots.append(policy.poll())
        let begins = sink.entries.compactMap { entry -> DiagnosticRecord? in
            guard case .begin(let record) = entry, record.stage == .feedbackStateChange else {
                return nil
            }
            return record
        }
        let ends = sink.entries.compactMap { entry -> DiagnosticRecord? in
            guard case .end(let record) = entry, record.stage == .feedbackStateChange else {
                return nil
            }
            return record
        }
        #expect(begins == ends)
        #expect(begins.count == (mode == .disabled ? 0 : mode == .sampled ? 1 : 2))
        #expect(
            begins.allSatisfy {
                $0.metadata.profileToken == 5701 && $0.metadata.sampleCount == 0
                    && $0.metadata.queueWaitNanoseconds == nil && $0.metadata.queueDepth == 0
            })
        #expect(policy.latest.statistics.stateChanges == 2)
    }
    #expect(snapshots[0] == snapshots[1])
    #expect(snapshots[1] == snapshots[2])
}
