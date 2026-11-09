import Foundation
import HDXLVoiceProcessing

public struct JitterPCMEvidence: Encodable {
    public let fixture: String
    public let fixtureSHA256: String
    public let encodedInputSHA256: String
    public let normalizedInputSHA256: String
    public let sampleCount: Int
    public let f0FrameCount: Int
    public let f0FirstCenterSeconds: Double
    public let f0StepSeconds: Double
    public let pulseConfiguration: PulseConfiguration
    public let pulseProfile: ProfileIdentity
    public let contourIdentity: ProfileIdentity
    public let preparedPulseBufferBytes: Int
    public let preparedStatisticsBufferBytes: Int
    public let preparedContourBytes: Int
    public let rawPulseTimesSeconds: [Double]
    public let mappedPeriods: [JitterPeriodInput]
    public let maximumReferenceErrorSamples: Double
}

private struct JitterPCMFixture: Decodable {
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

final class JitterPCMWorkload<S: BinaryFloatingPoint & Sendable>: JitterBatch {
    let item: JitterCase
    private let fixture: JitterPCMFixture
    let fixtureName: String
    let fixtureHash: String
    let normalizedHash: String
    let pcm: [S]
    let configuration: JitterConfiguration
    let pulseConfiguration: PulseConfiguration
    let contour: PulseF0Contour
    let inputTiming: AnalysisTiming
    let statisticsTiming: AnalysisTiming
    let provenance: JitterInputProvenance
    let pipeline: PreparedPCMJitter<S>
    let pulse: PreparedPulseTracker<S>
    let statistics: PreparedJitter
    let mappedPeriods: [JitterPeriodInput]
    let maximumTrackingAttempts = 4096
    var last: JitterAnalysisResult?

    init(_ item: JitterCase) throws {
        self.item = item
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Tests/HDXLVoiceProcessingTests/Fixtures/Pulses")
        let name = "gaussian-\(item.sampleRate)-\(item.frequencyHz)-\(item.precision.rawValue)"
        fixtureName = name
        let json = try Data(contentsOf: directory.appending(path: name + ".json"))
        let fixture = try JSONDecoder().decode(JitterPCMFixture.self, from: json)
        self.fixture = fixture
        fixtureHash = jitterSHA(json)
        let data = try Data(contentsOf: directory.appending(path: name + ".wav"))
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
        guard data.count == 56 + fixture.case.sampleCount * 8,
            fixture.case.sampleRate == item.sampleRate,
            fixture.case.inputPrecision == item.precision,
            jitterSHA(data) == fixture.reference.inputSHA256,
            tag(0) == "RIFF", tag(8) == "WAVE", Int(u32(4)) == data.count - 8,
            tag(12) == "fmt ", u32(16) == 16, u16(20) == 3, u16(22) == 1,
            Int(u32(24)) == item.sampleRate, u32(28) == u32(24) * 8,
            u16(32) == 8, u16(34) == 64, tag(36) == "fact", u32(40) == 4,
            Int(u32(44)) == fixture.case.sampleCount, tag(48) == "data",
            Int(u32(52)) == data.count - 56
        else { throw JitterWorkloadError.invalidInput }
        let samples: [S] = stride(from: 56, to: data.count, by: 8).map { i in
            data.withUnsafeBytes {
                S(
                    Double(
                        bitPattern: UInt64(
                            littleEndian:
                                $0.loadUnaligned(fromByteOffset: i, as: UInt64.self))))
            }
        }
        pcm = samples
        var normalized = Data()
        for sample in samples {
            var bits = Double(sample).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { normalized.append(contentsOf: $0) }
        }
        normalizedHash = jitterSHA(normalized)
        let profile = try JitterConfiguration(
            sampleRate: item.sampleRate, inputPrecision: item.precision)
        configuration = profile
        let pulseProfile = try PulseConfiguration(
            sampleRate: item.sampleRate, inputPrecision: item.precision,
            pitchCeilingHz: fixture.reference.pitch.ceilingHz)
        pulseConfiguration = pulseProfile
        let pitch = fixture.reference.pitch
        let contour = try PulseF0Contour(
            sampleRate: item.sampleRate, sampleCount: samples.count,
            firstCenterSeconds: pitch.firstCenterSeconds, stepSeconds: pitch.stepSeconds,
            ceilingHz: pitch.ceilingHz, frequenciesHz: pitch.frequenciesHz)
        self.contour = contour
        let source = try SourceInterval(
            epoch: StreamEpoch(
                streamID:
                    UUID(uuidString: "00000000-0000-0000-0000-000000000050")!),
            startSample: 0, sampleCount: Int64(samples.count), sampleRate: Double(item.sampleRate))
        let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        inputTiming = timing
        let pipeline = try PreparedPCMJitter<S>(
            configuration: profile, pulseConfiguration: pulseProfile,
            maximumSampleCount: samples.count, maximumF0FrameCount: contour.frequenciesHz.count,
            maximumTrackingAttempts: 4096)
        self.pipeline = pipeline
        pulse = try PreparedPulseTracker(
            configuration: pulseProfile, maximumSampleCount: samples.count,
            maximumF0FrameCount: contour.frequenciesHz.count, maximumTrackingAttempts: 4096)
        statistics = try PreparedJitter(
            configuration: profile,
            maximumPeriodCount: contour.frequenciesHz.count + 4096)
        var periods: [JitterPeriodInput] = []
        var referenceResult: JitterAnalysisResult?
        try samples.withUnsafeBufferPointer { buffer in
            try pipeline.analyze(buffer, contour: contour, timing: timing) { output in
                periods = try output.snapshotPeriods(maximumCount: 30_000)
                referenceResult = output.result
            }
        }
        guard let referenceResult else { throw JitterWorkloadError.mismatch }
        mappedPeriods = periods
        statisticsTiming = referenceResult.dependencyTiming
        provenance = referenceResult.inputProvenance
    }

    @inline(never) func prepare() throws -> AnyObject {
        try PreparedPCMJitter<S>(
            configuration: configuration, pulseConfiguration: pulseConfiguration,
            maximumSampleCount: pcm.count, maximumF0FrameCount: contour.frequenciesHz.count,
            maximumTrackingAttempts: maximumTrackingAttempts)
    }

    func prepareRun(_ operation: JitterOperation) throws {
        last = nil
        switch operation {
        case .prepare: break
        case .pulseOnly: try pulse.reset()
        case .pcmCombined: try pipeline.reset()
        case .statisticsOnly: try statistics.reset()
        default: throw JitterWorkloadError.unsupportedOperation
        }
    }

    private func pulseChecksum(_ output: BorrowedPulseOutput) -> Double {
        var checksum = Double(output.result.rawPulseCount + output.result.trackingAttemptCount)
        for p in output.landmarks { checksum += p.timeSeconds + Double(p.rejections.rawValue) }
        for p in output.periods { checksum += p.durationSeconds + Double(p.rejections.rawValue) }
        return checksum
    }

    @inline(never) func run(_ operation: JitterOperation) throws -> Double {
        var checksum = 0.0
        switch operation {
        case .pulseOnly:
            try pcm.withUnsafeBufferPointer { buffer in
                try pulse.analyze(buffer, contour: contour, timing: inputTiming) { output in
                    checksum = pulseChecksum(output)
                }
            }
        case .pcmCombined:
            try pcm.withUnsafeBufferPointer { buffer in
                try pipeline.analyze(buffer, contour: contour, timing: inputTiming) { output in
                    last = output.result
                    checksum = pulseChecksum(output.pulses) + jitterChecksum(output.result)
                }
            }
        case .statisticsOnly:
            let result = try mappedPeriods.withUnsafeBufferPointer {
                try statistics.analyze(
                    $0, dependencyTiming: statisticsTiming, provenance: provenance)
            }
            last = result
            checksum = jitterChecksum(result)
        default: throw JitterWorkloadError.unsupportedOperation
        }
        return checksum
    }

    func verify() throws -> JitterEvidence {
        try prepareRun(.pcmCombined)
        let combined = try run(.pcmCombined)
        guard let result = last else { throw JitterWorkloadError.mismatch }
        try prepareRun(.pcmCombined)
        guard try run(.pcmCombined) == combined, last == result else {
            throw JitterWorkloadError.mismatch
        }
        try prepareRun(.statisticsOnly)
        let stats = try run(.statisticsOnly)
        guard last == result else { throw JitterWorkloadError.mismatch }
        try prepareRun(.pulseOnly)
        let pulseSum = try run(.pulseOnly)
        var times: [Double] = []
        try pcm.withUnsafeBufferPointer { buffer in
            try pulse.analyze(buffer, contour: contour, timing: inputTiming) { output in
                times = output.landmarks.map(\.timeSeconds)
            }
        }
        guard times.count == fixture.reference.data.pulseTimesSeconds.count,
            mappedPeriods.count == max(0, times.count - 1)
        else { throw JitterWorkloadError.mismatch }
        let error =
            zip(times, fixture.reference.data.pulseTimesSeconds).map {
                abs($0 - $1) * Double(item.sampleRate)
            }.max() ?? 0
        let checksums = [
            JitterOperation.pcmCombined.rawValue: combined,
            JitterOperation.pulseOnly.rawValue: pulseSum,
            JitterOperation.statisticsOnly.rawValue: stats,
        ]
        guard error <= 1e-6, checksums.values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw JitterWorkloadError.mismatch
        }
        let pcmEvidence = try JitterPCMEvidence(
            fixture: fixtureName, fixtureSHA256: fixtureHash,
            encodedInputSHA256: fixture.reference.inputSHA256,
            normalizedInputSHA256: normalizedHash,
            sampleCount: pcm.count, f0FrameCount: contour.frequenciesHz.count,
            f0FirstCenterSeconds: contour.firstCenterSeconds, f0StepSeconds: contour.stepSeconds,
            pulseConfiguration: pulseConfiguration, pulseProfile: pulseConfiguration.identity(),
            contourIdentity: contour.identity(),
            preparedPulseBufferBytes: pulse.executionStatistics.preparedBufferBytes,
            preparedStatisticsBufferBytes: statistics.executionStatistics.preparedBufferBytes,
            preparedContourBytes: contour.frequenciesHz.count * MemoryLayout<Double>.stride,
            rawPulseTimesSeconds: times, mappedPeriods: mappedPeriods,
            maximumReferenceErrorSamples: error)
        return try JitterEvidence(
            name: item.name, workload: item, configuration: configuration,
            profileIdentity: configuration.identity(), operations: item.operations.map(\.rawValue),
            inputPeriodCount: mappedPeriods.count, measuredPeriodUpdates: 0, windowSampleCount: nil,
            frameSampleCount: pcm.count, hopDefinition: "wholeDeclaredInterval",
            preparedCombinedBufferBytes: pipeline.preparedBufferBytes,
            preparedSeparateBufferBytes: 0,
            preparedInputBytes: pcm.count * MemoryLayout<S>.stride
                + mappedPeriods.count * MemoryLayout<JitterPeriodInput>.stride,
            periodInputSHA256: jitterPeriodHash(mappedPeriods), result: result,
            checksums: checksums, sumTreeNodeUpdates: nil,
            observedAppendCount: nil, observedQueryCount: nil, pcm: pcmEvidence)
    }
}
