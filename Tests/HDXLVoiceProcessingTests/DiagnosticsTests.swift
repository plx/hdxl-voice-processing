import Foundation
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

final class RecordingSink: DiagnosticSink {
    enum Entry: Equatable, Sendable {
        case begin(DiagnosticRecord)
        case end(DiagnosticRecord)
        case event(DiagnosticRecord)
    }
    private struct Storage {
        var entries: [Entry] = []
        var reservedEnds = 0
    }
    private let storage = Mutex<Storage>(Storage())
    var entries: [Entry] { storage.withLock { $0.entries } }
    // Test-only sink with a fixed bound. Reserve enough room for any outstanding ends.
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
        storage.withLock {
            guard $0.entries.count + $0.reservedEnds + 2 <= 10_000 else { return nil }
            $0.entries.append(.begin(record))
            $0.reservedEnds += 1
            return .recorded
        }
    }
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {
        storage.withLock {
            $0.entries.append(.end(record))
            $0.reservedEnds -= 1
        }
    }
    func event(_ record: DiagnosticRecord) -> Bool {
        storage.withLock {
            guard $0.entries.count + $0.reservedEnds + 1 <= 10_000 else { return false }
            $0.entries.append(.event(record))
            return true
        }
    }
}

private enum SyntheticError: Error { case expected }

@Test func framingDiagnosticsBoundAssemblyScopesAndPreserveFrames() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let config = try FramingConfiguration(
        window: WindowSpecification(definition: .rectangular, sampleCount: 4, sampleRate: 16_000),
        hopLength: 2, partialWindowPolicy: .emitUnavailable)
    let samples = Array(0..<8).map(Double.init)
    for mode in DiagnosticMode.allCases {
        let sink = RecordingSink()
        let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
        let framer = try PCMFramer<Double>(
            configuration: config, epoch: epoch, diagnostics: diagnostics)
        var output: [[Double]] = []
        func emit(_ buffer: UnsafeBufferPointer<Double>, _ support: PCMFrameSupport) {
            output.append(Array(buffer))
            if mode == .detailed {
                guard case .end(let record) = sink.entries.last else {
                    Issue.record("Consumer ran inside a diagnostic assembly interval")
                    return
                }
                #expect(record.stage == .analysisFrame)
                #expect(record.metadata.sampleCount == UInt32(buffer.count))
                #expect(
                    record.metadata.validity
                        == (support.unavailability == nil ? .available : .warmup))
            }
        }
        _ = try samples.withUnsafeBufferPointer {
            try framer.process(
                $0,
                interval: SourceInterval(
                    epoch: epoch, startSample: 0, sampleCount: 8, sampleRate: 16_000), emit: emit)
        }
        try framer.finish(emit: emit)
        #expect(output == [[0, 1, 2, 3], [2, 3, 4, 5], [4, 5, 6, 7], [6, 7]])
        #expect(diagnostics.counts.intervals == (mode == .disabled ? 0 : mode == .sampled ? 2 : 8))
        framer.cancel()
    }
}

@Test func diagnosticScopesBalanceAcrossResetReturnErrorAndCancellation() throws {
    let sink = RecordingSink()
    let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
    var metadata = DiagnosticMetadata()
    metadata.sampleCount = 128
    metadata.profileToken = 4
    let returned = diagnostics.withFrame(metadata) {
        diagnostics.withInterval(.fft) {
            diagnostics.reset()
            return 42
        }
    }
    #expect(returned == 42)
    #expect(throws: SyntheticError.self) {
        try diagnostics.withFrame(metadata) {
            try diagnostics.withInterval(.cepstrum) { throw SyntheticError.expected }
        }
    }
    #expect(throws: CancellationError.self) {
        try diagnostics.withFrame(metadata) {
            try diagnostics.withInterval(.pitch) { throw CancellationError() }
        }
    }
    var open: [UInt64: DiagnosticRecord] = [:]
    var epochs: Set<UInt64> = []
    for entry in sink.entries {
        switch entry {
        case .begin(let record):
            #expect(open.updateValue(record, forKey: record.span) == nil)
            epochs.insert(record.epoch)
        case .end(let record):
            #expect(open.removeValue(forKey: record.span) == record)
        case .event: break
        }
    }
    #expect(open.isEmpty)
    #expect(epochs == [0, 1])
    #expect(diagnostics.counts.intervals == 6)
}

@Test func concurrentDiagnosticSessionsHaveIndependentIdentities() async {
    let sink = RecordingSink()
    let sessions = await withTaskGroup(of: UInt64.self) { group in
        for _ in 0..<16 {
            group.addTask {
                let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
                diagnostics.withFrame(DiagnosticMetadata()) {
                    diagnostics.withInterval(.fft) { diagnostics.event(.overrun) }
                }
                return diagnostics.session
            }
        }
        var identities: Set<UInt64> = []
        for await session in group { identities.insert(session) }
        return identities
    }
    #expect(sessions.count == 16)
    #expect(!sessions.contains(0))
    var begins: Set<String> = []
    var ends: Set<String> = []
    for entry in sink.entries {
        switch entry {
        case .begin(let record): begins.insert("\(record.session):\(record.span)")
        case .end(let record): ends.insert("\(record.session):\(record.span)")
        case .event: break
        }
    }
    #expect(begins == ends)
    #expect(begins.count == 32)
}

@Test func diagnosticModesPreserveOutputAndSampleWholeFrames() {
    var outputs: [UInt64] = []
    for mode in DiagnosticMode.allCases {
        let sink = RecordingSink()
        let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
        var total: UInt64 = 0
        for index in 0..<64 {
            var metadata = DiagnosticMetadata()
            metadata.frameSequence = UInt64(index)
            total += diagnostics.withFrame(metadata) {
                diagnostics.withInterval(.fft) {
                    diagnostics.event(.dequeue)
                    return UInt64(index * 7 + 1)
                }
            }
        }
        outputs.append(total)
        let begins = sink.entries.compactMap { entry -> DiagnosticRecord? in
            guard case .begin(let record) = entry else { return nil }
            return record
        }
        switch mode {
        case .disabled: #expect(sink.entries.isEmpty)
        case .sampled:
            #expect(begins.count == 8)
            #expect(begins.allSatisfy { $0.metadata.frameSequence % 16 == 0 })
        case .detailed: #expect(begins.count == 128)
        }
    }
    #expect(Set(outputs).count == 1)
}

@Test func diagnosticBudgetsBoundEventsAndNestingWithoutSkippingWork() {
    let sink = RecordingSink()
    let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
    var executed = 0
    func nested(_ depth: Int) {
        diagnostics.withInterval(.fft) {
            executed += 1
            if depth > 0 { nested(depth - 1) }
        }
    }
    diagnostics.withFrame(DiagnosticMetadata()) {
        nested(20)
        for _ in 0..<1_000 { diagnostics.event(.overrun) }
        diagnostics.withFrame(DiagnosticMetadata()) { executed += 1 }
    }
    #expect(executed == 22)
    #expect(diagnostics.counts.intervals == 8)
    // Includes initialization.
    #expect(diagnostics.counts.intervals + diagnostics.counts.events == 65)
    #expect(diagnostics.counts.suppressed > 900)
    let beginCount = sink.entries.filter { if case .begin = $0 { true } else { false } }.count
    let endCount = sink.entries.filter { if case .end = $0 { true } else { false } }.count
    #expect(beginCount == endCount)
    // No frame entry means a control-event storm cannot refresh the budget.
    let before = diagnostics.counts.events
    for _ in 0..<100 { diagnostics.reset() }
    #expect(diagnostics.counts.events == before)
}

@Test func captureDiagnosticsUseCallerTimestampsAndSaturatingCounts() {
    var counters = CaptureDiagnostics()
    #expect(MemoryLayout<CaptureDiagnostics>.size == 28)
    #expect(MemoryLayout<CaptureDiagnostics>.stride == 32)
    counters.record(frames: 256, hostTimestamp: 100, dropped: false)
    counters.record(frames: 512, hostTimestamp: 200, dropped: true)
    #expect(counters.callbacks == 2)
    #expect(counters.droppedFrames == 512)
    #expect(counters.largestBlock == 512)
    #expect(counters.lastHostTimestamp == 200)
    #expect(saturatingAdd(.max) == .max)
    #expect(saturatingAdd(.max - 3, 4) == .max)
    #expect(saturatingAdd(10, 4) == 14)
}

@Test func cooperativeTaskCancellationClosesWorkerScopes() async {
    let sink = RecordingSink()
    let task = Task {
        // Observe cancellation before entering a synchronous worker turn.
        while !Task.isCancelled { await Task.yield() }
        let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
        do {
            try diagnostics.withFrame(DiagnosticMetadata()) {
                try diagnostics.withInterval(.fft) { try Task.checkCancellation() }
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // The scope defers have already paired both intervals.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
    task.cancel()
    await task.value
    let begins = sink.entries.compactMap { entry -> DiagnosticRecord? in
        if case .begin(let record) = entry { record } else { nil }
    }
    let ends = sink.entries.compactMap { entry -> DiagnosticRecord? in
        if case .end(let record) = entry { record } else { nil }
    }
    #expect(begins.count == 2)
    #expect(begins == ends.reversed())
}
