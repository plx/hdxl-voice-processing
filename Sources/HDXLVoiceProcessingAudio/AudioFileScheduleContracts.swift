import AVFAudio
import Foundation
import HDXLVoiceProcessing

public enum AudioFileScheduleError: Error, Sendable, Equatable {
    case formatMismatch, invalidRange, invalidCapacity, unexpectedEndOfFile, invalidDecodedBuffer
}

/// Scalar copy of the on-disk ASBD, distinct from the decoder's PCM output.
public struct AudioFileStorageFormat: Sendable, Hashable, Codable {
    public let sampleRate: Double
    public let formatID: UInt32
    public let formatFlags: UInt32
    public let bytesPerPacket: UInt32
    public let framesPerPacket: UInt32
    public let bytesPerFrame: UInt32
    public let channelsPerFrame: UInt32
    public let bitsPerChannel: UInt32

    init(_ format: AVAudioFormat) {
        let d = format.streamDescription.pointee
        sampleRate = d.mSampleRate
        formatID = d.mFormatID
        formatFlags = d.mFormatFlags
        bytesPerPacket = d.mBytesPerPacket
        framesPerPacket = d.mFramesPerPacket
        bytesPerFrame = d.mBytesPerFrame
        channelsPerFrame = d.mChannelsPerFrame
        bitsPerChannel = d.mBitsPerChannel
    }
}

/// AVAudioFile performs codec/PCM decoding into the explicitly requested Float32
/// or Float64 layout. Sample rate and channel count must already match the recipe;
/// numerical resampling/channel selection remains inside the shared scheduler.
public struct AudioFileDecodingProvenance: Sendable, Hashable {
    public let url: URL
    public let storage: AudioFileStorageFormat
    public let decodedPCM: PCMFormat
    public let fileSampleCount: Int64
    public let decoderIdentifier: String
    public let platformVersion: String
}

public struct AudioFileScheduledFrame: Sendable, Hashable {
    public let frame: ScheduledFrame
    public let decoding: AudioFileDecodingProvenance
}

public enum AudioFileScheduleCompletion: Sendable, Hashable {
    case analyzed(AnalysisScheduleCompletion)
    case masked(MaskedScheduleCompletion)
    case cancelled(source: SourceInterval, coverage: AnalysisCoverageCounts)
}

public struct AudioFileScheduleProgress: Sendable, Hashable {
    public let decodedSampleCount: Int64
    /// Includes explicitly skipped missing-acquisition intervals in a supplied mask.
    public let advancedSourceSamples: Int64
    public let isFinished: Bool
    public let isCancelled: Bool
}
