import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func energyGateConfiguration() throws -> EnergyEligibilityConfiguration {
    try EnergyEligibilityConfiguration(
        sampleRate: 16_000, declaredInputBandwidthHz: 8000, windowSamples: 16,
        activationDBFS: -20, deactivationDBFS: -40, activationConfirmationWindows: 2,
        deactivationConfirmationWindows: 3)
}

@Test func energyEligibilityUsesExplicitHysteresisAndConsecutiveConfirmation() throws {
    let c = try energyGateConfiguration()
    let epoch = StreamEpoch(streamID: UUID())
    // Window amplitudes have exact digital RMS; a middle-level window breaks
    // activation confirmation but preserves an already active state.
    let amplitudes = [0.0, 1, 0.05, 1, 1, 0.05, 0, 0, 1, 0, 0, 0]
    let expected = [false, false, false, false, true, true, true, true, true, true, true, false]
    let samples = amplitudes.flatMap { Array(repeating: $0, count: 16) } + [0.2, 0.2, 0.2]
    var baseline: [EnergyEligibilityFrame]?
    for chunk in [1, 7, 64, 1024] {
        let worker = try PreparedEnergyEligibility<Double>(
            configuration: c, epoch: epoch, startSample: 10)
        var output: [EnergyEligibilityFrame] = []
        try samples.withUnsafeBufferPointer { pcm in
            for start in stride(from: 0, to: pcm.count, by: chunk) {
                let end = min(pcm.count, start + chunk)
                let interval = try SourceInterval(
                    epoch: epoch, startSample: 10 + Int64(start),
                    sampleCount: Int64(end - start), sampleRate: 16_000)
                try worker.process(
                    UnsafeBufferPointer(rebasing: pcm[start..<end]), interval: interval
                ) { output.append($0) }
            }
        }
        let completion = try worker.finish { output.append($0) }
        #expect(completion.completeWindowCount == 12)
        #expect(completion.unavailableTailSamples == 3)
        #expect(output.dropLast().map(\.isEligible) == expected.map(Optional.some))
        #expect(output.last?.isEligible == nil)
        #expect(output.last?.level == .unavailable(.insufficientData))
        #expect(output.first?.level == .zeroEnergy)
        #expect(output[1].level.finiteDecibels == 0)
        #expect(output[4].changedState)
        #expect(output[11].changedState)
        #expect(output.allSatisfy { $0.effectiveDelaySeconds == 0.001 })
        if let baseline { #expect(output == baseline) } else { baseline = output }
        #expect(try worker.finish { _ in Issue.record("Repeated finish emitted") } == completion)
        let plan = try MaskPlan(
            source: completion.source, provenances: [worker.provenance],
            policy: MaskSelectionPolicy(selectionSources: [0]),
            observations: output.map { try $0.observation(provenanceIndex: 0) },
            effectiveDelaySeconds: c.effectiveDelaySeconds)
        let coverage = try MaskTimeline(plan).coverage
        #expect(coverage.selectedSampleCount == 7 * 16)
        #expect(coverage.eligibleSampleCount == 195)
        #expect(coverage.tags.first { $0.tag == .algorithmInsufficiency }?.sampleCount == 3)
    }
}

@Test func energyEligibilityResetDiscardsPartialHistoryAndPendingConfirmation() throws {
    let c = try energyGateConfiguration()
    let epoch = StreamEpoch(streamID: UUID())
    let worker = try PreparedEnergyEligibility<Double>(configuration: c, epoch: epoch)
    _ = try Array(repeating: 1.0, count: 20).withUnsafeBufferPointer {
        try worker.process(
            $0,
            interval: SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: 20, sampleRate: 16_000)
        ) { _ in }
    }
    #expect(worker.pendingConfirmationWindows == 1)
    let missing = try SourceInterval(
        epoch: epoch, startSample: 20, sampleCount: 30, sampleRate: 16_000)
    let next = try epoch.successor()
    try worker.reset(
        for: SourceDiscontinuity(
            previousEpoch: epoch, nextEpoch: next, reason: .droppedAudio, missingSource: missing))
    #expect(worker.nextInputSample == 0)
    #expect(!worker.isEligible)
    #expect(worker.pendingConfirmationWindows == 0)
    var frames: [EnergyEligibilityFrame] = []
    _ = try Array(repeating: 1.0, count: 32).withUnsafeBufferPointer {
        try worker.process(
            $0,
            interval: SourceInterval(
                epoch: next, startSample: 0, sampleCount: 32, sampleRate: 16_000)
        ) { frames.append($0) }
    }
    #expect(frames.map(\.isEligible) == [false, true])
    #expect(frames.map(\.source.startSample) == [0, 16])
    #expect(frames.allSatisfy { $0.source.epoch == next })
}

@Test func energyEligibilityValidatesAtomicallyAndCancellationStopsAtCurrentWindow() throws {
    let c = try energyGateConfiguration()
    let epoch = StreamEpoch(streamID: UUID())
    let worker = try PreparedEnergyEligibility<Double>(configuration: c, epoch: epoch)
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 32, sampleRate: 16_000)
    var invalid = Array(repeating: 1.0, count: 32)
    invalid[31] = .nan
    #expect(throws: MaskError.nonfiniteInput) {
        try invalid.withUnsafeBufferPointer {
            try worker.process($0, interval: source) { _ in Issue.record("Nonfinite chunk emitted")
            }
        }
    }
    #expect(worker.nextInputSample == 0)
    _ = try Array(repeating: Double.greatestFiniteMagnitude, count: 32).withUnsafeBufferPointer {
        let report = try worker.process($0, interval: source) { frame in
            #expect(frame.level.status == .finite)
            #expect(frame.isEligible == false)
            #expect(throws: MaskError.reentrantCall) { try worker.finish { _ in } }
            worker.cancel()
        }
        #expect(report.consumedSampleCount == 16)
        #expect(report.isCancelled)
    }
    #expect(throws: MaskError.invalidState) { try worker.finish { _ in } }
    let bytes = try JSONEncoder().encode(c)
    #expect(try JSONDecoder().decode(EnergyEligibilityConfiguration.self, from: bytes) == c)
    #expect(throws: MaskError.invalidConfiguration) {
        try EnergyEligibilityConfiguration(
            sampleRate: 16_000, declaredInputBandwidthHz: 8000,
            windowSamples: 16, activationDBFS: -40, deactivationDBFS: -20)
    }
}
