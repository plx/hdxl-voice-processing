import Foundation
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

private final class SWIPEPrimeDiagnosticSink: DiagnosticSink {
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
}

@Test func swipePrimeDiagnosticsSampleWholeStagesAndEndBeforeConsumer() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let pcm = (0..<(c.requiredSampleCount + 19 * c.hopLength)).map {
        0.5 * sin(2 * Double.pi * Double($0) / 6)
    }
    for mode in DiagnosticMode.allCases {
        let sink = SWIPEPrimeDiagnosticSink()
        let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
        let epoch = StreamEpoch(streamID: UUID())
        let origin = try AnalysisTiming(
            source: SourceInterval(epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: 4000),
            includedSampleCount: 0)
        let worker = try PreparedSWIPEPrimeAnalyzer<Double>(
            configuration: c, origin: origin, diagnostics: diagnostics)
        let source = try SourceInterval(
            epoch: epoch, startSample: 0, sampleCount: Int64(pcm.count), sampleRate: 4000)
        var emitted = 0
        func receive(_ output: BorrowedSWIPEPrimeOutput) {
            emitted += 1
            #expect(output.result.profile == worker.identity)
            #expect(sink.begins.withLock { $0.count } == sink.ends.withLock { $0.count })
        }
        _ = try pcm.withUnsafeBufferPointer {
            try worker.process($0, interval: source, emit: receive)
        }
        try worker.finish(emit: receive)
        #expect(emitted == 21)
        let records = sink.begins.withLock { $0 }
        let ends = sink.ends.withLock { $0 }
        #expect(Set(records.map(\.span)).count == records.count)
        for record in records { #expect(ends.filter { $0 == record }.count == 1) }
        if mode == .disabled {
            #expect(records.isEmpty && sink.events.withLock { $0.isEmpty })
        } else {
            let frames = mode == .sampled ? [UInt64(0), 16] : Array(UInt64(0)...20)
            let pitch = records.filter { $0.stage == .pitch }
            #expect(pitch.map(\.metadata.frameSequence) == frames)
            for record in pitch {
                #expect(record.metadata.profileToken == 44)
                let partial = record.metadata.frameSequence == 20
                #expect(
                    record.metadata.sampleCount == UInt32(c.requiredSampleCount - (partial ? 4 : 0))
                )
                #expect(record.metadata.validity == (partial ? .warmup : .available))
            }
            #expect(records.contains { $0.stage == .fft })
        }
        // A reset advances the diagnostics epoch. Cancellation in the next borrow
        // leaves all intervals balanced and emits a single bounded control event.
        let next = try epoch.successor()
        try worker.reset(
            for: SourceDiscontinuity(
                previousEpoch: epoch, nextEpoch: next, reason: .explicitReset))
        let resetSource = try SourceInterval(
            epoch: next, startSample: 0, sampleCount: Int64(pcm.count), sampleRate: 4000)
        _ = try pcm.withUnsafeBufferPointer {
            try worker.process($0, interval: resetSource) { _ in worker.cancel() }
        }
        #expect(sink.begins.withLock { $0.count } == sink.ends.withLock { $0.count })
        if mode != .disabled {
            #expect(sink.events.withLock { $0.filter { $0.stage == .reset }.count } == 1)
            #expect(sink.events.withLock { $0.filter { $0.stage == .cancelled }.count } == 1)
            #expect(sink.begins.withLock { $0.last?.epoch } == 1)
        }
    }
}
