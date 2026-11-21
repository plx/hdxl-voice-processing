import Foundation
import WorkloadReplay

guard CommandLine.arguments.count == 3, let chunk = Int(CommandLine.arguments[2]), chunk > 0 else {
    FileHandle.standardError.write(
        Data("usage: ReplayWorkloads BUNDLE MAXIMUM_CHUNK_SAMPLES\n".utf8))
    exit(2)
}
let result = try replayWorkloads(
    at: URL(fileURLWithPath: CommandLine.arguments[1]), maximumChunkSamples: chunk)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(result))
FileHandle.standardOutput.write(Data([10]))
