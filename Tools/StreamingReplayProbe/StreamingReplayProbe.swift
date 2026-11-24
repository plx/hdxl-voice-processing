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
                    // Keep the target available while the collector drains its final signposts.
                    try await Task.sleep(for: .seconds(1))
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
