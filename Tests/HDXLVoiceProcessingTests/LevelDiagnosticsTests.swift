import HDXLVoiceProcessing
import Synchronization
import Testing

private final class LevelTestSink: DiagnosticSink {
    let beginnings = Mutex<[DiagnosticRecord]>([])
    let endings = Mutex<[DiagnosticRecord]>([])
    let events = Mutex<[DiagnosticRecord]>([])
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
        beginnings.withLock { $0.append(record) }
        return .recorded
    }
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {
        endings.withLock { $0.append(record) }
    }
    func event(_ record: DiagnosticRecord) -> Bool {
        events.withLock { $0.append(record) }
        return true
    }
}

@Test func levelDiagnosticsBalanceBeforeCallbacksAndUseBoundedWindowScopes() throws {
    for mode in DiagnosticMode.allCases {
        let sink = LevelTestSink()
        let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
        let config = try levelConfiguration(
            window: 8, hop: 4, weighting: .bs1770Revision5(warmupSampleCount: 8))
        let plan = try PreparedLevelAnalyzer<Double>(
            configuration: config, epoch: levelEpoch, diagnostics: diagnostics)
        let input = [Double](repeating: 0.25, count: 80)
        var outputs = 0
        func emit(_ window: LevelWindowResult) {
            outputs += 1
            #expect(sink.beginnings.withLock { $0.count } == sink.endings.withLock { $0.count })
        }
        _ = try input.withUnsafeBufferPointer {
            try plan.process($0, interval: levelInterval(input.count), emit: emit)
        }
        try plan.finish(emit: emit)
        #expect(outputs == 20)
        let begins = sink.beginnings.withLock { $0 }
        let ends = sink.endings.withLock { $0 }
        #expect(begins.count == ends.count)
        #expect(diagnostics.counts.suppressed == (mode == .sampled ? 72 : 0))
        if mode == .disabled {
            #expect(begins.isEmpty)
        } else {
            let frames = mode == .sampled ? [UInt64(0), 16] : Array(UInt64(0)..<20)
            #expect(begins.count == frames.count * 4)
            for frame in frames {
                let records = begins.filter { $0.metadata.frameSequence == frame }
                #expect(
                    records.map(\.stage) == [
                        .analysisFrame, .levelEnergy, .kWeighting, .levelEnergy,
                    ])
                for record in records {
                    #expect(record.metadata.profileToken == 32)
                    #expect(record.metadata.sampleCount == (frame == 19 ? 4 : 8))
                    #expect(
                        record.metadata.validity
                            == (frame < 2 || frame == 19 ? .warmup : .available))
                    #expect(ends.filter { $0 == record }.count == 1)
                }
            }
        }
    }
}

@Test func levelDiagnosticsEndFilterFailureScopesBeforeRecovery() throws {
    let sink = LevelTestSink()
    let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
    let config = try levelConfiguration(window: 8, hop: 8)
    let plan = try PreparedLevelAnalyzer<Double>(
        configuration: config, epoch: levelEpoch, diagnostics: diagnostics)
    #expect(throws: LevelError.nonfiniteResult) {
        try [Double](repeating: .greatestFiniteMagnitude, count: 8).withUnsafeBufferPointer {
            try plan.process($0, interval: levelInterval(8)) { _ in Issue.record("Overflow output")
            }
        }
    }
    #expect(sink.beginnings.withLock { $0.count } == sink.endings.withLock { $0.count })
    #expect(
        sink.events.withLock {
            $0.contains { $0.stage == .error && $0.metadata.validity == .failed }
        })
    try plan.reset(
        for: SourceDiscontinuity(
            previousEpoch: levelEpoch, nextEpoch: levelEpoch.successor(), reason: .explicitReset))
    _ = try [Double](repeating: 0, count: 8).withUnsafeBufferPointer {
        try plan.process($0, interval: levelInterval(8, epoch: plan.epoch)) { _ in }
    }
    #expect(sink.beginnings.withLock { $0.last?.epoch } == 1)
}
