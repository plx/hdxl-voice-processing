import HDXLVoiceProcessing
import Synchronization
import Testing

private final class ConditioningSink: DiagnosticSink {
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

@Test func conditioningDiagnosticsAreBoundedAndBalanceNestedFourierAndFilterSpans() throws {
    for preview in [false, true] {
        let sink = ConditioningSink()
        let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
        let config = try testConditioningConfiguration(
            method: preview
                ? .streamingPreview(lobes: 32, cutoffFraction: 0.9)
                : .praat7WholeInterval(interpolationDepth: 50))
        let input = [Double](repeating: 0.25, count: 1024)
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 31
        metadata.frameSequence = 7
        metadata.sampleCount = 1024
        func checkConsumerScope() {
            let starts = sink.beginnings.withLock { $0 }
            let ends = sink.endings.withLock { $0 }
            for stage in [DiagnosticStage.resample, .preEmphasis, .fft] {
                #expect(
                    starts.filter { $0.stage == stage }.count
                        == ends.filter { $0.stage == stage }.count)
            }
        }
        try diagnostics.withFrame(metadata) {
            if preview {
                let plan = try PreparedPreviewConditioner<Double>(
                    layout: PreviewConditioningLayout(
                        configuration: config, outputBlockCapacity: 1),
                    epoch: conditioningEpoch, diagnostics: diagnostics)
                _ = try input.withUnsafeBufferPointer {
                    try plan.process($0, interval: conditioningInterval(input.count)) { _, _ in
                        checkConsumerScope()
                    }
                }
                try plan.finish { _, _ in checkConsumerScope() }
            } else {
                let plan = try PreparedIntervalConditioner<Double>(
                    configuration: config,
                    source: conditioningInterval(input.count), diagnostics: diagnostics)
                try input.withUnsafeBufferPointer {
                    try plan.append($0, interval: conditioningInterval(input.count))
                }
                try plan.finish { _, _ in checkConsumerScope() }
            }
        }
        let starts = sink.beginnings.withLock { $0 }
        let ends = sink.endings.withLock { $0 }
        #expect(starts.contains { $0.stage == .resample })
        #expect(starts.contains { $0.stage == .preEmphasis })
        #expect(starts.contains { $0.stage == .fft } == !preview)
        #expect(starts.count <= 64)
        #expect(starts.count == ends.count)
        for record in starts {
            #expect(record.metadata == metadata)
            #expect(ends.filter { $0.span == record.span && $0.metadata == metadata }.count == 1)
        }
    }
}
