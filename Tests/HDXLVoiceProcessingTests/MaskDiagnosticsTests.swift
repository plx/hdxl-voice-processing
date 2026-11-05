import Foundation
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

private final class MaskDiagnosticSink: DiagnosticSink {
    let begins = Mutex<[DiagnosticRecord]>([])
    let ends = Mutex<[DiagnosticRecord]>([])
    let events = Mutex<[DiagnosticRecord]>([])
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
        begins.withLock { $0.append(record) }
        return .recorded
    }
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {
        ends.withLock { $0.append(record) }
    }
    func event(_ record: DiagnosticRecord) -> Bool {
        events.withLock { $0.append(record) }
        return true
    }
    func checkBalanced() {
        let a = begins.withLock { $0 }
        let b = ends.withLock { $0 }
        #expect(a.count == b.count)
        for record in a { #expect(b.filter { $0 == record }.count == 1) }
    }
}

@Test func maskDiagnosticsBalanceSamplingResetAndBorrowedConsumerBoundaries() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let source = try SourceInterval(
        epoch: epoch, startSample: 91, sampleCount: 4000, sampleRate: 16000)
    let pcm = (0..<4000).map { 0.2 * sin(Double($0) * 0.1) }
    var referenceValues: [Double]?
    for mode in DiagnosticMode.allCases {
        var values: [Double] = []
        let sink = MaskDiagnosticSink()
        let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
        let detector = try PreparedLTSFDetector<Double>(
            configuration: LTSFConfiguration(sampleRate: 16000, declaredInputBandwidthHz: 8000),
            source: source, diagnostics: diagnostics)
        let energy = try PreparedEnergyEligibility<Double>(
            configuration: EnergyEligibilityConfiguration(
                sampleRate: 16000, declaredInputBandwidthHz: 8000,
                windowSamples: 160), epoch: epoch, startSample: 91, diagnostics: diagnostics)
        try pcm.withUnsafeBufferPointer { input in
            try detector.append(input, interval: source) { _ in sink.checkBalanced() }
            try energy.process(input, interval: source) { output in
                sink.checkBalanced()
                values.append(output.level.mathematicalDecibels!)
                values.append(output.isEligible == true ? 1 : 0)
            }
        }
        var plan: MaskPlan?
        try detector.finish { output in
            sink.checkBalanced()
            plan = try! output.exportMaskPlan()
            values.append(contentsOf: output.flatness)
            values.append(contentsOf: output.referenceIntensityDB)
            for region in output.speechIntervals {
                values.append(contentsOf: [
                    region.startSeconds, region.endSeconds, region.isSpeech ? 1 : 0,
                ])
            }
        }
        try energy.finish { _ in sink.checkBalanced() }
        let timeline = try MaskTimeline(#require(plan), diagnostics: diagnostics)
        let cursor = PreparedMaskCursor<Double>(
            timeline: timeline, scope: .allEligible, diagnostics: diagnostics)
        _ = try pcm.withUnsafeBufferPointer { input in
            try cursor.process(input, interval: source) { _, _ in sink.checkBalanced() }
        }
        try cursor.resetToStart()
        try detector.reset(source: source)
        _ = try pcm.withUnsafeBufferPointer { try detector.append($0, interval: source) }
        detector.cancel()
        detector.cancel()
        cursor.cancel()
        cursor.cancel()
        try energy.reset(
            for: SourceDiscontinuity(
                previousEpoch: epoch, nextEpoch: epoch.successor(), reason: .explicitReset))
        energy.cancel()
        energy.cancel()
        if let referenceValues {
            #expect(values == referenceValues)
        } else {
            referenceValues = values
        }
        sink.checkBalanced()
        let records = sink.begins.withLock { $0 }
        let events = sink.events.withLock { $0 }
        if mode == .disabled {
            #expect(records.isEmpty && events.isEmpty)
        } else {
            #expect(
                Set(records.map(\.stage)).isSuperset(of: [
                    .analysisFrame, .fft, .speechActivity, .maskIntervals, .energyEligibility,
                    .maskResolution, .maskRouting,
                ]))
            #expect(Set(records.map { $0.metadata.profileToken }) == [34, 3401, 3402, 3403])
            #expect(records.allSatisfy { $0.metadata.sampleCount > 0 })
            #expect(events.filter { $0.stage == .reset }.count == 3)
            #expect(events.filter { $0.stage == .cancelled }.count == 3)
            #expect(records.contains { $0.epoch > 0 })
            if mode == .sampled {
                #expect(records.allSatisfy { $0.metadata.frameSequence % 16 == 0 })
            }
        }
    }
}
