import AVFAudio
import Foundation
import HDXLVoiceProcessing

/// One foreground segment, analyzed off the main actor after recording ends.
struct SegmentLevel: Codable, Sendable {
    let frames: Int
    let sampleRate: Int
    let channels: UInt32
    let fileFormatID: UInt32
    let windows: UInt64
    let profileSHA256: String
    let lastWindow: DigitalLevel?

    enum Failure: Error { case unsupportedFormat, invalidLength, incompleteRead, invalidFixture }

    static func read(_ url: URL) throws -> Self {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.channelCount == 1, let rate = Int(exactly: format.sampleRate),
            (4_000...192_000).contains(rate)
        else { throw Failure.unsupportedFormat }
        let length = file.length
        guard length > 0, length <= Int64(rate * 4) else { throw Failure.invalidLength }
        let epoch = StreamEpoch(streamID: UUID())
        let window = rate / 10
        let configuration = try LevelConfiguration(
            sampleRate: rate, inputPrecision: .float32,
            windowLength: window, hopLength: window, accumulation: .direct, weighting: .none,
            partialWindowPolicy: .discard)
        let worker = try PreparedLevelAnalyzer<Float>(configuration: configuration, epoch: epoch)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            throw Failure.unsupportedFormat
        }
        var frames: Int64 = 0
        var last: DigitalLevel?
        while frames < length {
            try file.read(into: buffer, frameCount: UInt32(min(1024, length - frames)))
            let count = Int(buffer.frameLength)
            guard count > 0, let samples = buffer.floatChannelData?[0] else {
                throw Failure.incompleteRead
            }
            let interval = try SourceInterval(
                epoch: epoch, startSample: frames,
                sampleCount: Int64(count), sampleRate: format.sampleRate)
            try worker.process(
                UnsafeBufferPointer(start: samples, count: count), interval: interval
            ) {
                last = $0.unweighted.digitalLevel
            }
            frames += Int64(count)
        }
        let completion = try worker.finish { _ in }
        return Self(
            frames: Int(frames), sampleRate: rate, channels: file.fileFormat.channelCount,
            fileFormatID: file.fileFormat.streamDescription.pointee.mFormatID,
            windows: completion.completeWindowCount, profileSHA256: worker.identity.sha256,
            lastWindow: last)
    }

    /// A half-scale square wave has exactly -6.0206 dBFS RMS in every window.
    static func replay() throws -> Self {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
            let samples = buffer.floatChannelData?[0]
        else { throw Failure.invalidFixture }
        buffer.frameLength = 16_000
        for index in 0..<16_000 { samples[index] = index % 80 < 40 ? 0.5 : -0.5 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let result = try read(url)
        guard result.frames == 16_000, result.windows == 10,
            let db = result.lastWindow?.finiteDecibels, abs(db + 6.020599913) < 0.000001
        else { throw Failure.invalidFixture }
        return result
    }
}
