import CryptoKit
import Dispatch
import Foundation
import HDXLVoiceProcessing
import Synchronization

private enum ProbeError: Error {
    case arguments, input
    case mismatch(String)
}

/// Worker-only bounded sink. Per-attempt frames prevent the ordinary 64-record
/// interval budget from sampling only a prefix of a long block. This probe replays
/// actual kernel calls; it does not change production sampling or claim its cost.
private final class StageSink: DiagnosticSink {
    struct State {
        var active = [DiagnosticRecord?](repeating: nil, count: WorkerDiagnostics.maximumDepth)
        var starts = [UInt64](repeating: 0, count: WorkerDiagnostics.maximumDepth)
        var depth = 0
        var matching: [UInt64?]
        var interpolation: [UInt64?]
        init(_ count: Int) {
            matching = Array(repeating: nil, count: count)
            interpolation = Array(repeating: nil, count: count)
        }
    }
    let state: Mutex<State>
    init(_ count: Int) { state = Mutex(State(count)) }
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken? {
        let time = DispatchTime.now().uptimeNanoseconds
        state.withLock {
            precondition($0.depth < $0.active.count)
            $0.active[$0.depth] = record
            $0.starts[$0.depth] = time
            $0.depth += 1
        }
        return .recorded
    }
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken) {
        let time = DispatchTime.now().uptimeNanoseconds
        state.withLock {
            precondition($0.depth > 0)
            $0.depth -= 1
            precondition($0.active[$0.depth] == record)
            let elapsed = time - $0.starts[$0.depth]
            let index = Int(record.metadata.frameSequence)
            switch record.stage {
            case .pulseMatching:
                precondition($0.matching[index] == nil)
                $0.matching[index] = elapsed
            case .pulseInterpolation:
                precondition($0.interpolation[index] == nil)
                $0.interpolation[index] = elapsed
            default: break
            }
        }
    }
    func event(_ record: DiagnosticRecord) -> Bool { true }
    func clear() {
        state.withLock {
            precondition($0.depth == 0)
            for i in $0.matching.indices {
                $0.matching[i] = nil
                $0.interpolation[i] = nil
            }
        }
    }
    func snapshot() -> ([UInt64?], [UInt64?]) {
        state.withLock {
            precondition($0.depth == 0)
            return ($0.matching, $0.interpolation)
        }
    }
}

private struct Fixture: Decodable {
    struct Case: Decodable {
        let sampleRate, sampleCount: Int
        let inputPrecision: AnalysisPrecision
    }
    struct Reference: Decodable {
        struct Pitch: Decodable {
            let firstCenterSeconds, stepSeconds, ceilingHz: Double
            let frequenciesHz: [Double]
        }
        struct Values: Decodable { let pulseTimesSeconds: [Double] }
        let inputSHA256: String
        let pitch: Pitch
        let data: Values
    }
    let `case`: Case
    let reference: Reference
}
private struct Attempt: Encodable {
    let index: Int
    let acceptedByReferenceGates, eligible, interpolationExpected: Bool
    let rejectionBits: UInt32
    let fromSeconds, frequencyHz: Double
    let direction: PulseTrackingDirection
}
private struct Trial: Encodable {
    let index: Int
    let mode: String
    let replayNanoseconds: UInt64
    let checksum: Double
    let matchingNanoseconds, interpolationNanoseconds: [UInt64?]
}
private struct CaseResult: Encodable {
    let name, encodedInputSHA256, fixtureJSONSHA256: String
    let configuration: PulseConfiguration
    let profileIdentity, f0ContourIdentity: ProfileIdentity
    let inputSampleCount: Int
    let attempts: [Attempt]
    let trials: [Trial]
}
private struct Report: Encodable {
    let schemaVersion = 1
    let definition = "pulse-actual-attempt-kernel-replay-v1"
    let limitations =
        "Actual matching/interpolation kernel calls replayed from a complete native trace. Detailed stage timings include sink clock/lock overhead. Null means unmeasured; a measured zero is below clock resolution. Five paired disabled/detailed trials, warmed before measurement. Per-attempt diagnostic frames avoid prefix sampling; production sampling is unchanged. Replay totals include validation/frame wrappers and are not full analyzer throughput. Fixture loading, tracking prepass, setup and JSON export excluded. Separate prepared benchmarks supply full latency and allocation evidence."
    let cases: [CaseResult]
}

@main
struct PulseStageProbe {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.count == 2, arguments.first == "--shard",
            let shard = arguments.last,
            ["steady16000", "steady44100", "steady48000", "stress", "vowel"].contains(shard)
        else { throw ProbeError.arguments }
        let stems: [String]
        if shard.hasPrefix("steady") {
            let rate = String(shard.dropFirst(6))
            stems = [80, 150, 300, 600].map { "gaussian-\(rate)-\($0)" }
        } else if shard == "stress" {
            stems = [
                "rising-f0", "falling-f0", "jitter-12pct", "noisy-high", "missing-cycles", "splice",
                "silence", "noise",
            ]
        } else {
            stems = ["speech-bl01-vowel-a"]
        }
        var cases: [CaseResult] = []
        for stem in stems {
            for precision in [AnalysisPrecision.float32, .float64] {
                cases.append(try measure(stem + "-" + precision.rawValue))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(Report(cases: cases)))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func measure(_ name: String) throws -> CaseResult {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Tests/HDXLVoiceProcessingTests/Fixtures/Pulses")
        let json = try Data(contentsOf: directory.appending(path: name + ".json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: json)
        let wave = try Data(contentsOf: directory.appending(path: name + ".wav"))
        func sha(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        guard sha(wave) == fixture.reference.inputSHA256,
            wave.count == 56 + fixture.case.sampleCount * 8
        else { throw ProbeError.input }
        // Hash-bound canonical Float64 transport; original Float32 rounding is
        // already represented exactly by these Double values.
        let pcm = stride(from: 56, to: wave.count, by: 8).map { i in
            wave.withUnsafeBytes {
                Double(
                    bitPattern: UInt64(
                        littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
            }
        }
        let rate = fixture.case.sampleRate
        let pitch = fixture.reference.pitch
        let configuration = try PulseConfiguration(
            sampleRate: rate, inputPrecision: fixture.case.inputPrecision,
            pitchCeilingHz: pitch.ceilingHz)
        let contour = try PulseF0Contour(
            sampleRate: rate, sampleCount: pcm.count,
            firstCenterSeconds: pitch.firstCenterSeconds, stepSeconds: pitch.stepSeconds,
            ceilingHz: pitch.ceilingHz, frequenciesHz: pitch.frequenciesHz)
        let source = try SourceInterval(
            epoch: StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!),
            startSample: 0, sampleCount: Int64(pcm.count), sampleRate: Double(rate))
        let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        func prepass<S: BinaryFloatingPoint & Sendable>(_ input: [S]) throws -> PulseSnapshot {
            let worker = try PreparedPulseTracker<S>(
                configuration: configuration, maximumSampleCount: pcm.count,
                maximumF0FrameCount: contour.frequenciesHz.count, maximumTrackingAttempts: 4096)
            var result: PulseSnapshot?
            try input.withUnsafeBufferPointer {
                try worker.analyze($0, contour: contour, timing: timing) {
                    result = try $0.snapshot(maximumRecordCount: 30_000)
                }
            }
            guard let result else {
                throw ProbeError.mismatch("\(name): no tracking prepass result")
            }
            return result
        }
        let snapshot =
            try fixture.case.inputPrecision == .float32
            ? prepass(pcm.map(Float.init)) : prepass(pcm)
        guard snapshot.landmarks.count == fixture.reference.data.pulseTimesSeconds.count else {
            throw ProbeError.mismatch("\(name): prepass raw count")
        }
        for (a, b) in zip(snapshot.landmarks, fixture.reference.data.pulseTimesSeconds) {
            guard abs(a.timeSeconds - b) * Double(rate) <= 1e-6 else {
                throw ProbeError.mismatch("\(name): prepass raw position")
            }
        }
        let attempts = snapshot.attempts
        let sink = StageSink(attempts.count)
        var trials: [Trial] = []
        var expectedChecksum: Double?
        for index in 0..<5 {
            let modes: [DiagnosticMode] =
                index % 2 == 0 ? [.disabled, .detailed] : [.detailed, .disabled]
            for mode in modes {
                let diagnostics = WorkerDiagnostics(mode: mode, sink: sink)
                let kernel = PulseSearchKernel(configuration, diagnostics: diagnostics)
                func replay() throws -> Double {
                    var checksum = 0.0
                    try pcm.withUnsafeBufferPointer { input in
                        for attempt in attempts {
                            var metadata = DiagnosticMetadata()
                            metadata.frameSequence = UInt64(attempt.index)
                            metadata.sampleCount = UInt32(input.count)
                            metadata.profileToken = 42
                            let match = try diagnostics.withFrame(metadata) {
                                try kernel.match(
                                    input, anchor: attempt.fromSeconds,
                                    frequency: attempt.frequencyHz,
                                    direction: attempt.direction == .backward ? .backward : .forward
                                )
                            }
                            guard match.timeSeconds == attempt.proposedSeconds,
                                match.correlation == attempt.correlation,
                                match.curvature == attempt.curvature,
                                match.observedPairCount == attempt.observedPairCount,
                                match.amplitudeGatePeak == attempt.amplitudeGatePeak,
                                match.usedRangeFallback == attempt.usedRangeFallback
                            else {
                                throw ProbeError.mismatch(
                                    "\(name)/\(attempt.index): replay time \(match.timeSeconds) vs \(attempt.proposedSeconds), coefficient \(String(describing: match.correlation)) vs \(String(describing: attempt.correlation)), curvature \(match.curvature) vs \(attempt.curvature), pairs \(match.observedPairCount) vs \(attempt.observedPairCount), peak \(match.amplitudeGatePeak) vs \(attempt.amplitudeGatePeak), fallback \(match.usedRangeFallback) vs \(attempt.usedRangeFallback)"
                                )
                            }
                            checksum +=
                                match.timeSeconds + (match.correlation ?? 0)
                                + Double(match.observedPairCount)
                        }
                    }
                    return checksum
                }
                sink.clear()
                _ = try replay()
                sink.clear()
                let start = DispatchTime.now().uptimeNanoseconds
                let checksum = try replay()
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                let (matching, interpolation) = sink.snapshot()
                guard diagnostics.counts.suppressed == 0 else {
                    throw ProbeError.mismatch("Unexpected diagnostic suppression")
                }
                if let expectedChecksum {
                    guard expectedChecksum == checksum else {
                        throw ProbeError.mismatch("\(name): checksum changed")
                    }
                }
                expectedChecksum = checksum
                for i in attempts.indices {
                    guard (matching[i] != nil) == (mode == .detailed),
                        (interpolation[i] != nil)
                            == (mode == .detailed && attempts[i].correlation != nil)
                    else {
                        throw ProbeError.mismatch(
                            "\(name)/\(i)/\(mode): stage coverage \(String(describing: matching[i])), \(String(describing: interpolation[i])); correlation \(String(describing: attempts[i].correlation))"
                        )
                    }
                }
                trials.append(
                    Trial(
                        index: index, mode: mode.rawValue, replayNanoseconds: elapsed,
                        checksum: checksum, matchingNanoseconds: matching,
                        interpolationNanoseconds: interpolation))
            }
        }
        return try CaseResult(
            name: name, encodedInputSHA256: fixture.reference.inputSHA256,
            fixtureJSONSHA256: sha(json),
            configuration: configuration, profileIdentity: configuration.identity(),
            f0ContourIdentity: contour.identity(),
            inputSampleCount: pcm.count,
            attempts: attempts.map {
                Attempt(
                    index: $0.index,
                    acceptedByReferenceGates: $0.acceptedByReferenceGates,
                    eligible: $0.rejections.isEmpty,
                    interpolationExpected: $0.correlation != nil,
                    rejectionBits: $0.rejections.rawValue,
                    fromSeconds: $0.fromSeconds, frequencyHz: $0.frequencyHz,
                    direction: $0.direction)
            }, trials: trials)
    }
}
