import Foundation
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

private final class CepstralDiagnosticSink: DiagnosticSink {
    let begins = Mutex<[DiagnosticRecord]>([])
    let ends = Mutex<[DiagnosticRecord]>([])
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
        begins.withLock { $0.append(record) }
        return .recorded
    }
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {
        ends.withLock { $0.append(record) }
    }
    func event(_ record: DiagnosticRecord) -> Bool { true }
}

@Test func cepstralDiagnosticsSampleWholeKernelsAndBalanceBeforeConsumers() throws {
    for mode in DiagnosticMode.allCases {
        let sink = CepstralDiagnosticSink()
        let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
        let configuration = try PowerCepstrumConfiguration(sampleRate: 4000, pitchFloorHz: 1000)
        let worker = try PreparedPowerCepstrum(configuration, diagnostics: diagnostics)
        let context = try cepstrumContext(count: configuration.frameLength)
        let signal = (0..<configuration.frameLength).map { sin(Double($0) * 0.73) * 0.25 }
        for frame in UInt64(0)..<20 {
            let indexed = try CepstralFrameContext(
                origin: context.origin, timing: context.timing,
                frameIndex: frame, firstAnalysisSampleIndex: 0,
                suppliedAnalysisSampleCount: signal.count,
                centerSecondsFromOrigin: context.centerSecondsFromOrigin)
            try signal.withUnsafeBufferPointer { input in
                try worker.analyze(input, context: indexed) { output in
                    #expect(output.unavailability == nil)
                    #expect(sink.begins.withLock { $0.count } == sink.ends.withLock { $0.count })
                }
            }
        }
        let begins = sink.begins.withLock { $0 }
        let ends = sink.ends.withLock { $0 }
        if mode == .disabled {
            #expect(begins.isEmpty && ends.isEmpty)
        } else {
            let expected = mode == .sampled ? [UInt64(0), 16] : Array(UInt64(0)..<20)
            #expect(begins.count == expected.count * 4)
            for frame in expected {
                let records = begins.filter { $0.metadata.frameSequence == frame }
                #expect(records.map(\.stage) == [.analysisFrame, .cepstrum, .fft, .fft])
                for record in records {
                    #expect(record.metadata.profileToken == 33)
                    #expect(record.metadata.sampleCount == UInt32(signal.count))
                    #expect(ends.filter { $0 == record }.count == 1)
                }
            }
        }
    }
}
