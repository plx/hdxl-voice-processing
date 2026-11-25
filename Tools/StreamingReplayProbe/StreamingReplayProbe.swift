import Foundation

@main
enum StreamingReplayProbe {
    static func main() async {
        do {
            #if os(macOS)
                let options = try ReplayOptions(arguments: Array(CommandLine.arguments.dropFirst()))
                if options.operation == .trace,
                    let marker = ProcessInfo.processInfo.environment["HDXL_REPLAY_RECORDING_START"]
                {
                    let deadline = ContinuousClock.now + .seconds(60)
                    while !FileManager.default.fileExists(atPath: marker) {
                        guard ContinuousClock.now < deadline else {
                            throw ReplayFailure("Instruments did not announce recording startup")
                        }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    // Allow the target's logging provider to attach before creating the lifecycle.
                    try await Task.sleep(for: .seconds(1))
                    try await runReplay(options)
                    if ProcessInfo.processInfo.environment["HDXL_REPLAY_HOLD_FOR_RECORDER"] == "1" {
                        // The controller stops Instruments after the atomic trial report appears.
                        // Hold only after measurement. A controller crash cannot leave us running indefinitely.
                        let releaseDeadline = ContinuousClock.now + .seconds(150)
                        while FileManager.default.fileExists(atPath: marker) {
                            guard ContinuousClock.now < releaseDeadline else {
                                throw ReplayFailure(
                                    "Instruments controller did not release the finished replay")
                            }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                    } else {
                        try await Task.sleep(for: .seconds(1))
                    }
                } else {
                    try await runReplay(options)
                }
            #else
                throw ReplayFailure("run StreamingReplayProbe on a macOS host")
            #endif
        } catch {
            FileHandle.standardError.write(Data("StreamingReplayProbe: \(error)\n".utf8))
            exit(1)
        }
    }
}
