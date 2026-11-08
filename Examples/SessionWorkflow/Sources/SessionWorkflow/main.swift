import Darwin
import Foundation
import SessionWorkflowSupport

@main struct SessionWorkflow {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if try SerializationBenchmark.command(args) { return }
            if try storageCommand(args) { return }
            if args.count == 5, args[0] == "--generate-calibration-fixture",
                args[1] == "--reference",
                args[3] == "--output"
            {
                try SyntheticCalibrationFixture.generate(
                    referenceURL: URL(fileURLWithPath: args[2]),
                    outputDirectory: URL(fileURLWithPath: args[4]))
                print("Synthetic calibration fixture generated; not DSP or listening evidence.")
                return
            }
            guard args.count == 7, args[0] == "--fixture-probe", args[1] == "--fixtures",
                args[3] == "--scratch", args[5] == "--output"
            else {
                print(
                    """
                    Commands (existing parent/scratch directories required):
                      create-synthetic ARCHIVE --scratch DIRECTORY [--include-audio] [--replace]
                      inspect ARCHIVE
                      replay ARCHIVE --scratch DIRECTORY
                      share-copy ARCHIVE DESTINATION [--include-audio]
                      delete ARCHIVE
                      --fixture-probe --fixtures DIRECTORY --scratch DIRECTORY --output REPORT
                      --generate-calibration-fixture --reference JSON --output NEW_DIRECTORY
                      --serialization-write|--serialization-read --frames COUNT --archive FILE --output REPORT
                    """
                )
                exit(EXIT_FAILURE)
            }
            let report = try SessionFixtureProbe.run(
                fixtures: URL(fileURLWithPath: args[2]), scratch: URL(fileURLWithPath: args[4]))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: URL(fileURLWithPath: args[6]), options: .atomic)
            print("Synthetic session interchange probe passed.")
        } catch {
            FileHandle.standardError.write(
                Data("Session workflow failed: \(StoredSessionWorkflow.failureCode(error)).\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func storageCommand(_ args: [String]) throws -> Bool {
        guard let command = args.first else { return false }
        func url(_ index: Int) -> URL { URL(fileURLWithPath: args[index]) }
        switch command {
        case "create-synthetic" where args.count >= 4 && args[2] == "--scratch":
            let flags = Array(args.dropFirst(4))
            guard Set(flags).count == flags.count,
                Set(flags).isSubset(of: ["--include-audio", "--replace"])
            else { return false }
            try printInspection(
                StoredSessionWorkflow.createSynthetic(
                    at: url(1), scratch: url(3), includeAudio: flags.contains("--include-audio"),
                    publication: flags.contains("--replace") ? .replace : .create))
        case "inspect" where args.count == 2:
            try printInspection(StoredSessionWorkflow.inspect(at: url(1)))
        case "replay" where args.count == 4 && args[2] == "--scratch":
            let count = try StoredSessionWorkflow.replay(at: url(1), scratch: url(3))
            print("Reanalysis completed: \(count) measurements. No values logged.")
        case "share-copy"
        where args.count == 3 || (args.count == 4 && args[3] == "--include-audio"):
            try StoredSessionWorkflow.shareCopy(
                from: url(1), to: url(2), includeAudio: args.count == 4)
            print("Verified sharing copy created. No upload performed.")
        case "delete" where args.count == 2:
            try StoredSessionWorkflow.delete(at: url(1))
            print("Selected archive deleted. Previously shared copies are independent.")
        default: return false
        }
        return true
    }

    private static func printInspection(_ inspection: StoredSessionWorkflow.Inspection) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(inspection))
        print()
    }
}
