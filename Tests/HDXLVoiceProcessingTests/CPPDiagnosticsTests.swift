import Foundation
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

private final class CPPDiagnosticSink: DiagnosticSink {
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

@Test func cppDiagnosticsBalanceAndFinishBeforeBorrowedConsumer() throws {
    let frame = try PowerCepstrumConfiguration(sampleRate: 4000, pitchFloorHz: 1000)
    let profile = CPPProfile(frame: frame, settings: try CPPConfiguration.murtonRecipePraat7())
    let base = try cepstrumContext(count: frame.frameLength, rate: frame.sampleRate)
    let power = (0..<frame.binCount).map { Double($0 + 1) }
    for mode in DiagnosticMode.allCases {
        let sink = CPPDiagnosticSink()
        let worker = try PreparedCPP(
            profile, diagnostics: WorkerDiagnostics(mode: mode, sink: sink))
        for index in UInt64(0)..<20 {
            let context = try CepstralFrameContext(
                origin: base.origin, timing: base.timing,
                frameIndex: index, firstAnalysisSampleIndex: 0,
                suppliedAnalysisSampleCount: frame.frameLength,
                centerSecondsFromOrigin: base.centerSecondsFromOrigin)
            try power.withUnsafeBufferPointer { input in
                try worker.analyzePowerCepstrum(input, context: context) { output in
                    #expect(output.result.observation != nil)
                    #expect(sink.begins.withLock { $0.count } == sink.ends.withLock { $0.count })
                }
            }
        }
        let begins = sink.begins.withLock { $0 }
        let ends = sink.ends.withLock { $0 }
        if mode == .disabled {
            #expect(begins.isEmpty && ends.isEmpty)
        } else {
            let frames = mode == .sampled ? [UInt64(0), 16] : Array(UInt64(0)..<20)
            #expect(begins.count == 2 * frames.count)
            for index in frames {
                let records = begins.filter { $0.metadata.frameSequence == index }
                #expect(records.map(\.stage) == [.analysisFrame, .cpp])
                for record in records {
                    #expect(record.metadata.profileToken == 35)
                    #expect(record.metadata.sampleCount == UInt32(frame.binCount))
                    #expect(ends.filter { $0 == record }.count == 1)
                }
            }
        }
    }
}
