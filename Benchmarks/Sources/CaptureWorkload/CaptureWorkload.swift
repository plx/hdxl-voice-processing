import AVFAudio
import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

public struct CaptureCase: Codable, Sendable {
    public let encoding: String
    public let layout: String
    public let frames: UInt32
    public let operation: String
    public var name: String { "Capture.\(operation).\(encoding)-\(layout)-c2-n\(frames)" }
    public static let matrix: [CaptureCase] = ["float32", "float64"].flatMap { encoding in
        ["planar", "interleaved"].flatMap { layout in
            [UInt32(64), 4096].flatMap { frames in
                ["Accepted", "UnknownClock", "Overflow", "Oversized", "ChangedFormat"].map {
                    CaptureCase(encoding: encoding, layout: layout, frames: frames, operation: $0)
                }
            }
        }
    }
}

/// Synthetic native-buffer adapter measurement. Storage, SDK objects, and checks
/// are outside the measured region; `run` calls the production bridge exactly once.
public final class CaptureBatch {
    public let item: CaptureCase
    private let buffer: AVReadOnlyAudioPCMBuffer
    private let time: AVAudioTime
    private let format: PCMFormat
    private var tap: PreparedCaptureTap!

    public init(item: CaptureCase) throws {
        self.item = item
        format = try PCMFormat(
            sampleRate: 48000, channelCount: 2,
            encoding: item.encoding == "float32" ? .float32 : .float64,
            layout: item.layout == "planar" ? .planar : .interleaved)
        let native = AVAudioFormat(
            commonFormat: item.encoding == "float32" ? .pcmFormatFloat32 : .pcmFormatFloat64,
            sampleRate: item.operation == "ChangedFormat" ? 44100 : 48000, channels: 2,
            interleaved: item.layout == "interleaved")!
        let mutable = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: item.frames)!
        mutable.frameLength = item.frames
        mutable.withUnsafeAudioBufferList { list in
            let planes = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            let width = item.encoding == "float32" ? 4 : 8
            for plane in planes {
                for offset in stride(from: 0, to: Int(plane.mDataByteSize), by: width) {
                    if width == 4 {
                        plane.mData!.storeBytes(
                            of: Float(0.25), toByteOffset: offset, as: Float.self)
                    } else {
                        plane.mData!.storeBytes(
                            of: Double(0.25), toByteOffset: offset, as: Double.self)
                    }
                }
            }
        }
        buffer = AVReadOnlyAudioPCMBuffer(unsafeRetaining: mutable)
        var timestamp = AudioTimeStamp()
        if item.operation != "UnknownClock" {
            timestamp.mFlags = [.sampleTimeValid, .hostTimeValid]
            timestamp.mSampleTime = 0
            timestamp.mHostTime = 123
        }
        time = AVAudioTime(audioTimeStamp: &timestamp, sampleRate: 48000)
    }

    public func prepareIteration() throws {
        let transfer = PCMTransfer(
            configuration: try PCMTransferConfiguration(
                format: format,
                epoch: StreamEpoch(streamID: UUID()),
                maximumFramesPerChunk: item.operation == "Oversized"
                    ? item.frames / 2 : item.frames,
                slotCount: 2))
        tap = PreparedCaptureTap(transfer: transfer)
        if item.operation == "Overflow" {
            tap.accept(buffer, at: time)
            tap.accept(buffer, at: time)
        }
    }

    @inline(never) public func run() { tap.accept(buffer, at: time) }

    public func verify() -> Bool {
        let snapshot = tap.transfer.snapshot()
        switch item.operation {
        case "Overflow":
            guard snapshot.overflowChunks == 1, snapshot.acceptedChunks == 2 else { return false }
        case "Oversized":
            guard snapshot.oversizedChunks == 1, snapshot.acceptedChunks == 0 else { return false }
        case "ChangedFormat":
            return tap.failure == .formatChanged && snapshot.isClosed
                && snapshot.acceptedChunks == 0
        default: guard snapshot.acceptedChunks == 1 else { return false }
        }
        tap.transfer.close()
        var valid = true
        var blocks = 0
        var gaps = 0
        while tap.transfer.withNext({ event in
            switch event {
            case .gap: gaps += 1
            case .block(let block):
                blocks += 1
                valid = valid && block.frameCount == item.frames
                valid =
                    valid && ((block.deviceSampleTime == nil) == (item.operation == "UnknownClock"))
                valid =
                    valid
                    && ((block.hostStartNanoseconds == nil) == (item.operation == "UnknownClock"))
                let width = item.encoding == "float32" ? 4 : 8
                for offset in stride(from: 0, to: block.bytes.count, by: width) {
                    let value =
                        width == 4
                        ? Double(block.bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
                        : block.bytes.loadUnaligned(fromByteOffset: offset, as: Double.self)
                    valid = valid && value == 0.25
                }
            }
        }) == .delivered {}
        let expected = item.operation == "Overflow" ? 2 : item.operation == "Oversized" ? 0 : 1
        return valid && blocks == expected
            && (gaps > 0) == ["Overflow", "Oversized"].contains(item.operation)
    }
}
