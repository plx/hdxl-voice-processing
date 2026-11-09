import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func jitterDiagnosticsPreserveResultsAndSeparatePulseFromStatisticsScopes() throws {
    let samples = pulseCycleTrain(count: 160)
    let contour = try pulseContour(count: samples.count)
    let timing = try pulseTiming(count: samples.count)
    var baseline: JitterAnalysisResult?
    for mode in DiagnosticMode.allCases {
        let sink = RecordingSink()
        let worker = try PreparedPCMJitter<Double>(
            configuration: JitterConfiguration(sampleRate: 4000),
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
                $0.metadata.profileToken == 50 && $0.metadata.sampleCount == 160
                    && $0.metadata.elapsedProcessingCount == $0.metadata.frameSequence
            })
        #expect(starts.filter { $0.stage == .pulses }.map(\.metadata.frameSequence) == frames)
        if mode == .disabled { #expect(sink.entries.isEmpty) }
    }
}
