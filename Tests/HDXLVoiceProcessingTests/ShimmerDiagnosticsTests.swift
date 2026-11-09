import Foundation
import Testing

@testable import HDXLVoiceProcessing

/// Test-only synchronous sink. It is used by one worker on one test thread;
/// production sinks cannot mutate or retain the non-Sendable worker.
private final class ShimmerReentrySink: DiagnosticSink, @unchecked Sendable {
    var action: (() -> Void)?
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
        action?()
        return .recorded
    }
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {}
    func event(_ record: DiagnosticRecord) -> Bool {
        if record.stage == .reset { action?() }
        return true
    }
}

@Test func shimmerStatisticsRejectDiagnosticReentryDuringQueryAndReset() throws {
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()),
        startSample: 0, sampleCount: 160, sampleRate: 16000)
    let timing = try AnalysisTiming(source: source, includedSampleCount: 160)
    let amplitude = try ShimmerAmplitudeInput(timeSeconds: 0.005, amplitude: 1, sequenceIndex: 0)
    let batchSink = ShimmerReentrySink()
    let batch = try PreparedShimmer(
        configuration: ShimmerConfiguration(sampleRate: 16000),
        maximumAmplitudeCount: 4, diagnostics: WorkerDiagnostics(mode: .detailed, sink: batchSink))
    var batchCalls = 0
    batchSink.action = {
        batchCalls += 1
        #expect(throws: ShimmerError.reentrantCall) { try batch.reset() }
        #expect(throws: ShimmerError.reentrantCall) {
            try [amplitude].withUnsafeBufferPointer {
                try batch.analyze($0, dependencyTiming: timing)
            }
        }
    }
    defer { batchSink.action = nil }
    _ = try [amplitude].withUnsafeBufferPointer { try batch.analyze($0, dependencyTiming: timing) }
    try batch.reset()
    #expect(batchCalls == 2 && batch.executionStatistics.analyzedQueryCount == 0)

    let rollingSink = ShimmerReentrySink()
    let rolling = try PreparedRollingShimmer(
        configuration: ShimmerConfiguration(
            sampleRate: 16000,
            applicability: .exploratoryRolling, rollingWindowSampleCount: 1600),
        origin: SourceInterval(
            epoch: source.epoch, startSample: 0, sampleCount: 0, sampleRate: 16000),
        maximumAmplitudeCount: 4, diagnostics: WorkerDiagnostics(mode: .detailed, sink: rollingSink)
    )
    var rollingCalls = 0
    rollingSink.action = {
        rollingCalls += 1
        #expect(throws: ShimmerError.reentrantCall) { try rolling.reset() }
        #expect(throws: ShimmerError.reentrantCall) {
            try rolling.append(amplitude, dependency: source)
        }
        #expect(throws: ShimmerError.reentrantCall) {
            try rolling.requiredDependency(atSourceSample: 160)
        }
        #expect(throws: ShimmerError.reentrantCall) {
            try rolling.result(atSourceSample: 160, dependencyTiming: timing)
        }
    }
    defer { rollingSink.action = nil }
    try rolling.append(amplitude, dependency: source)
    _ = try rolling.result(atSourceSample: 160, dependencyTiming: timing)
    try rolling.reset()
    #expect(rollingCalls == 2 && rolling.executionStatistics.retainedAmplitudeCount == 0)
}

@Test func shimmerDiagnosticsPreserveResultsAndSeparatePulseFromStatisticsScopes() throws {
    let samples = pulseCycleTrain(count: 160)
    let contour = try pulseContour(count: samples.count)
    let timing = try pulseTiming(count: samples.count)
    var baseline: ShimmerAnalysisResult?
    for mode in DiagnosticMode.allCases {
        let sink = RecordingSink()
        let worker = try PreparedPCMShimmer<Double>(
            configuration: ShimmerConfiguration(sampleRate: 4000),
            pulseConfiguration: PulseConfiguration(sampleRate: 4000, pitchCeilingHz: 1000),
            maximumSampleCount: 160, maximumF0FrameCount: 8, maximumTrackingAttempts: 128,
            pulseDiagnostics: WorkerDiagnostics(mode: mode, sink: sink),
            statisticsDiagnostics: WorkerDiagnostics(mode: mode, sink: sink))
        for _ in 0..<17 {
            try samples.withUnsafeBufferPointer { input in
                try worker.analyze(input, contour: contour, timing: timing) { output in
                    if let baseline {
                        #expect(output.result == baseline)
                    } else {
                        baseline = output.result
                    }
                    var activeStatistics = 0
                    for entry in sink.entries {
                        switch entry {
                        case .begin(let record) where record.stage == .perturbation:
                            activeStatistics += 1
                        case .end(let record) where record.stage == .perturbation:
                            activeStatistics -= 1
                        default: break
                        }
                    }
                    #expect(
                        activeStatistics == 0,
                        "Consumer must execute after the statistics span ends")
                }
            }
        }
        var open: [String: DiagnosticRecord] = [:]
        var starts: [DiagnosticRecord] = []
        for entry in sink.entries {
            switch entry {
            case .begin(let record):
                let key = "\(record.session)-\(record.span)"
                #expect(open.updateValue(record, forKey: key) == nil)
                starts.append(record)
            case .end(let record):
                let key = "\(record.session)-\(record.span)"
                #expect(open.removeValue(forKey: key) == record)
            case .event: break
            }
        }
        #expect(open.isEmpty)
        let frames: [UInt64] = mode == .disabled ? [] : mode == .sampled ? [0, 16] : Array(0..<17)
        let statistics = starts.filter { $0.stage == .perturbation }
        #expect(statistics.map(\.metadata.frameSequence) == frames)
        #expect(
            statistics.allSatisfy {
                $0.metadata.profileToken == 51 && $0.metadata.sampleCount == 160
                    && $0.metadata.elapsedProcessingCount == $0.metadata.frameSequence
            })
        #expect(starts.filter { $0.stage == .pulses }.map(\.metadata.frameSequence) == frames)
        if mode == .disabled { #expect(sink.entries.isEmpty) }
    }
}
