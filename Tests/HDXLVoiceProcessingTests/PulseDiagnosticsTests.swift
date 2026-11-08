import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func pulseCheckBalanced(_ sink: RecordingSink) {
    var open: [UInt64: DiagnosticRecord] = [:]
    for entry in sink.entries {
        switch entry {
        case .begin(let record): #expect(open.updateValue(record, forKey: record.span) == nil)
        case .end(let record): #expect(open.removeValue(forKey: record.span) == record)
        case .event: break
        }
    }
    #expect(open.isEmpty)
}

@Test func pulseDiagnosticsSeparateMatchingInterpolationAndConsumerWithoutChangingResults() throws {
    let values = pulseCycleTrain(count: 160)
    let contour = try pulseContour(count: 160)
    let timing = try pulseTiming(count: 160)
    var baseline: PulseSnapshot?
    for mode in DiagnosticMode.allCases {
        let sink = RecordingSink()
        let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
        let worker = try PreparedPulseTracker<Double>(
            configuration: PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1000),
            maximumSampleCount: 160, maximumF0FrameCount: 8, maximumTrackingAttempts: 128,
            diagnostics: diagnostics)
        for _ in 0..<17 {
            try values.withUnsafeBufferPointer { input in
                try worker.analyze(input, contour: contour, timing: timing) { output in
                    let copy = try output.snapshot(maximumRecordCount: 1000)
                    if let baseline { #expect(copy == baseline) } else { baseline = copy }
                    // Consumer cost must not be inside the pulse algorithm span.
                    let records = sink.entries
                    let begins = records.filter {
                        if case .begin(let r) = $0 { return r.stage == .pulses }
                        return false
                    }.count
                    let ends = records.filter {
                        if case .end(let r) = $0 { return r.stage == .pulses }
                        return false
                    }.count
                    #expect(begins == ends)
                }
            }
        }
        pulseCheckBalanced(sink)
        let frames: [UInt64] = mode == .disabled ? [] : mode == .sampled ? [0, 16] : Array(0..<17)
        let starts = sink.entries.compactMap { entry -> DiagnosticRecord? in
            if case .begin(let record) = entry { return record }
            return nil
        }
        for stage in [DiagnosticStage.pulses, .pulseSequences, .resultPublication] {
            #expect(starts.filter { $0.stage == stage }.map(\.metadata.frameSequence) == frames)
        }
        for frame in frames {
            let selected = starts.filter { $0.metadata.frameSequence == frame }
            #expect(selected.contains { $0.stage == .pulseMatching })
            #expect(selected.contains { $0.stage == .pulseInterpolation })
            #expect(
                selected.allSatisfy {
                    $0.metadata.profileToken == 42 && $0.metadata.sampleCount == 160
                })
            #expect(selected.count <= WorkerDiagnostics.recordsPerFrame)
        }
        if mode == .disabled { #expect(sink.entries.isEmpty) }
    }
}

@Test func pulseDiagnosticsBoundLongBlocksAndBalanceThrownPublication() throws {
    let sink = RecordingSink()
    let diagnostics = WorkerDiagnostics(mode: .detailed, sink: sink)
    let worker = try PreparedPulseTracker<Double>(
        configuration: PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1000),
        maximumSampleCount: 400, maximumF0FrameCount: 20, maximumTrackingAttempts: 128,
        diagnostics: diagnostics)
    let contour = try pulseContour(count: 400)
    let timing = try pulseTiming(count: 400)
    enum DeliveryError: Error { case intentional }
    #expect(throws: DeliveryError.intentional) {
        try pulseCycleTrain().withUnsafeBufferPointer { input in
            try worker.analyze(input, contour: contour, timing: timing) { _ in
                throw DeliveryError.intentional
            }
        }
    }
    pulseCheckBalanced(sink)
    #expect(diagnostics.counts.suppressed > 0)
    #expect(diagnostics.counts.intervals <= UInt64(WorkerDiagnostics.recordsPerFrame))
    try worker.reset()
    // The exhausted record budget may suppress the reset event, but its epoch
    // transition must apply when the next analysis receives a fresh budget.
    let unvoiced = try pulseContour(count: 400, values: Array(repeating: 0, count: 20))
    try pulseCycleTrain().withUnsafeBufferPointer { input in
        try worker.analyze(input, contour: unvoiced, timing: timing) {
            #expect($0.landmarks.isEmpty)
        }
    }
    pulseCheckBalanced(sink)
    let epochs = sink.entries.compactMap { entry -> UInt64? in
        if case .begin(let record) = entry { return record.epoch }
        return nil
    }
    #expect(epochs.first == 0 && epochs.last == 1)
}
