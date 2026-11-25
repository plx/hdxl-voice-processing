import Foundation
import VoiceSuiteWorkload

struct Evidence: Encodable {
    let fixture: SuiteFixture
    let recipe: SuiteRecipe
    let name: String
    let results: [SuiteResult]
    let phase: CPPSPhaseEvidence?
    let measurementBoundary: String?

    init(_ trial: SuiteTrial, _ results: [SuiteResult]) {
        fixture = trial.item
        recipe = trial.input.recipe
        name = trial.name
        self.results = results
        phase = nil
        measurementBoundary = nil
    }
    init(_ trial: CPPSPhaseTrial, _ evidence: CPPSPhaseEvidence) {
        fixture = trial.item
        recipe = trial.recipe
        name = "phase." + trial.phase.rawValue + "." + trial.item.name
        results = []
        phase = evidence
        measurementBoundary = trial.phase.measurementBoundary
    }
}

struct TracedRun: Encodable {
    let processID: Int32
    let evidence: Evidence
}

func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

func printJSON<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try encodeJSON(value))
    FileHandle.standardOutput.write(Data([10]))
}

// Both waits are outside the measured work and apply only to controller-driven traces.
func waitForRecorder(_ marker: String, present: Bool, timeout: Duration) throws {
    let deadline = ContinuousClock.now + timeout
    while FileManager.default.fileExists(atPath: marker) != present {
        guard ContinuousClock.now < deadline else {
            throw SuiteError.invalidInput("Instruments controller handshake timed out")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
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
    let controlledTrace = args.count == 5 && args.first == "trace"
    guard args.count == 4 || controlledTrace, let composition = SuiteComposition(rawValue: args[2]),
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
    let marker: String?
    if controlledTrace {
        guard let path = ProcessInfo.processInfo.environment["HDXL_REPLAY_RECORDING_START"] else {
            throw SuiteError.invalidInput("Controlled trace requires a recorder startup marker")
        }
        try waitForRecorder(path, present: true, timeout: .seconds(90))
        // Give the target's logging provider time to attach before the short native trial.
        Thread.sleep(forTimeInterval: 1)
        marker = path
    } else {
        marker = nil
    }
    let results =
        try args[0].hasPrefix("verify")
        ? trial.verify() : trial.run(diagnostics: args[0] == "trace" ? .detailed : .disabled)
    let evidence = Evidence(trial, results)
    if args[0] == "trace" {
        let traced = TracedRun(
            processID: ProcessInfo.processInfo.processIdentifier, evidence: evidence)
        if let marker {
            try encodeJSON(traced).write(to: URL(filePath: args[4]), options: .atomic)
            try waitForRecorder(marker, present: false, timeout: .seconds(150))
        } else {
            try printJSON(traced)
        }
    } else {
        try printJSON(evidence)
    }
}

do { try main() } catch {
    FileHandle.standardError.write(
        Data(("Voice suite check failed: " + String(describing: error) + "\n").utf8))
    exit(EXIT_FAILURE)
}
