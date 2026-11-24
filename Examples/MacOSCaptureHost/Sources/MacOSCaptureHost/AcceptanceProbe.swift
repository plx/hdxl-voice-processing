import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

/// Development host only. All counters are collected on the consumer side of the tap.
enum AcceptanceProbe {
    enum Failure: Error { case arguments, consumerConflict, captureFailed, inputChanged }

    struct Counts: Codable, Sendable {
        var blocks = 0
        var frames = 0
        var knownGapFrames: Int64 = 0
        var unknownGaps = 0
    }

    static func drain(_ transfer: PCMTransfer) async throws -> Counts {
        var counts = Counts()
        while true {
            try Task.checkCancellation()
            var overflow = false
            let result = transfer.withNext { event in
                switch event {
                case .block(let block):
                    counts.blocks += 1
                    counts.frames += Int(block.frameCount)
                case .gap(let gap):
                    if let missing = gap.missingSource {
                        let sum = counts.knownGapFrames.addingReportingOverflow(missing.frameCount)
                        overflow = sum.overflow
                        counts.knownGapFrames = sum.partialValue
                    } else {
                        counts.unknownGaps += 1
                    }
                }
            }
            guard !overflow else { throw Failure.captureFailed }
            switch result {
            case .finished: return counts
            case .empty: try await Task.sleep(for: .milliseconds(5))
            case .concurrentConsumer: throw Failure.consumerConflict
            case .delivered: break
            }
        }
    }

    @MainActor static func run(_ args: [String]) async throws {
        guard args.count == 6, args[0] == "--capture-check", args[1].hasPrefix("/"),
            args[1].hasSuffix(".json"), args[2] == "--seconds", let seconds = Double(args[3]),
            seconds.isFinite, (0.1...3600).contains(seconds), args[4] == "--runs",
            let repetitions = Int(args[5]), (1...30).contains(repetitions)
        else { throw Failure.arguments }
        let destination = URL(fileURLWithPath: args[1])
        var runs: [[String: Any]] = []
        let startedAt = Date.now.formatted(.iso8601)
        let startNS = DispatchTime.now().uptimeNanoseconds
        func save(_ status: String, error: String? = nil, new: Bool = false) throws {
            var report: [String: Any] = [
                "schemaVersion": 1, "status": status, "operation": "capture-only",
                "requestedRuns": repetitions, "requestedSecondsPerRun": seconds, "runs": runs,
                "startedAtUTC": startedAt,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "revision": Bundle.main.object(forInfoDictionaryKey: "HDXLCaptureRevision")
                    as? String ?? "unavailable",
                "sourceState": Bundle.main.object(forInfoDictionaryKey: "HDXLCaptureSourceState")
                    as? String ?? "unavailable",
            ]
            if let error { report["failure"] = error }
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: destination, options: new ? .withoutOverwriting : .atomic)
        }
        try save("running", new: true)
        var inputChanged = false
        let capture = MacOSMicrophoneCapture { event in
            switch event {
            case .configurationChanged: inputChanged = true
            default: break
            }
        }
        do {
            for _ in 0..<repetitions {
                inputChanged = false
                let session = try capture.start(
                    request: CaptureRequest(
                        channelSelection: .arithmeticMean, processing: .measurement),
                    buffering: MacOSCaptureBuffering())
                let start = DispatchTime.now().uptimeNanoseconds
                let worker = Task.detached { try await drain(session.transfer) }
                var history = CaptureResourceHistory(startNS: startNS)
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(seconds))
                do {
                    repeat {
                        history.observe(session.transfer)
                        try await clock.sleep(
                            until: min(deadline, clock.now.advanced(by: .seconds(1))))
                    } while clock.now < deadline && !session.transfer.snapshot().isClosed
                    capture.stop()
                    var terminalError: (any Error)?
                    do { try await capture.finish() } catch { terminalError = error }
                    let counts = try await worker.value
                    history.observe(session.transfer, finishing: true)
                    let samples = try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(history.readings))
                    let final = session.transfer.snapshot()
                    let config = session.transfer.configuration
                    let format = config.format
                    let run: [String: Any] = [
                        "epoch": config.epoch.streamID.uuidString,
                        "sequence": config.epoch.sequence,
                        "durationNS": DispatchTime.now().uptimeNanoseconds - start,
                        "sampleRate": format.sampleRate, "channels": format.channelCount,
                        "encoding": format.encoding.rawValue, "layout": format.layout.rawValue,
                        "queueSlots": config.slotCount,
                        "maximumFramesPerChunk": config.maximumFramesPerChunk,
                        "queueHighWater": final.highWaterSlots,
                        "acceptedChunks": final.acceptedChunks,
                        "drainedChunks": counts.blocks, "consumedFrames": counts.frames,
                        "droppedFrames": final.droppedFrames,
                        "knownGapFrames": counts.knownGapFrames,
                        "unknownGaps": counts.unknownGaps, "invalidChunks": final.invalidChunks,
                        "producerContractViolated": final.producerContractViolated,
                        "inputChanged": inputChanged, "resourceSamples": samples,
                    ]
                    runs.append(run)
                    if let terminalError { throw terminalError }
                    if inputChanged { throw Failure.inputChanged }
                    guard final.isClosed, counts.frames > 0,
                        final.acceptedChunks == counts.blocks, !final.producerContractViolated,
                        final.invalidChunks == 0, final.droppedFrames == 0,
                        counts.knownGapFrames == 0, counts.unknownGaps == 0
                    else { throw Failure.captureFailed }
                    try save("running")
                } catch {
                    capture.stop()
                    try? await capture.finish()
                    worker.cancel()
                    _ = await worker.result
                    throw error
                }
            }
            try save("completed")
        } catch {
            let reason =
                (error as? Failure) == .inputChanged
                ? "input configuration changed" : HostErrorReport.message(for: error)
            try save("failed", error: reason)
            throw error
        }
    }
}
