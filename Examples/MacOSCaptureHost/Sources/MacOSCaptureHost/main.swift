import AVFAudio
import AVFoundation
import Darwin
import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

private enum HostError: Error {
    case arguments, permission, existingDestination, captureGap, callbackFailure
}

/// Development-only executable wrapped in an independently signed app bundle.
/// Neither the default invocation nor the build script requests microphone access.
@main struct CaptureHost {
    @MainActor static func main() async {
        do { try await run() } catch {
            let message = "Capture host failed: \(HostErrorReport.message(for: error)).\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--self-test-error-reporting"] {
            // A pure error-boundary probe: no engine, permission, input, or file access.
            throw NSError(
                domain: "SYNTHETIC-PRIVATE-DEVICE-UID", code: 28,
                userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC-PRIVATE-DESCRIPTION"])
        }
        if args == ["--request-permission"] {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            print(allowed ? "Microphone authorized" : "Microphone denied")
            if !allowed { throw HostError.permission }
            return
        }
        guard args.count == 4, args[0] == "--record", args[2] == "--seconds",
            let seconds = Double(args[3]), seconds.isFinite, (0.1...300).contains(seconds),
            args[1].hasPrefix("/"), args[1].hasSuffix(".caf")
        else {
            print("Use --request-permission, or --record /absolute/path/sample.caf --seconds 5")
            return
        }
        let url = URL(fileURLWithPath: args[1])
        let receipt = url.appendingPathExtension("json")
        guard !FileManager.default.fileExists(atPath: url.path),
            !FileManager.default.fileExists(atPath: receipt.path)
        else { throw HostError.existingDestination }
        var stoppedUnexpectedly = false
        let capture = MacOSMicrophoneCapture { event in
            switch event {
            case .failed, .configurationChanged: stoppedUnexpectedly = true
            default: break
            }
        }
        let session = try capture.start(
            request: CaptureRequest(channelSelection: .arithmeticMean, processing: .measurement),
            buffering: MacOSCaptureBuffering())
        defer { capture.stop() }
        let writer = Task.detached { try await record(session, to: url) }
        let deadline = Task { @MainActor in
            try await Task.sleep(for: .seconds(seconds))
            capture.stop()
        }
        defer { deadline.cancel() }
        do {
            let frames = try await writer.value
            try await capture.finish()
            guard !stoppedUnexpectedly else { throw HostError.callbackFailure }
            let observed = session.observation
            // Only the explicitly requested local recording destination receives this receipt.
            // Device UID stays local to the session and is deliberately omitted from the file.
            let metadata: [String: Any] = [
                "schemaVersion": 1, "status": "completed", "frames": frames,
                "sampleRate": observed.effectiveFormat.sampleRate,
                "channels": observed.effectiveFormat.channelCount,
                "encoding": observed.effectiveFormat.encoding.rawValue,
                "layout": observed.effectiveFormat.layout.rawValue,
                "requestedSeconds": seconds,
                "sourceIdentityKnown": observed.input.deviceIdentifier != .unknown,
                "overflowChunks": session.transfer.snapshot().overflowChunks,
                "oversizedChunks": session.transfer.snapshot().oversizedChunks,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "evidence":
                    "Explicit host recording; operator must separately label built-in/external hardware.",
            ]
            try JSONSerialization.data(
                withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]
            )
            .write(to: receipt, options: .atomic)
            print(
                "Capture completed; inspect the local CAF and JSON receipt before accepting evidence."
            )
        } catch {
            capture.stop()
            writer.cancel()
            _ = await writer.result
            try? JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 1, "status": "failed",
                    "note":
                        "Partial CAF is not accepted evidence. Inspect operator logs and repeat.",
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: receipt, options: .atomic)
            throw error
        }
    }

    private static func record(_ session: MacOSCaptureSession, to url: URL) async throws -> UInt64 {
        let configuration = session.transfer.configuration
        let common: AVAudioCommonFormat =
            configuration.format.encoding == .float32 ? .pcmFormatFloat32 : .pcmFormatFloat64
        guard
            let format = AVAudioFormat(
                commonFormat: common, sampleRate: configuration.format.sampleRate,
                channels: AVAudioChannelCount(configuration.format.channelCount),
                interleaved: configuration.format.layout == .interleaved),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: configuration.maximumFramesPerChunk)
        else { throw HostError.arguments }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: common,
            interleaved: format.isInterleaved)
        var frames: UInt64 = 0
        while !Task.isCancelled {
            var writeError: (any Error)?
            let result = session.transfer.withNext { event in
                switch event {
                case .gap: writeError = HostError.captureGap
                case .block(let block):
                    buffer.frameLength = block.frameCount
                    buffer.withUnsafeAudioBufferList { list in
                        let destination = UnsafeMutableAudioBufferListPointer(
                            UnsafeMutablePointer(mutating: list))
                        let planeBytes = Int(block.frameCount) * configuration.bytesPerSample
                        for index in destination.indices {
                            let bytes =
                                planeBytes
                                * (format.isInterleaved ? configuration.format.channelCount : 1)
                            destination[index].mData!.copyMemory(
                                from: block.bytes.baseAddress!.advanced(by: index * planeBytes),
                                byteCount: bytes)
                        }
                    }
                    do {
                        try file.write(from: buffer)
                        frames += UInt64(block.frameCount)
                    } catch { writeError = error }
                }
            }
            if let writeError { throw writeError }
            if result == .finished { return frames }
            if result == .empty { try await Task.sleep(for: .milliseconds(10)) }
            if result == .concurrentConsumer { throw HostError.captureGap }
        }
        throw CancellationError()
    }
}
