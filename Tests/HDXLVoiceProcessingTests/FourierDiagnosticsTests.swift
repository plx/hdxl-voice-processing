import HDXLVoiceProcessing
import Synchronization
import Testing

private final class FourierSink: DiagnosticSink {
    let beginnings = Mutex<[DiagnosticRecord]>([])
    let endings = Mutex<[DiagnosticRecord]>([])
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
        beginnings.withLock { $0.append(record) }
        return .recorded
    }
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {
        endings.withLock { $0.append(record) }
    }
    func event(_ record: DiagnosticRecord) -> Bool { true }
}

@Test func fourierDiagnosticsReuseTheWorkersFrameAndBalanceKernelIntervals() throws {
    let sink = FourierSink()
    let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
    let plan = try PreparedFourierTransform<Double>(
        FourierConfiguration(length: 8, sampleRate: 48_000), diagnostics: diagnostics)
    var metadata = DiagnosticMetadata()
    metadata.profileToken = 30
    metadata.frameSequence = 17
    metadata.sampleCount = 8
    var bins = Array(repeating: FourierBin<Double>(real: 0), count: 5)
    var output = [Double](repeating: 0, count: 8)
    try diagnostics.withFrame(metadata) {
        try [1.0].withUnsafeBufferPointer { x in
            try bins.withUnsafeMutableBufferPointer { _ = try plan.forwardReal(x, into: $0) }
        }
        try bins.withUnsafeBufferPointer { x in
            try output.withUnsafeMutableBufferPointer { try plan.inverseReal(x, into: $0) }
        }
        #expect(throws: FourierError.nonfiniteInput) {
            try [Double.nan].withUnsafeBufferPointer { x in
                try bins.withUnsafeMutableBufferPointer { _ = try plan.forwardReal(x, into: $0) }
            }
        }
    }
    let starts = sink.beginnings.withLock { $0 }
    let ends = sink.endings.withLock { $0 }
    #expect(starts.map(\.stage) == [.analysisFrame, .fft, .fft])
    #expect(ends.map(\.stage) == [.fft, .fft, .analysisFrame])
    for record in starts {
        #expect(record.metadata == metadata)
        let matched = ends.filter { $0.span == record.span }
        #expect(matched.count == 1 && matched[0].metadata == record.metadata)
    }
}
