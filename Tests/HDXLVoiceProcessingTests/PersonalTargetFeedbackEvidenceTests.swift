import Dispatch
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct FeedbackPreparation: Encodable {
    let rateHz: Int
    let nanoseconds: [UInt64]
}

private struct FeedbackTrial: Encodable {
    let rateHz, subscribers, trial: Int
    let mode, targetSHA256, configurationSHA256, outputSHA256: String
    let updateNanoseconds: [UInt64]
    let sourceSamples, qualifiedSamples, matchingSamples, acceptedIntervals, stateChanges: UInt64
    let finalState: String
    let fastDelivered, fastHighWater, strictDelivered, strictHighWater, strictErrors: Int
    let displayDelivered, displayCoalesced, displayHighWater, activeAfterFinish: Int
}

private struct FeedbackEvidenceReport: Encodable {
    let preparations: [FeedbackPreparation]
    let trials: [FeedbackTrial]
}

// This measures policy and bounded delivery using fabricated, validated summaries.
// A 1 ms synthetic summary is a stress input, not evidence of valid 1 ms CPPS DSP.
@MainActor private func feedbackEvidenceTrial(
    target: ActivatedPersonalTarget, inputs: [PersonalTargetFeedbackEvidence],
    rate: Int, subscribers: Int, mode: RuntimeDiagnosticMode, trial: Int
) async throws -> FeedbackTrial {
    let clock = FeedbackTestClock()
    let configuration = try PersonalTargetFeedbackConfiguration(
        warmupSeconds: 0.01, entryPersistenceSeconds: 0.02, exitPersistenceSeconds: 0.02,
        minimumObservations: 2, cooldownSeconds: 0.04)
    let policy = try PersonalTargetFeedback(
        target: target, configuration: configuration, diagnostics: mode,
        maximumSubscribers: 64, clock: clock.now)
    let fast = try subscribers == 0 ? nil : policy.subscribe(.failOnOverflow(capacity: 1))
    let strict = try subscribers == 0 ? nil : policy.subscribe(.failOnOverflow(capacity: 4))
    let displays = try (0..<max(0, subscribers - 2)).map { _ in
        try policy.subscribe(.newest(capacity: 1))
    }
    var fastIterator = fast?.makeAsyncIterator()
    var fastCount = 0
    if let fast {
        try #require(fast.statistics.buffered == 1)
        try #require(await fastIterator?.next()?.publication == 0)
        fastCount += 1
    }
    var snapshots = [policy.latest]
    var timings: [UInt64] = []
    for input in inputs {
        clock.set(input.interval.sourceEndHostNanoseconds)
        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = try policy.update(input)
        timings.append(DispatchTime.now().uptimeNanoseconds - start)
        snapshots.append(snapshot)
        if let fast {
            // Never await missing data: producer progress and consumption are scripted.
            try #require(fast.statistics.buffered == 1)
            let delivered = try #require(await fastIterator?.next())
            try #require(delivered.value == snapshot && delivered.publication == UInt64(fastCount))
            fastCount += 1
        }
    }
    let last = policy.latest
    let final = policy.finish()
    snapshots.append(final)
    if let fast {
        try #require(fast.statistics.buffered == 1)
        try #require(await fastIterator?.next()?.value == final)
        fastCount += 1
        try #require(await fastIterator?.next() == nil)
        try #require(fast.statistics.coalesced == 0 && fast.statistics.rejected == 0)
    }
    var strictCount = 0
    var errors = 0
    if let strict {
        var iterator = strict.makeAsyncIterator()
        for sequence in 0..<4 {
            try #require(await iterator.next()?.publication == UInt64(sequence))
            strictCount += 1
        }
        do {
            _ = try await iterator.next()
            Issue.record("A stalled observer did not report overflow")
        } catch let error as ResultDeliveryError {
            try #require(error == .overflow(rejectedPublication: 4))
            errors += 1
        }
        try #require(await iterator.next() == nil)
        try #require(strict.statistics.rejected == 1)
    }
    var displayCount = 0
    var coalesced = 0
    var displayHighWater = 0
    for display in displays {
        var iterator = display.makeAsyncIterator()
        let delivered = try #require(await iterator.next())
        try #require(delivered.value == final && delivered.publication == 257)
        try #require(await iterator.next() == nil)
        displayCount += 1
        coalesced += Int(display.statistics.coalesced)
        displayHighWater = max(displayHighWater, display.statistics.highWater)
        try #require(display.statistics.highWater == 1 && display.statistics.rejected == 0)
    }
    try #require(policy.activeSubscriberCount == 0)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try FeedbackTrial(
        rateHz: rate, subscribers: subscribers, trial: trial, mode: mode.rawValue,
        targetSHA256: last.targetIdentity.sha256,
        configurationSHA256: last.configurationIdentity.sha256,
        outputSHA256: CalibrationDigest(bytes: encoder.encode(snapshots)).sha256,
        updateNanoseconds: timings, sourceSamples: last.coverage.sourceSamples,
        qualifiedSamples: last.coverage.qualifiedSummarySamples,
        matchingSamples: last.coverage.matchingSummarySamples,
        acceptedIntervals: last.statistics.acceptedIntervals,
        stateChanges: last.statistics.stateChanges,
        finalState: last.state.rawValue, fastDelivered: fastCount,
        fastHighWater: fast?.statistics.highWater ?? 0,
        strictDelivered: strictCount, strictHighWater: strict?.statistics.highWater ?? 0,
        strictErrors: errors, displayDelivered: displayCount, displayCoalesced: coalesced,
        displayHighWater: displayHighWater, activeAfterFinish: policy.activeSubscriberCount)
}

@Test @MainActor func feedbackPerformanceEvidenceTrials() async throws {
    let target = try feedbackTestTarget()
    var rows: [FeedbackTrial] = []
    var preparations: [FeedbackPreparation] = []
    for rate in [4, 40, 1000] {
        let count = 16000 / rate
        var inputs: [PersonalTargetFeedbackEvidence] = []
        var times: [UInt64] = []
        for index in 0..<256 {
            let start = DispatchTime.now().uptimeNanoseconds
            inputs.append(
                try feedbackTestEvidence(
                    index: index, value: (index / 64).isMultiple(of: 2) ? 10 : 4,
                    count: Int64(count),
                    end: 1_000_000_000 + UInt64(index + 1) * UInt64(1_000_000_000 / rate)))
            times.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        preparations.append(FeedbackPreparation(rateHz: rate, nanoseconds: times))
        for trial in 0..<3 {
            let modes = RuntimeDiagnosticMode.allCases
            for offset in 0..<modes.count {
                let mode = modes[(trial + offset) % modes.count]
                for subscribers in (trial.isMultiple(of: 2) ? [0, 64] : [64, 0]) {
                    rows.append(
                        try await feedbackEvidenceTrial(
                            target: target, inputs: inputs, rate: rate, subscribers: subscribers,
                            mode: mode, trial: trial))
                }
            }
        }
        try #require(Set(rows.filter { $0.rateHz == rate }.map(\.outputSHA256)).count == 1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(FeedbackEvidenceReport(preparations: preparations, trials: rows))
    print("PERSONAL_FEEDBACK_EVIDENCE " + String(decoding: bytes, as: UTF8.self))
}
