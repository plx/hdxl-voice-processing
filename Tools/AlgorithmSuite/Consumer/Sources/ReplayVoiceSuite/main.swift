import CryptoKit
import Foundation
import HDXLVoiceProcessing

// A stand-alone consumer of the production library. Read typed mono PCM and emit public
// rows with their actual source positions for comparison with the combined benchmark.
struct Frame: Encodable {
    let lane: String
    let sourceStart: Int64
    let value: Double?
}
struct Replay: Encodable {
    let pcmSHA256, cppsProfileSHA256, yinProfileSHA256: String
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
    func consume(_ value: BorrowedCPPSOutput) {
        let source = value.result.context.timing.source
        frames.append(
            Frame(
                lane: "cpps", sourceStart: source.startSample,
                value: value.result.observation?.prominenceDB))
        frames.append(
            Frame(
                lane: "cpp", sourceStart: source.startSample,
                value: value.result.rawCPP.observation?.prominenceDB))
    }
    func consumePitch(_ value: BorrowedYINAnalysisOutput) {
        let result = value.raw.result
        frames.append(
            Frame(
                lane: "yin", sourceStart: result.timing.source.startSample,
                value: result.observation?.frequencyHz))
    }
    try samples.withUnsafeBufferPointer { input in
        var start = 0
        while start < input.count {
            let count = min(chunk, input.count - start)
            let span = try SourceInterval(
                epoch: epoch, startSample: Int64(start), sampleCount: Int64(count),
                sampleRate: 16000)
            let part = UnsafeBufferPointer(rebasing: input[start..<(start + count)])
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
        frames: frames)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(replay()))
FileHandle.standardOutput.write(Data([10]))
