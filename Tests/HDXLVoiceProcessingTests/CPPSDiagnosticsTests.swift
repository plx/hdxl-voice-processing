import Foundation
import Synchronization
import Testing

@testable import HDXLVoiceProcessing

private final class CPPSDiagnosticSink: DiagnosticSink {
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
    func checkBalanced() {
        let a = begins.withLock { $0 }
        let b = ends.withLock { $0 }
        #expect(a.count == b.count)
        for record in a { #expect(b.filter { $0 == record }.count == 1) }
    }
}

@Test func cppsDiagnosticsSamplingBalanceAndConsumerBoundaries() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 2240, sampleRate: 16_000)
    let origin = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: 16_000)
    let profile = try CPPSProfile.murtonRecipePraat7(
        sourceSampleRate: 16_000, declaredInputBandwidthHz: 8000)
    let policy = try MaskSelectionPolicy()
    let mask = try MaskTimeline(
        MaskPlan(source: source, provenances: [], policy: policy, observations: []))
    let statistic = try CPPSStatisticProfile(
        measurement: profile, population: .allEligible,
        selection: policy, provenances: [], aggregation: .rollingFrameMean, rollingWindowSeconds: 1)
    let pcm = (0..<2240).map { sin(Double($0) * 0.1) * 0.2 + cos(Double($0) * 0.731) * 0.01 }
    var reference: [CPPSFrameResult]?
    for mode in DiagnosticMode.allCases {
        let sink = CPPSDiagnosticSink()
        let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
        let worker = try PreparedIntervalCPPS<Double>(
            profile: profile, source: source, diagnostics: diagnostics)
        let rolling = try PreparedRollingCPPS(
            profile: statistic, origin: origin, diagnostics: diagnostics)
        try pcm.withUnsafeBufferPointer { try worker.append($0, interval: source) }
        var values: [CPPSFrameResult] = []
        var callbackError: (any Error)?
        try worker.finish { output in
            sink.checkBalanced()
            values.append(output.result)
            do {
                try rolling.append(output.result)
                _ = try rolling.result(atSourceSample: source.endSample, mask: mask)
            } catch { callbackError = error }
            sink.checkBalanced()
        }
        if let callbackError { throw callbackError }
        if let reference { #expect(values == reference) } else { reference = values }
        sink.checkBalanced()
        let records = sink.begins.withLock { $0 }
        if mode == .disabled {
            #expect(records.isEmpty)
        } else {
            for (stage, token) in [
                (DiagnosticStage.cppsSmoothing, UInt64(37)), (.cppsFitting, 37),
                (.cppsAggregation, 3701),
            ] {
                let selected = records.filter { $0.stage == stage }
                let expected =
                    mode == .sampled
                    ? values.filter { $0.context.frameIndex % 16 == 0 }.count : values.count
                #expect(selected.count == expected)
                #expect(
                    selected.allSatisfy {
                        $0.metadata.profileToken == token && $0.metadata.sampleCount > 0
                    })
                if mode == .sampled {
                    #expect(selected.allSatisfy { $0.metadata.frameSequence % 16 == 0 })
                }
            }
        }
        try worker.reset(source: source)
        try rolling.reset(origin: origin)
        sink.checkBalanced()
    }
}
