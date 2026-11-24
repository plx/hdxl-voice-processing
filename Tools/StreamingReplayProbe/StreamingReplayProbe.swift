import Foundation

@main
enum StreamingReplayProbe {
    static func main() async {
        do {
            #if os(macOS)
                let options = try ReplayOptions(arguments: Array(CommandLine.arguments.dropFirst()))
                try await runReplay(options)
            #else
                throw ReplayFailure("run StreamingReplayProbe on a macOS host")
            #endif
        } catch {
            FileHandle.standardError.write(Data("StreamingReplayProbe: \(error)\n".utf8))
            exit(1)
        }
    }
}
