import Foundation
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

private final class HNRDiagnosticSink: DiagnosticSink {
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
    func clear() {
        begins.withLock { $0.removeAll() }
        ends.withLock { $0.removeAll() }
        events.withLock { $0.removeAll() }
    }
    func checkBalanced() {
        let starts = begins.withLock { $0 }
        let stops = ends.withLock { $0 }
        #expect(starts.count == stops.count)
        #expect(Set(starts.map(\.span)).count == starts.count)
        for start in starts { #expect(stops.filter { $0 == start }.count == 1) }
    }
}

@Test func hnrDiagnosticsSampleCompleteStagesPreserveResultsAndEndBeforeConsumer() throws {
    for method in HNRMethod.allCases {
        let c = try HNRConfiguration(
            method: method, sampleRate: 4000, pitchFloorHz: 100, hopSeconds: 0.01,
            normalization: .causalWindow)
        let pcm = (0..<(c.causalWindowSampleCount + 19 * 40)).map {
            0.4 * sin(2 * Double.pi * 120 * Double($0) / 4000)
                + 0.05 * cos(2 * Double.pi * 311 * Double($0) / 4000)
        }
        let epoch = StreamEpoch(streamID: UUID())
        let source = try SourceInterval(
            epoch: epoch, startSample: 0, sampleCount: Int64(pcm.count), sampleRate: 4000)
        let origin = try AnalysisTiming(
            source: SourceInterval(epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: 4000),
            includedSampleCount: 0)
        var baseline: [HNRAnalysisResult]?
        for mode in DiagnosticMode.allCases {
            let sink = HNRDiagnosticSink()
            let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
            let worker = try PreparedHNRStream<Double>(
                configuration: c, origin: origin, diagnostics: diagnostics)
            sink.clear()
            var results: [HNRAnalysisResult] = []
            func consume(_ output: BorrowedHNRStreamingOutput) {
                sink.checkBalanced()
                results.append(output.frame.result)
            }
            try pcm.withUnsafeBufferPointer {
                _ = try worker.process($0, interval: source, emit: consume)
            }
            try worker.finish(emit: consume)
            #expect(results.count == 21)
            if let baseline { #expect(results == baseline) } else { baseline = results }
            let records = sink.begins.withLock { $0 }
            let frames =
                mode == .disabled ? [] : mode == .sampled ? [UInt64(0), 16] : Array(UInt64(0)..<20)
            for stage in [
                DiagnosticStage.hnrNormalization, .analysisFrame, .hnr, .hnrWindow,
                .hnrCorrelation, .hnrPeriodSearch,
            ] {
                let selected = records.filter { $0.stage == stage }
                #expect(selected.map(\.metadata.frameSequence) == frames)
                #expect(selected.allSatisfy { $0.metadata.profileToken == 39 })
            }
            if mode == .disabled {
                #expect(records.isEmpty && sink.events.withLock { $0.isEmpty })
            } else {
                #expect(records.contains { $0.stage == .fft })
            }
            let next = try epoch.successor()
            try worker.reset(
                for: SourceDiscontinuity(
                    previousEpoch: epoch, nextEpoch: next, reason: .explicitReset))
            let nextSource = try SourceInterval(
                epoch: next, startSample: 0, sampleCount: Int64(pcm.count), sampleRate: 4000)
            try pcm.withUnsafeBufferPointer {
                _ = try worker.process($0, interval: nextSource) { _ in
                    sink.checkBalanced()
                    worker.cancel()
                }
            }
            sink.checkBalanced()
            if mode != .disabled {
                #expect(sink.events.withLock { $0.filter { $0.stage == .reset }.count } == 1)
                #expect(sink.events.withLock { $0.filter { $0.stage == .cancelled }.count } == 1)
                #expect(sink.begins.withLock { $0.last?.epoch } == 1)
            }
        }
    }
}

@Test func hnrDiagnosticsWholeNormalizationOnceAndSilentFramesSkipCorrelation() throws {
    let c = try HNRConfiguration(method: .autocorrelation, sampleRate: 4000, pitchFloorHz: 100)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 0, sampleCount: 1600, sampleRate: 4000)
    let timing = try AnalysisTiming(source: source, includedSampleCount: 1600)
    let sink = HNRDiagnosticSink()
    let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
    let worker = try PreparedIntervalHNR<Double>(
        configuration: c, timing: timing, diagnostics: diagnostics)
    sink.clear()
    try Array(repeating: 0.0, count: 1600).withUnsafeBufferPointer {
        try worker.append($0, interval: source)
    }
    let completion = try worker.finish { _ in sink.checkBalanced() }
    #expect(completion.availableFrameCount == 0)
    let records = sink.begins.withLock { $0 }
    #expect(records.filter { $0.stage == .hnrNormalization }.count == 1)
    #expect(records.filter { $0.stage == .hnrNormalization }.first?.metadata.sampleCount == 1600)
    #expect(records.filter { $0.stage == .hnrWindow }.count == worker.layout.frameCount)
    #expect(!records.contains { [.hnrCorrelation, .hnrPeriodSearch, .fft].contains($0.stage) })
    try worker.reset(timing: timing)
    worker.cancel()
    worker.cancel()
    #expect(sink.events.withLock { $0.filter { $0.stage == .reset }.count } == 1)
    #expect(sink.events.withLock { $0.filter { $0.stage == .cancelled }.count } == 1)

    // The amplitude-reference mismatch fails inside window preparation. Every
    // admitted scope still ends and no consumer or later stage executes.
    let frame = try worker.layout.frame(at: 0)
    let direct = try PreparedHNR<Double>(c, diagnostics: diagnostics)
    let normalization = try Array(repeating: 0.0, count: 1600).withUnsafeBufferPointer {
        try HNRNormalization($0, timing: timing, definition: .wholeInterval)
    }
    sink.clear()
    #expect(throws: HNRError.unexpectedContext) {
        try Array(repeating: 1.0, count: frame.support.count).withUnsafeBufferPointer {
            try direct.analyze($0, layout: frame, normalization: normalization) { _ in
                Issue.record("Failed normalization must not emit")
            }
        }
    }
    sink.checkBalanced()
    #expect(sink.begins.withLock { $0.map(\.stage) } == [.analysisFrame, .hnr, .hnrWindow])
}
