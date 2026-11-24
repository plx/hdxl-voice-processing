import Foundation
import VoiceSuiteWorkload

struct Evidence: Encodable {
    let fixture: SuiteFixture
    let recipe: SuiteRecipe
    let name: String
    let results: [SuiteResult]
    let phase: CPPSPhaseEvidence?

    init(_ trial: SuiteTrial, _ results: [SuiteResult]) {
        fixture = trial.item
        recipe = trial.input.recipe
        name = trial.name
        self.results = results
        phase = nil
    }
    init(_ trial: CPPSPhaseTrial, _ evidence: CPPSPhaseEvidence) {
        fixture = trial.item
        recipe = trial.recipe
        name = "phase." + trial.phase.rawValue + "." + trial.item.name
        results = []
        phase = evidence
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VOICE_SUITE_INPUTS"], let name = env["VOICE_SUITE_FIXTURE"] else {
            throw SuiteError.invalidInput("Set VOICE_SUITE_INPUTS and VOICE_SUITE_FIXTURE")
        }
        let directory = URL(filePath: path, directoryHint: .isDirectory)
        guard let item = try SuiteFixture.load(in: directory).first(where: { $0.name == name })
        else {
            throw SuiteError.invalidInput(name)
        }
        var rows: [Evidence] = []
        for composition in SuiteComposition.allCases {
            for pair in [false, true] where !pair || composition == .full {
                let trial = try SuiteTrial(
                    item: item, composition: composition, directory: directory, simultaneous: pair)
                rows.append(try Evidence(trial, trial.verify()))
            }
        }
        if name == CPPSPhaseTrial.fixtureName {
            for phase in CPPSPhase.allCases {
                let trial = try CPPSPhaseTrial(item: item, directory: directory, phase: phase)
                try trial.prepareIteration()
                _ = try trial.measure()
                rows.append(try Evidence(trial, trial.check()))
            }
        }
        try printJSON(rows)
        return
    }
    guard args.count == 4, let composition = SuiteComposition(rawValue: args[2]),
        ["verify", "run", "pair", "verify-pair", "trace"].contains(args[0])
    else {
        throw SuiteError.invalidInput(
            "use (verify|run|pair|verify-pair|trace) INPUTS COMPOSITION FIXTURE")
    }
    let directory = URL(filePath: args[1], directoryHint: .isDirectory)
    guard let item = try SuiteFixture.load(in: directory).first(where: { $0.name == args[3] })
    else { throw SuiteError.invalidInput(args[3]) }
    let trial = try SuiteTrial(
        item: item, composition: composition, directory: directory,
        simultaneous: args[0].hasSuffix("pair"))
    let results =
        try args[0].hasPrefix("verify")
        ? trial.verify() : trial.run(diagnostics: args[0] == "trace" ? .detailed : .disabled)
    try printJSON(Evidence(trial, results))
}

do { try main() } catch {
    FileHandle.standardError.write(
        Data(("Voice suite check failed: " + String(describing: error) + "\n").utf8))
    exit(EXIT_FAILURE)
}
