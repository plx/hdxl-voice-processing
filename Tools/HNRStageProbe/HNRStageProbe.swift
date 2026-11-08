import Dispatch
import Foundation
import HDXLVoiceProcessing
import Synchronization

/// Fixed-capacity worker-only sink. Its clock/lock/record overhead is deliberately
/// included in detailed trials; disabled trials use no sink. Never captures PCM.
private final class StageSink: DiagnosticSink {
    static let stages: [DiagnosticStage] = [
        .hnrNormalization, .analysisFrame, .hnr, .hnrWindow, .hnrCorrelation, .hnrPeriodSearch,
        .fft,
    ]
    struct State {
        var active = [DiagnosticRecord?](repeating: nil, count: WorkerDiagnostics.maximumDepth)
        var starts = [UInt64](repeating: 0, count: WorkerDiagnostics.maximumDepth)
        var depth = 0
        var values = Array(repeating: [UInt64](repeating: 0, count: 4096), count: stages.count)
        var counts = [Int](repeating: 0, count: stages.count)
    }
    let state = Mutex(State())
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
        let start = DispatchTime.now().uptimeNanoseconds
        state.withLock {
            precondition($0.depth < $0.active.count)
            $0.active[$0.depth] = record
            $0.starts[$0.depth] = start
            $0.depth += 1
        }
        return .recorded
    }
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {
        let end = DispatchTime.now().uptimeNanoseconds
        state.withLock {
            precondition($0.depth > 0)
            $0.depth -= 1
            precondition($0.active[$0.depth] == record)
            if let i = Self.stages.firstIndex(of: record.stage) {
                precondition($0.counts[i] < $0.values[i].count)
                $0.values[i][$0.counts[i]] = end - $0.starts[$0.depth]
                $0.counts[i] += 1
            }
        }
    }
    func event(_ record: DiagnosticRecord) -> Bool { true }
    func clear() {
        state.withLock {
            precondition($0.depth == 0)
            for i in $0.counts.indices { $0.counts[i] = 0 }
        }
    }
    func samples() -> [String: [UInt64]] {
        state.withLock { state in
            precondition(state.depth == 0)
            return Dictionary(
                uniqueKeysWithValues: Self.stages.indices.map {
                    (Self.stages[$0].rawValue, Array(state.values[$0].prefix(state.counts[$0])))
                })
        }
    }
}
private struct Trial: Encodable {
    let configuration: HNRConfiguration
    let profileIdentity: ProfileIdentity
    let inputSampleCount: Int
    let trial: Int
    let mode: String
    let nanoseconds: UInt64
    let checksum: Double
    let completeFrames: Int
    let stageNanoseconds: [String: [UInt64]]
}
private struct Report: Encodable {
    let schemaVersion = 1
    let definition = "hnr-worker-stage-clock-probe-v1"
    let limitations =
        "Detailed inclusive stage timings contain clock/lock/sink overhead; nested FFT is included in correlation. Disabled full-batch trials provide paired overhead context, not capture latency or allocation evidence. PCM generation, worker setup, warmup and JSON export excluded. No transform sharing."
    let trials: [Trial]
}
private enum ProbeError: Error { case invalidArguments, mismatch }

@main
struct HNRStageProbe {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        let rates: [Int]
        if arguments.isEmpty {
            rates = [16000, 44100, 48000]
        } else if arguments.count == 2, arguments.first == "--rate",
            let rate = Int(arguments.last!),
            [16000, 44100, 48000].contains(rate)
        {
            rates = [rate]
        } else {
            throw ProbeError.invalidArguments
        }
        var trials: [Trial] = []
        for rate in rates {
            for method in HNRMethod.allCases {
                for periods in [4.5, 6.0] {
                    for floor in [60.0, 75.0] {
                        for hop in [0.005, 0.01] {
                            for precision in [AnalysisPrecision.float32, .float64] {
                                for normalization in [
                                    HNRNormalizationDefinition.wholeInterval, .causalWindow,
                                ] {
                                    let c = try HNRConfiguration(
                                        method: method, sampleRate: rate,
                                        inputPrecision: precision, pitchFloorHz: floor,
                                        periodsPerWindow: periods,
                                        hopSeconds: hop, normalization: normalization)
                                    if precision == .float32 {
                                        trials += try measure(c, as: Float.self)
                                    } else {
                                        trials += try measure(c, as: Double.self)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(Report(trials: trials)))
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    private static func measure<S: BinaryFloatingPoint & Sendable>(
        _ c: HNRConfiguration, as: S.Type
    ) throws -> [Trial] {
        let count = c.sampleRate * 2 / 5
        var seed: UInt32 = 39
        let pcm: [S] = (0..<count).map { index in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            let noise = (Double(seed) - 2_147_483_648) / 4_294_967_296
            let phase = 2 * Double.pi * 120 * Double(index) / Double(c.sampleRate)
            return S(0.4 * sin(phase) + 0.08 * sin(2 * phase) + 0.015 * noise)
        }
        let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000039")!)
        let source = try SourceInterval(
            epoch: epoch, startSample: 0,
            sampleCount: Int64(count), sampleRate: Double(c.sampleRate))
        let timing = try AnalysisTiming(source: source, includedSampleCount: Int64(count))
        let origin = try AnalysisTiming(
            source: SourceInterval(
                epoch: epoch, startSample: 0,
                sampleCount: 0, sampleRate: Double(c.sampleRate)), includedSampleCount: 0)
        let sink = StageSink()
        var result: [Trial] = []
        var expected: Double?
        // Alternate order per trial. Each worker is prepared and warmed before its
        // measured batch; no stale ring, completion or first-use sink arrays remain.
        for trial in 0..<5 {
            let modes: [DiagnosticMode] =
                trial % 2 == 0 ? [.disabled, .detailed] : [.detailed, .disabled]
            for mode in modes {
                let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
                let whole: PreparedIntervalHNR<S>? =
                    c.normalization == .wholeInterval
                    ? try PreparedIntervalHNR(
                        configuration: c, timing: timing, diagnostics: diagnostics) : nil
                let stream: PreparedHNRStream<S>? =
                    c.normalization == .causalWindow
                    ? try PreparedHNRStream(
                        configuration: c, origin: origin, diagnostics: diagnostics) : nil
                var checksum = 0.0
                var frames = 0
                func consume(_ value: BorrowedHNRAnalysisOutput) {
                    if case .frame(let output) = value {
                        frames += 1
                        checksum += Double(output.result.frameTiming.source.sampleCount)
                        checksum +=
                            output.result.selectedObservation?.referenceReportingDecibels ?? 0
                    }
                }
                func run() throws {
                    checksum = 0
                    frames = 0
                    try pcm.withUnsafeBufferPointer {
                        if let whole {
                            try whole.append($0, interval: source)
                            try whole.finish(emit: consume)
                        }
                        if let stream {
                            let current = try SourceInterval(
                                epoch: stream.epoch, startSample: 0,
                                sampleCount: Int64(count), sampleRate: Double(c.sampleRate))
                            try stream.process($0, interval: current) { consume($0.frame) }
                            try stream.finish { consume($0.frame) }
                        }
                    }
                }
                try run()
                if let whole { try whole.reset(timing: timing) }
                if let stream {
                    try stream.reset(
                        for: SourceDiscontinuity(
                            previousEpoch: stream.epoch,
                            nextEpoch: stream.epoch.successor(), reason: .explicitReset))
                }
                sink.clear()
                let start = DispatchTime.now().uptimeNanoseconds
                try run()
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                if let expected, expected != checksum { throw ProbeError.mismatch }
                expected = checksum
                result.append(
                    Trial(
                        configuration: c, profileIdentity: try c.identity(),
                        inputSampleCount: count, trial: trial, mode: mode.rawValue,
                        nanoseconds: elapsed, checksum: checksum, completeFrames: frames,
                        stageNanoseconds: sink.samples()))
            }
        }
        return result
    }
}
