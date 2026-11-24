import CryptoKit
import Foundation
import HDXLVoiceProcessing

// A stand-alone consumer of the production library. Read typed mono PCM and emit public
// rows with their actual source positions for comparison with the combined benchmark.
struct Frame: Encodable {
    let lane: String
    let sourceStart: Int64
    let value: Double?
    let status: String
    let reason: UnavailabilityReason?
}
struct Replay: Encodable {
    let pcmSHA256, cppsProfileSHA256, yinProfileSHA256: String
    let firstValidCPPSAfterSamples: Int?
    let frames: [Frame]
}
enum ReplayError: Error { case invalidArguments, invalidPCM }

func replay() throws -> Replay {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2, let chunk = Int(args[1]), chunk > 0 else {
        throw ReplayError.invalidArguments
    }
    let data = try Data(contentsOf: URL(filePath: args[0]))
    guard !data.isEmpty, data.count.isMultiple(of: 8), data.count <= 16_000 * 8 else {
        throw ReplayError.invalidPCM
    }
    let samples = data.withUnsafeBytes { raw in
        (0..<data.count / 8).map {
            Double(
                bitPattern: UInt64(
                    littleEndian: raw.loadUnaligned(fromByteOffset: 8 * $0, as: UInt64.self)))
        }
    }
    let epoch = StreamEpoch(streamID: UUID())
    let recipe = try CPPSProfile(
        cepstrogram: .init(
            sourceSampleRate: 16000, inputPrecision: .float64,
            hopSeconds: 0.01, declaredInputBandwidthHz: 8000,
            conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9)),
        settings: .init(
            timeWindowSeconds: 0.02,
            prominence: .init(
                pitchCeilingHz: 330, fitEndSeconds: 0,
                fitMethod: .praat7002Robust)))
    let yin = try YINConfiguration(
        sampleRate: 16000, pitchFloorHz: 50, pitchCeilingHz: 700,
        integrationLength: 479, hopLength: 160)
    let cepstral = try PreparedPreviewCPPS<Double>(profile: recipe, epoch: epoch)
    let pitch = try PreparedYINAnalyzer<Double>(profile: .init(estimator: yin), epoch: epoch)
    var frames: [Frame] = []
    var delivered = 0
    var firstValidCPPS: Int?
    func consume(_ value: BorrowedCPPSOutput) {
        let source = value.result.context.timing.source
        if firstValidCPPS == nil, value.result.observation != nil { firstValidCPPS = delivered }
        frames.append(
            Frame(
                lane: "cpps", sourceStart: source.startSample,
                value: value.result.observation?.prominenceDB,
                status: value.result.observation == nil ? "unavailable" : "available",
                reason: value.result.unavailability))
        let raw = value.result.rawCPP
        frames.append(
            Frame(
                lane: "cpp", sourceStart: raw.context.timing.source.startSample,
                value: raw.observation?.prominenceDB,
                status: raw.observation == nil ? "unavailable" : "available",
                reason: raw.unavailability))
    }
    func consumePitch(_ value: BorrowedYINAnalysisOutput) {
        let result = value.raw.result
        frames.append(
            Frame(
                lane: "yin", sourceStart: result.timing.source.startSample,
                value: result.observation?.frequencyHz, status: result.status.rawValue,
                reason: result.unavailability))
    }
    try samples.withUnsafeBufferPointer { input in
        var start = 0
        while start < input.count {
            let count = min(chunk, input.count - start)
            let span = try SourceInterval(
                epoch: epoch, startSample: Int64(start), sampleCount: Int64(count),
                sampleRate: 16000)
            let part = UnsafeBufferPointer(rebasing: input[start..<(start + count)])
            delivered = start + count
            _ = try cepstral.process(part, interval: span, emit: consume)
            _ = try pitch.process(part, interval: span, emit: consumePitch)
            start += count
        }
    }
    _ = try cepstral.finish(emit: consume)
    _ = try pitch.finish(emit: consumePitch)
    return try Replay(
        pcmSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
        cppsProfileSHA256: recipe.identity().sha256, yinProfileSHA256: yin.identity().sha256,
        firstValidCPPSAfterSamples: firstValidCPPS, frames: frames)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(replay()))
FileHandle.standardOutput.write(Data([10]))
