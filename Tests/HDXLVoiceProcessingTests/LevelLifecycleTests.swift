import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func levelFinishDistinguishesEmptyCompleteAndIncompleteGrids() throws {
    for hop in [1, 3, 8] {
        for count in [0, 1, 7, 8, 9, 16, 23] {
            for policy in [PartialWindowPolicy.discard, .emitUnavailable] {
                let config = try levelConfiguration(
                    window: 8, hop: hop, weighting: .none, partial: policy)
                let input = (0..<count).map { Double($0) / 10 }
                let origin = Int64.max - Int64(count)
                let captured = try captureLevels(
                    input, configuration: config, chunks: [1, 5, 2], origin: origin)
                let complete = count < 8 ? 0 : (count - 8) / hop + 1
                let tailCount = count - complete * hop
                let hasTail = tailCount > 0
                let emitsTail = hasTail && policy == .emitUnavailable
                #expect(captured.completion.completeWindowCount == UInt64(complete))
                #expect(captured.windows.count == complete + (emitsTail ? 1 : 0))
                let disposition: LevelEndDisposition =
                    count == 0
                    ? .empty
                    : hasTail ? (emitsTail ? .unavailablePartial : .discardedPartial) : .complete
                #expect(captured.completion.disposition == disposition)
                #expect(captured.completion.observedSource.endSample == Int64.max)
                if emitsTail {
                    let tail = try #require(captured.windows.last)
                    #expect(tail.source == captured.completion.tailSource)
                    #expect(tail.source.sampleCount == Int64(tailCount))
                    #expect(tail.missingSampleCount == 8 - tailCount)
                    #expect(tail.unweighted == .unavailable(.insufficientData))
                    #expect(tail.input.finitePeakMagnitude == input.last)
                    #expect(tail.unweightedTiming.includedSampleCount == Int64(tailCount))
                }
                for (i, window) in captured.windows.enumerated() {
                    #expect(window.frameIndex == UInt64(i))
                    #expect(window.source.startSample == origin + Int64(i * hop))
                    #expect(window.source.endSample <= Int64.max)
                    #expect(
                        window.unweightedTiming.effectiveDelaySeconds == Double(
                            window.source.sampleCount) / 96_000)
                }
            }
        }
    }
    #expect(throws: ContractError.invalidConfiguration) {
        try levelConfiguration(window: 8, hop: 9)
    }
}

@Test func levelInputRejectionIsAtomicAndDiagnosticsRetainNonfiniteCounts() throws {
    let config = try levelConfiguration(window: 8, hop: 8)
    let plan = try PreparedLevelAnalyzer<Double>(configuration: config, epoch: levelEpoch)
    let first = [0.2, -0.3, 1.0]
    _ = try first.withUnsafeBufferPointer {
        try plan.process($0, interval: levelInterval(3)) { _ in Issue.record("Early window") }
    }
    let invalid = [0.4, 2.0, Double.nan, .infinity, -.infinity, -1.0, Double.leastNonzeroMagnitude]
    let inspection = try invalid.withUnsafeBufferPointer { try LevelInputDiagnostics.inspect($0) }
    #expect(inspection.status == .nonfinite && inspection.nonfiniteSampleCount == 3)
    #expect(
        inspection.nanSampleCount == 1 && inspection.positiveInfinitySampleCount == 1
            && inspection.negativeInfinitySampleCount == 1)
    #expect(inspection.atFullScaleSampleCount == 1 && inspection.overFullScaleSampleCount == 1)
    #expect(inspection.subnormalSampleCount == 1 && inspection.finitePeakMagnitude == 2)
    #expect(LevelError.nonfiniteInput(inspection).unavailability == .invalidInput)
    #expect(throws: LevelError.nonfiniteInput(inspection)) {
        try invalid.withUnsafeBufferPointer {
            try plan.process($0, interval: levelInterval(invalid.count, start: 3)) { _ in
                Issue.record("Invalid output")
            }
        }
    }
    #expect(plan.nextInputSample == 3)
    let rest = [0.1, 0.2, 0.3, 0.4, 0.5]
    for interval in [
        try levelInterval(5, start: 4), try levelInterval(4, start: 3),
        try levelInterval(5, start: 3, rate: 44_100),
        try levelInterval(5, start: 3, epoch: levelEpoch.successor()),
    ] {
        #expect(throws: LevelError.unexpectedInterval) {
            try rest.withUnsafeBufferPointer {
                try plan.process($0, interval: interval) { _ in
                    Issue.record("Invalid metadata output")
                }
            }
        }
        #expect(plan.nextInputSample == 3)
    }
    var actual: LevelWindowResult?
    _ = try rest.withUnsafeBufferPointer {
        try plan.process($0, interval: levelInterval(5, start: 3)) { actual = $0 }
    }
    let expected = try #require(captureLevels(first + rest, configuration: config).windows.first)
    #expect(actual == expected)
    let empty = try [Double]().withUnsafeBufferPointer { try LevelInputDiagnostics.inspect($0) }
    #expect(empty.status == .empty && !empty.isSilent && empty.finitePeakMagnitude == nil)
    let allInvalid = try [Double.nan, .infinity].withUnsafeBufferPointer {
        try LevelInputDiagnostics.inspect($0)
    }
    #expect(allInvalid.finitePeakMagnitude == nil && allInvalid.finiteSampleCount == 0)
}

@Test func levelWarmupResetAndReconfigurationKeepIndependentSourceClocks() throws {
    let config = try levelConfiguration(
        window: 8, hop: 4, weighting: .bs1770Revision5(warmupSampleCount: 8))
    let input = (0..<24).map { sin(Double($0)) * 0.4 }
    let initial = try captureLevels(input, configuration: config)
    #expect(initial.windows[0].weighted == .unavailable(.insufficientData))
    #expect(initial.windows[1].weighted == .unavailable(.insufficientData))
    #expect(initial.windows[2].weighted?.energy != nil)
    #expect(initial.windows[0].unweighted.energy != nil)
    #expect(initial.windows[0].weightedTiming?.includedSampleCount == 0)
    #expect(initial.windows[2].weightedTiming?.includedSampleCount == 8)
    #expect(initial.windows[0].warmupSamplesRemainingAtWindowStart == 8)
    #expect(initial.windows[1].warmupSamplesRemainingAtWindowStart == 4)
    let plan = try PreparedLevelAnalyzer<Double>(configuration: config, epoch: levelEpoch)
    _ = try input.withUnsafeBufferPointer {
        try plan.process($0, interval: levelInterval(input.count)) { _ in }
    }
    let bytes = plan.executionStatistics.preparedBufferBytes
    let successor = try levelEpoch.successor()
    let missing = try levelInterval(12, start: 24)
    try plan.reset(
        for: SourceDiscontinuity(
            previousEpoch: levelEpoch, nextEpoch: successor,
            reason: .droppedAudio, missingSource: missing))
    #expect(plan.executionStatistics.preparedBufferBytes == bytes)
    #expect(plan.executionStatistics.unweightedRebaseCount == 0 && plan.nextInputSample == 0)
    var after: [LevelWindowResult] = []
    _ = try input.withUnsafeBufferPointer {
        try plan.process($0, interval: levelInterval(input.count, epoch: successor)) {
            after.append($0)
        }
    }
    try plan.finish { after.append($0) }
    for (a, b) in zip(after, initial.windows) {
        #expect(a.unweighted == b.unweighted && a.weighted == b.weighted)
        #expect(a.source.epoch == successor && a.source.startSample == b.source.startSample)
        #expect(a.filterHistorySource?.epoch == successor)
    }
    let nextConfig = try levelConfiguration(rate: 16_000, window: 16, hop: 8)
    let previousIdentity = plan.identity
    #expect(throws: LevelError.precisionMismatch) {
        try plan.reconfigure(
            to: levelConfiguration(precision: .float32), epoch: successor.successor())
    }
    #expect(plan.identity == previousIdentity && plan.configuration == config)
    try plan.reconfigure(to: nextConfig, epoch: successor.successor())
    #expect(plan.identity != previousIdentity && plan.nextInputSample == 0)
    var restarted: [LevelWindowResult] = []
    _ = try input.withUnsafeBufferPointer {
        try plan.process($0, interval: levelInterval(input.count, rate: 16_000, epoch: plan.epoch))
        { restarted.append($0) }
    }
    let fresh = try captureLevels(input, configuration: nextConfig)
    #expect(restarted[0].weighted == fresh.windows[0].weighted)
}

@Test func levelCancellationAndReentrancyHaveDefinedConsumption() throws {
    let config = try levelConfiguration(window: 8, hop: 4)
    let plan = try PreparedLevelAnalyzer<Double>(configuration: config, epoch: levelEpoch)
    let input = [Double](repeating: 0.25, count: 32)
    let report = try input.withUnsafeBufferPointer { buffer in
        try plan.process(buffer, interval: levelInterval(input.count)) { window in
            #expect(window.source.sampleCount == 8)
            #expect(throws: LevelError.reentrantCall) { try plan.finish { _ in } }
            #expect(throws: LevelError.reentrantCall) {
                try plan.process(buffer, interval: levelInterval(input.count)) { _ in }
            }
            #expect(throws: LevelError.reentrantCall) {
                try plan.reconfigure(to: config, epoch: levelEpoch.successor())
            }
            plan.cancel()
        }
    }
    #expect(report.consumedSampleCount == 8 && report.emittedWindowCount == 1 && report.isCancelled)
    #expect(plan.nextInputSample == 8 && plan.executionStatistics.preparedBufferBytes == 0)
    plan.cancel()
    #expect(throws: LevelError.invalidState) { try plan.finish { _ in } }
    try plan.reset(
        for: SourceDiscontinuity(
            previousEpoch: levelEpoch, nextEpoch: levelEpoch.successor(), reason: .explicitReset))
    #expect(plan.executionStatistics.preparedBufferBytes > 0)
    _ = try [0.2, 0.3].withUnsafeBufferPointer {
        try plan.process($0, interval: levelInterval(2, epoch: plan.epoch)) { _ in
            Issue.record("Early output")
        }
    }
    let completion = try plan.finish { _ in plan.cancel() }
    #expect(completion.isCancelled && completion.disposition == .unavailablePartial)
    #expect(throws: LevelError.invalidState) { try plan.finish { _ in } }
}

@Test func levelSubnormalAndOverflowPoliciesPreserveHonestAvailability() throws {
    let config = try levelConfiguration(window: 8, hop: 8)
    let smallest = [Double](repeating: .leastNonzeroMagnitude, count: 16)
    let result = try captureLevels(smallest, configuration: config)
    for window in result.windows {
        #expect(window.input.subnormalSampleCount == 8)
        #expect(window.unweighted.digitalLevel.status == .finite)
        #expect(window.unweighted.meanSquare == .unavailable(.unsupportedRange))
        #expect(
            window.weighted == .unavailable(.unsupportedRange) && window.weightedPrecisionLimited)
    }
    let floatConfig = try levelConfiguration(precision: .float32, window: 8, hop: 8)
    let floatInput = [Float](repeating: .leastNonzeroMagnitude, count: 16)
    let promoted = try captureLevels(floatInput, configuration: floatConfig)
    #expect(
        promoted.windows.allSatisfy { $0.weighted?.energy != nil && !$0.weightedPrecisionLimited })
    #expect(promoted.windows.allSatisfy { $0.input.subnormalSampleCount == 8 })
    let sticky = try captureLevels(
        smallest + [Double](repeating: 0.2, count: 16), configuration: config)
    #expect(sticky.windows.last?.weighted == .unavailable(.unsupportedRange))
    let plan = try PreparedLevelAnalyzer<Double>(configuration: config, epoch: levelEpoch)
    let huge = [Double](repeating: .greatestFiniteMagnitude, count: 8)
    #expect(throws: LevelError.nonfiniteResult) {
        try huge.withUnsafeBufferPointer {
            try plan.process($0, interval: levelInterval(8)) { _ in Issue.record("Overflow output")
            }
        }
    }
    #expect(throws: LevelError.invalidState) { try plan.finish { _ in } }
    try plan.reset(
        for: SourceDiscontinuity(
            previousEpoch: levelEpoch, nextEpoch: levelEpoch.successor(), reason: .explicitReset))
    var recovered: LevelWindowResult?
    _ = try [Double](repeating: 0.0, count: 8).withUnsafeBufferPointer {
        try plan.process($0, interval: levelInterval(8, epoch: plan.epoch)) { recovered = $0 }
    }
    #expect(recovered?.weighted?.energy == .zero && recovered?.weightedPrecisionLimited == false)
    let unweighted = try captureLevels(
        huge, configuration: levelConfiguration(window: 8, hop: 8, weighting: .none))
    #expect(unweighted.windows[0].unweighted.rms.estimate?.value == .greatestFiniteMagnitude)
}
