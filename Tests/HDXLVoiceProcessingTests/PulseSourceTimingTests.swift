import CryptoKit
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct PulseSourceCertificate: Decodable {
    struct Case: Decodable {
        let name: String
        let sampleRate, sampleCount: Int
        let inputPrecision: AnalysisPrecision
    }
    struct Pitch: Decodable {
        let firstCenterSeconds, stepSeconds, ceilingHz: Double
        let frequenciesHz: [Double]
    }
    struct Budget: Decodable {
        let definition: String
        let radiusSamples: Double
    }
    struct Point: Decodable {
        let sourceIndex: Int
        let sourceTimeSeconds: Double
        let algorithmTimeSeconds: [Double]
    }
    let schemaVersion: Int
    let definition, inputSHA256: String
    let `case`: Case
    let pitch: Pitch
    let budget: Budget
    let seedSourceIndex: Int
    let points: [Point]
    let maximumSourceErrorSamples, maximumEnclosureWidthSamples: Double
}

private struct PulseSourceTimingAudit: Encodable {
    let name: String
    let support: PulseSupportDefinition
    let inputSHA256: String
    let profile: ProfileIdentity
    let sourceTimes, nativeTimes: [Double]
    let maximumSourceErrorSamples, maximumCertifiedSourceErrorSamples: Double
    let sourceRadiusSamples, maximumEnclosureWidthSamples: Double
}

private func sourceTimingDirectory(_ name: String, override: String) throws -> URL {
    if let value = ProcessInfo.processInfo.environment[override] {
        try #require(!value.isEmpty, "Explicit certificate paths cannot be empty")
        return URL(filePath: value, directoryHint: .isDirectory)
    }
    return try #require(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

private func comparePulseSource<Sample: BinaryFloatingPoint & Sendable>(
    _ certificate: PulseSourceCertificate, samples: [Sample], support: PulseSupportDefinition
) throws -> PulseSourceTimingAudit {
    let item = certificate.case
    let configuration = try PulseConfiguration(
        sampleRate: item.sampleRate, inputPrecision: item.inputPrecision,
        pitchCeilingHz: certificate.pitch.ceilingHz, support: support)
    let contour = try PulseF0Contour(
        sampleRate: item.sampleRate, sampleCount: samples.count,
        firstCenterSeconds: certificate.pitch.firstCenterSeconds,
        stepSeconds: certificate.pitch.stepSeconds, ceilingHz: certificate.pitch.ceilingHz,
        frequenciesHz: certificate.pitch.frequenciesHz)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: Int64.max - Int64(samples.count),
        sampleCount: Int64(samples.count), sampleRate: Double(item.sampleRate))
    let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
    var captured: PulseSnapshot?
    if support == .completeInterval {
        let worker = try PreparedPulseTracker<Sample>(
            configuration: configuration, maximumSampleCount: samples.count,
            maximumF0FrameCount: contour.frequenciesHz.count, maximumTrackingAttempts: 4096)
        try samples.withUnsafeBufferPointer {
            try worker.analyze($0, contour: contour, timing: timing) {
                captured = try $0.snapshot(maximumRecordCount: 30000)
            }
        }
    } else {
        let stream = try PreparedPulseStream<Sample>(
            configuration: configuration, contour: contour, timing: timing,
            maximumTrackingAttempts: 4096)
        try samples.withUnsafeBufferPointer { input in
            for start in stride(from: 0, to: input.count, by: 137) {
                let end = min(input.count, start + 137)
                let interval = try SourceInterval(
                    epoch: source.epoch, startSample: source.startSample + Int64(start),
                    sampleCount: Int64(end - start), sampleRate: source.sampleRate)
                try stream.append(
                    UnsafeBufferPointer(rebasing: input[start..<end]), interval: interval)
            }
        }
        try stream.finish { captured = try $0.snapshot(maximumRecordCount: 30000) }
    }
    let snapshot = try #require(captured)
    try #require(snapshot.landmarks.count == certificate.points.count, "\(item.name): source count")
    #expect(snapshot.landmarks.filter { $0.direction == .seed }.count == 1)
    #expect(snapshot.landmarks[certificate.seedSourceIndex].direction == .seed)
    var maximumError = 0.0
    for (index, pair) in zip(snapshot.landmarks, certificate.points).enumerated() {
        let (landmark, point) = pair
        try #require(point.sourceIndex == index && point.algorithmTimeSeconds.count == 2)
        let lower = point.algorithmTimeSeconds[0]
        let upper = point.algorithmTimeSeconds[1]
        try #require(lower < upper)
        #expect(
            lower <= landmark.timeSeconds && landmark.timeSeconds <= upper,
            "\(item.name)/\(index)/\(support): \(landmark.timeSeconds) outside [\(lower), \(upper)]"
        )
        let error = abs(landmark.timeSeconds - point.sourceTimeSeconds) * Double(item.sampleRate)
        maximumError = max(maximumError, error)
        #expect(error <= certificate.budget.radiusSamples, "\(item.name): source timing radius")
    }
    return PulseSourceTimingAudit(
        name: item.name, support: support, inputSHA256: certificate.inputSHA256,
        profile: snapshot.result.profile, sourceTimes: certificate.points.map(\.sourceTimeSeconds),
        nativeTimes: snapshot.landmarks.map(\.timeSeconds), maximumSourceErrorSamples: maximumError,
        maximumCertifiedSourceErrorSamples: certificate.maximumSourceErrorSamples,
        sourceRadiusSamples: certificate.budget.radiusSamples,
        maximumEnclosureWidthSamples: certificate.maximumEnclosureWidthSamples)
}

@Test func pulseGeneratedSourceTimingFitsIndependentFiniteInputCertificates() throws {
    let directory = try sourceTimingDirectory(
        "PulseSourceTiming", override: "HDXL_PULSE_SOURCE_TIMING_DIRECTORY")
    let inputDirectory = try sourceTimingDirectory(
        "Pulses", override: "HDXL_PULSE_REFERENCE_DIRECTORY")
    struct Manifest: Decodable { let cases: [String] }
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
    var names = Set<String>()
    for precision in ["float32", "float64"] {
        for rate in [16000, 44100, 48000] {
            for hz in [80, 150, 300, 600] { names.insert("gaussian-\(rate)-\(hz)-\(precision)") }
        }
        for stem in [
            "inverted", "quiet", "jitter-1pct", "jitter-12pct", "modulated", "alternating",
        ] { names.insert("\(stem)-\(precision)") }
    }
    try #require(manifest.cases.count == 36 && Set(manifest.cases) == names)
    var rows: [PulseSourceTimingAudit] = []
    for name in manifest.cases {
        let certificate = try JSONDecoder().decode(
            PulseSourceCertificate.self,
            from: Data(contentsOf: directory.appending(path: name + ".json")))
        try #require(certificate.schemaVersion == 1 && certificate.case.name == name)
        try #require(certificate.definition == "finite-input-gaussian-pulse-enclosure-v1")
        try #require(certificate.budget.definition == "finite-gaussian-source-radius-v1")
        try #require(certificate.points.indices.contains(certificate.seedSourceIndex))
        let wave = try Data(contentsOf: inputDirectory.appending(path: name + ".wav"))
        let sha = SHA256.hash(data: wave).map { String(format: "%02x", $0) }.joined()
        try #require(sha == certificate.inputSHA256)
        let pcm = try CorpusPCM(data: wave)
        try #require(
            pcm.sampleRate == certificate.case.sampleRate
                && pcm.samples.count == certificate.case.sampleCount)
        for support in [PulseSupportDefinition.completeInterval, .independentlyAnchoredBlock] {
            switch certificate.case.inputPrecision {
            case .float32:
                rows.append(
                    try comparePulseSource(
                        certificate, samples: pcm.samples.map(Float.init), support: support))
            case .float64:
                rows.append(
                    try comparePulseSource(certificate, samples: pcm.samples, support: support))
            }
        }
    }
    #expect(rows.count == 72 && rows.reduce(0) { $0 + $1.nativeTimes.count } == 8580)
    if let path = ProcessInfo.processInfo.environment["HDXL_PULSE_SOURCE_TIMING_REPORT"] {
        try #require(!path.isEmpty)
        try canonicalContractJSON(rows).write(to: URL(filePath: path), options: .atomic)
    }
}
