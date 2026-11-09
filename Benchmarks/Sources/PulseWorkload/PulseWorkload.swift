import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum PulseOperation: String, CaseIterable {
    case prepare = "Prepare"
    case run = "Run"
}

public struct PulseCase: Encodable, Sendable {
    public let fixture: String
    public let precision: AnalysisPrecision
    public let support: PulseSupportDefinition
    public let ownedSnapshot: Bool
    public let shard: String
    public let chunkSamples = 256
    public let maximumTrackingAttempts = 4096
    public var name: String {
        "\(fixture).\(precision.rawValue).\(support == .completeInterval ? "whole" : "block").\(ownedSnapshot ? "owned" : "borrowed")"
    }
    public static func matrix() -> [Self] {
        var rows: [Self] = []
        func add(_ fixture: String, shard: String, owned: Bool = false) {
            for precision in [AnalysisPrecision.float32, .float64] {
                for support in [
                    PulseSupportDefinition.completeInterval, .independentlyAnchoredBlock,
                ] {
                    rows.append(
                        Self(
                            fixture: fixture, precision: precision, support: support,
                            ownedSnapshot: owned, shard: shard))
                }
            }
        }
        for rate in [16000, 44100, 48000] {
            for hz in [80, 150, 300, 600] { add("gaussian-\(rate)-\(hz)", shard: "steady\(rate)") }
        }
        for name in [
            "rising-f0", "falling-f0", "jitter-12pct", "noisy-high", "missing-cycles", "splice",
            "silence", "noise",
        ] {
            add(name, shard: "stress")
        }
        add("speech-bl01-vowel-a", shard: "vowel")
        add("gaussian-48000-150", shard: "export", owned: true)
        return rows
    }
    public func makeWorkload() throws -> any PulseBatch {
        if precision == .float32 { return try PulseWorkload<Float>(self) }
        return try PulseWorkload<Double>(self)
    }
}

private enum WorkloadError: Error { case invalidFixture, mismatch }
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
        struct Values: Decodable {
            struct Amplitude: Decodable {
                let pulseIndex: Int
                let rmsAmplitude: Double
            }
            let pulseTimesSeconds: [Double]
            let amplitudes: [Amplitude]
        }
        let inputSHA256: String
        let pitch: Pitch
        let data: Values
    }
    let `case`: Case
    let reference: Reference
}

public struct PulseCounts: Encodable, Equatable {
    public var rawPulses = 0, attempts = 0, acceptedAttempts = 0, rejectedAttempts = 0
    public var eligibleAttempts = 0, eligiblePulses = 0, rawPeriods = 0, eligiblePeriods = 0
    public var rawPairs = 0, eligiblePairs = 0, availableAmplitudes = 0, runs = 0
    public var exportedRecords = 0
}

public struct PulseEvidence: Encodable {
    public let name: String
    public let workload: PulseCase
    public let configuration: PulseConfiguration
    public let profileIdentity, f0ContourIdentity: ProfileIdentity
    public let fixtureJSONSHA256, encodedInputSHA256, normalizedInputSHA256: String
    public let inputSampleCount, f0FrameCount, preparedInputBytes, preparedContourBytes,
        preparedBufferBytes: Int
    public let f0FirstCenterSeconds, f0StepSeconds, inputDurationSeconds,
        maximumDependencyDelaySeconds: Double
    public let counts: PulseCounts
    public let checksum, maximumReferenceErrorSamples, maximumAmplitudeBudgetFraction: Double
}

public protocol PulseBatch: AnyObject {
    func prepare() throws -> AnyObject
    func run() throws -> Double
    func verify() throws -> PulseEvidence
}

private final class PulseWorkload<S: BinaryFloatingPoint & Sendable>: PulseBatch {
    let item: PulseCase
    let fixture: Fixture
    let fixtureHash: String
    let pcm: [S]
    let configuration: PulseConfiguration
    let contour: PulseF0Contour
    let timing: AnalysisTiming
    let worker: PreparedPulseTracker<S>?
    let stream: PreparedPulseStream<S>?
    var counts = PulseCounts()
    var checksum = 0.0
    var delay = 0.0
    var capture = false
    var captured: PulseSnapshot?

    init(_ item: PulseCase) throws {
        self.item = item
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Tests/HDXLVoiceProcessingTests/Fixtures/Pulses")
        let stem = item.fixture + "-" + item.precision.rawValue
        let json = try Data(contentsOf: directory.appending(path: stem + ".json"))
        fixture = try JSONDecoder().decode(Fixture.self, from: json)
        fixtureHash = Self.sha(json)
        let data = try Data(contentsOf: directory.appending(path: stem + ".wav"))
        guard Self.sha(data) == fixture.reference.inputSHA256,
            fixture.case.inputPrecision == item.precision,
            data.count == 56 + fixture.case.sampleCount * 8
        else { throw WorkloadError.invalidFixture }
        // Only the canonical Float64 WAVE transport emitted by the pinned fixture
        // tool is accepted. File decoding and precision conversion are setup work.
        func tag(_ i: Int) -> String { String(decoding: data[i..<i + 4], as: UTF8.self) }
        func u16(_ i: Int) -> UInt16 {
            data.withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt16.self))
            }
        }
        func u32(_ i: Int) -> UInt32 {
            data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt32.self))
            }
        }
        guard tag(0) == "RIFF", tag(8) == "WAVE", Int(u32(4)) == data.count - 8,
            tag(12) == "fmt ", u32(16) == 16, u16(20) == 3, u16(22) == 1,
            Int(u32(24)) == fixture.case.sampleRate, u32(28) == u32(24) * 8,
            u16(32) == 8, u16(34) == 64, tag(36) == "fact", u32(40) == 4,
            Int(u32(44)) == fixture.case.sampleCount, tag(48) == "data",
            Int(u32(52)) == fixture.case.sampleCount * 8
        else { throw WorkloadError.invalidFixture }
        pcm = stride(from: 56, to: data.count, by: 8).map { i in
            data.withUnsafeBytes {
                S(
                    Double(
                        bitPattern: UInt64(
                            littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt64.self))))
            }
        }
        let pitch = fixture.reference.pitch
        contour = try PulseF0Contour(
            sampleRate: fixture.case.sampleRate, sampleCount: pcm.count,
            firstCenterSeconds: pitch.firstCenterSeconds, stepSeconds: pitch.stepSeconds,
            ceilingHz: pitch.ceilingHz, frequenciesHz: pitch.frequenciesHz)
        configuration = try PulseConfiguration(
            sampleRate: fixture.case.sampleRate,
            inputPrecision: item.precision, pitchCeilingHz: pitch.ceilingHz, support: item.support)
        let source = try SourceInterval(
            epoch: StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!),
            startSample: 0, sampleCount: Int64(pcm.count),
            sampleRate: Double(fixture.case.sampleRate))
        timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        worker =
            item.support == .completeInterval
            ? try PreparedPulseTracker(
                configuration: configuration, maximumSampleCount: pcm.count,
                maximumF0FrameCount: contour.frequenciesHz.count,
                maximumTrackingAttempts: item.maximumTrackingAttempts) : nil
        stream =
            item.support == .independentlyAnchoredBlock
            ? try PreparedPulseStream(
                configuration: configuration, contour: contour, timing: timing,
                maximumTrackingAttempts: item.maximumTrackingAttempts) : nil
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    @inline(never) func prepare() throws -> AnyObject {
        if item.support == .completeInterval {
            return try PreparedPulseTracker<S>(
                configuration: configuration, maximumSampleCount: pcm.count,
                maximumF0FrameCount: contour.frequenciesHz.count,
                maximumTrackingAttempts: item.maximumTrackingAttempts)
        }
        return try PreparedPulseStream<S>(
            configuration: configuration, contour: contour, timing: timing,
            maximumTrackingAttempts: item.maximumTrackingAttempts)
    }
    @inline(never) func run() throws -> Double {
        counts = PulseCounts()
        checksum = 0
        delay = 0
        captured = nil
        if let worker {
            try worker.reset()
            try pcm.withUnsafeBufferPointer {
                try worker.analyze($0, contour: contour, timing: timing, emit: consume)
            }
        } else if let stream {
            try stream.reset(contour: contour, timing: timing)
            try pcm.withUnsafeBufferPointer { buffer in
                for start in stride(from: 0, to: buffer.count, by: item.chunkSamples) {
                    let end = min(buffer.count, start + item.chunkSamples)
                    let interval = try SourceInterval(
                        epoch: timing.source.epoch, startSample: Int64(start),
                        sampleCount: Int64(end - start), sampleRate: timing.source.sampleRate)
                    try stream.append(
                        UnsafeBufferPointer(rebasing: buffer[start..<end]), interval: interval)
                }
            }
            try stream.finish(emit: consume)
        }
        return checksum
    }
    private func consume(_ output: BorrowedPulseOutput) throws {
        let r = output.result
        counts.rawPulses = output.landmarks.count
        counts.attempts = output.attempts.count
        counts.rawPeriods = output.periods.count
        counts.rawPairs = output.periodPairs.count
        counts.eligiblePulses = r.eligiblePulseCount
        counts.eligiblePeriods = r.eligiblePeriodCount
        counts.eligiblePairs = r.eligiblePairCount
        counts.availableAmplitudes = r.availableAmplitudeCount
        counts.runs = r.runCount
        delay = r.timing.effectiveDelaySeconds
        checksum = Double(r.timing.source.sampleCount + Int64(r.trackingAttemptCount))
        for p in output.landmarks { checksum += p.timeSeconds + Double(p.rejections.rawValue) }
        for a in output.attempts {
            counts.acceptedAttempts += a.acceptedByReferenceGates ? 1 : 0
            counts.rejectedAttempts += a.acceptedByReferenceGates ? 0 : 1
            counts.eligibleAttempts += a.rejections.isEmpty ? 1 : 0
            checksum += a.proposedSeconds + (a.correlation ?? 0) + Double(a.rejections.rawValue)
        }
        for p in output.periods { checksum += p.durationSeconds + Double(p.rejections.rawValue) }
        for p in output.periodPairs {
            checksum += (p.ratio.isFinite ? p.ratio : 0) + Double(p.rejections.rawValue)
        }
        for a in output.amplitudes {
            checksum += (a.rmsAmplitude ?? 0) + Double(a.rejections.rawValue)
        }
        if item.ownedSnapshot || capture {
            let snapshot = try output.snapshot(maximumRecordCount: 30_000)
            if item.ownedSnapshot {
                counts.exportedRecords =
                    snapshot.landmarks.count + snapshot.attempts.count
                    + snapshot.periods.count + snapshot.periodPairs.count
                    + snapshot.amplitudes.count
                // Every owned array is observed after copying; its lifetime covers
                // these reads. Snapshot allocation is intentionally measured here.
                checksum += snapshot.landmarks.reduce(0) { $0 + $1.timeSeconds }
                checksum += snapshot.attempts.reduce(0) { $0 + $1.proposedSeconds }
                checksum += snapshot.periods.reduce(0) { $0 + $1.durationSeconds }
                checksum += snapshot.periodPairs.reduce(0) { $0 + Double($1.rejections.rawValue) }
                checksum += snapshot.amplitudes.reduce(0) { $0 + ($1.rmsAmplitude ?? 0) }
            }
            if capture { captured = snapshot }
        }
    }
    func verify() throws -> PulseEvidence {
        capture = true
        let firstChecksum = try run()
        guard let first = captured else { throw WorkloadError.mismatch }
        let firstCounts = counts
        let secondChecksum = try run()
        guard first == captured, firstChecksum == secondChecksum, firstCounts == counts,
            checksum.isFinite, checksum > 0,
            first.landmarks.count == fixture.reference.data.pulseTimesSeconds.count
        else { throw WorkloadError.mismatch }
        capture = false
        captured = nil
        var error = 0.0
        var amplitudeError = 0.0
        for (a, b) in zip(first.landmarks, fixture.reference.data.pulseTimesSeconds) {
            error = max(error, abs(a.timeSeconds - b) * Double(configuration.sampleRate))
        }
        for a in first.amplitudes {
            guard let value = a.rmsAmplitude else { continue }
            guard
                let b = fixture.reference.data.amplitudes.first(where: {
                    $0.pulseIndex == a.pulseIndex
                })
            else { throw WorkloadError.mismatch }
            amplitudeError = max(
                amplitudeError, abs(value - b.rmsAmplitude) / (2e-12 + 1e-10 * abs(b.rmsAmplitude)))
        }
        guard error <= 1e-6, amplitudeError <= 1 else { throw WorkloadError.mismatch }
        var normalized = Data()
        for sample in pcm {
            var bits = Double(sample).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { normalized.append(contentsOf: $0) }
        }
        return try PulseEvidence(
            name: item.name, workload: item, configuration: configuration,
            profileIdentity: configuration.identity(), f0ContourIdentity: contour.identity(),
            fixtureJSONSHA256: fixtureHash, encodedInputSHA256: fixture.reference.inputSHA256,
            normalizedInputSHA256: Self.sha(normalized), inputSampleCount: pcm.count,
            f0FrameCount: contour.frequenciesHz.count,
            preparedInputBytes: pcm.count * MemoryLayout<S>.stride,
            preparedContourBytes: contour.frequenciesHz.count * MemoryLayout<Double>.stride,
            preparedBufferBytes: worker?.executionStatistics.preparedBufferBytes
                ?? stream!.preparedBufferBytes,
            f0FirstCenterSeconds: contour.firstCenterSeconds, f0StepSeconds: contour.stepSeconds,
            inputDurationSeconds: Double(pcm.count) / Double(configuration.sampleRate),
            maximumDependencyDelaySeconds: delay, counts: counts, checksum: checksum,
            maximumReferenceErrorSamples: error, maximumAmplitudeBudgetFraction: amplitudeError)
    }
}
