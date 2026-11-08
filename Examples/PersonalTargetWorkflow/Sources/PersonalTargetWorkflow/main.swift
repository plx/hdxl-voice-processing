import Darwin
import Foundation
import HDXLVoiceProcessing

struct Timing: Encodable {
    let fittingSeconds, evaluationSeconds: Double
    let modelBytes: Int
    let modelIdentity: CalibrationDigest
    let peakResidentBytes: Int64
}

struct ScenarioReport: Encodable {
    let name: String
    let datasetIdentity, splitIdentity, fitIdentity, evaluationIdentity: CalibrationDigest
    let activated: Bool
    let datasetFile, splitFile, fitFile, evaluationFile: String
    let feedbackFile: String?
}

struct Report: Encodable {
    let schemaVersion = 1
    let status = "passed"
    let syntheticOnly = true
    let humanListeningPerformed = false
    let physicalDeviceEvidence = false
    let numericalPCMValidationIsSeparate = true
    let validationIdentity, fittingReferenceIdentity: CalibrationDigest
    let scenarios: [ScenarioReport]
    let maximumDatasetSessions, maximumDatasetTakes, maximumDatasetBytes: Int
    let maximumDatasetIdentity: CalibrationDigest
    let repetitions: Int
    let capacityTrials: [Timing]
}

func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
}

func seconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

func peakResidentBytes() throws -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
        throw ExampleError.verificationFailed
    }
    return Int64(usage.ru_maxrss)  // Darwin reports bytes; this example is macOS-only.
}

func perform() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 5, let repetitions = Int(arguments[4]), (1...16).contains(repetitions)
    else {
        throw ExampleError.invalidInput
    }
    let repository = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let evidenceURL = URL(fileURLWithPath: arguments[2])
    let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw ExampleError.invalidInput
    }
    let evidenceBytes = try Data(contentsOf: evidenceURL)
    try require(evidenceBytes.count <= 256 * 1024)
    let evidence = try JSONDecoder().decode(CheckedEvidence.self, from: evidenceBytes)
    let validation = try evidence.validation()
    let fixtureURL = repository.appending(
        path: "Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets/fitting-reference.json")
    let fixtureBytes = try Data(contentsOf: fixtureURL)
    try require(fixtureBytes.count <= 2 * 1024 * 1024)
    let fixtures = try JSONDecoder().decode(ReferenceInputs.self, from: fixtureBytes)
    try require(fixtures.schemaVersion == 1 && fixtures.syntheticOnly && fixtures.cases.count == 9)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var scenarios: [ScenarioReport] = []
    for scenario in fixtures.cases {
        let report = try autoreleasepool {
            let inputs = try PreparedInputs(rows: scenario.rows, evidence: evidence)
            let fit = try inputs.fit()
            let evaluation = try inputs.evaluate(fit)
            try require((evaluation.activated != nil) == scenario.activated)
            let fitFile = scenario.name + "-fit.json"
            let evaluationFile = scenario.name + "-evaluation.json"
            let datasetFile = scenario.name + "-dataset.json"
            let splitFile = scenario.name + "-split.json"
            try inputs.dataset.canonicalJSON().write(
                to: output.appending(path: datasetFile), options: .atomic)
            try inputs.split.canonicalJSON().write(
                to: output.appending(path: splitFile), options: .atomic)
            try write(fit, to: output.appending(path: fitFile))
            try write(evaluation, to: output.appending(path: evaluationFile))
            let feedbackFile = evaluation.activated == nil ? nil : scenario.name + "-feedback.json"
            if let target = evaluation.activated, let feedbackFile {
                try write(
                    feedbackSnapshots(target: target, profile: evidence.profile),
                    to: output.appending(path: feedbackFile))
            }
            return try ScenarioReport(
                name: scenario.name, datasetIdentity: inputs.dataset.identity(),
                splitIdentity: CalibrationDigest(bytes: inputs.split.canonicalJSON()),
                fitIdentity: fit.identity(), evaluationIdentity: evaluation.evaluationIdentity,
                activated: evaluation.activated != nil, datasetFile: datasetFile,
                splitFile: splitFile,
                fitFile: fitFile, evaluationFile: evaluationFile, feedbackFile: feedbackFile)
        }
        scenarios.append(report)
    }
    let capacityRows = (1...512).map { id in
        ReferenceInputs.Row(
            id: id, session: 800 + (id - 1) / 16, role: .fitting, groupSHA256: "",
            label: id.isMultiple(of: 2) ? .usual : .preferred,
            cpps: id.isMultiple(of: 2) ? 4 : 10, pitch: 200, level: -20)
    }
    let maximum = try PreparedInputs(rows: capacityRows, evidence: evidence)
    let maximumBytes = try maximum.dataset.canonicalJSON()
    try require(maximum.dataset.takeCount == 512 && maximum.dataset.sessions.count == 32)
    try require(try CalibrationDataset.decode(maximumBytes) == maximum.dataset)
    try maximumBytes.write(to: output.appending(path: "capacity-dataset.json"), options: .atomic)
    try maximum.split.canonicalJSON().write(
        to: output.appending(path: "capacity-split.json"), options: .atomic)
    var timings: [Timing] = []
    for index in 0..<repetitions {
        let timing = try autoreleasepool {
            let fitStart = DispatchTime.now().uptimeNanoseconds
            let fit = try maximum.fit()
            let fittingSeconds = seconds(since: fitStart)
            let evaluationStart = DispatchTime.now().uptimeNanoseconds
            let evaluation = try maximum.evaluate(fit)
            let evaluationSeconds = seconds(since: evaluationStart)
            guard let model = evaluation.activated else { throw ExampleError.verificationFailed }
            let encoder = JSONEncoder()
            let modelBytes = try encoder.encode(model).count
            try require(modelBytes <= ActivatedPersonalTarget.maximumEncodedBytes)
            if index == 0 {
                try write(fit, to: output.appending(path: "capacity-fit.json"))
                try write(evaluation, to: output.appending(path: "capacity-evaluation.json"))
                try write(model, to: output.appending(path: "capacity-model.json"))
            }
            return try Timing(
                fittingSeconds: fittingSeconds, evaluationSeconds: evaluationSeconds,
                modelBytes: modelBytes, modelIdentity: model.identity(),
                peakResidentBytes: peakResidentBytes())
        }
        timings.append(timing)
    }
    try require(Set(timings.map(\.modelIdentity)).count == 1)
    try write(
        Report(
            validationIdentity: validation.identity(),
            fittingReferenceIdentity: CalibrationDigest(bytes: fixtureBytes),
            scenarios: scenarios, maximumDatasetSessions: 32, maximumDatasetTakes: 512,
            maximumDatasetBytes: maximumBytes.count,
            maximumDatasetIdentity: maximum.dataset.identity(),
            repetitions: repetitions, capacityTrials: timings),
        to: output.appending(path: "report.json"))
    print(
        "Validated nine synthetic fitting scenarios and \(repetitions) maximum-capacity fitting/evaluation passes."
    )
}

do {
    try perform()
} catch {
    // Do not print caller paths or contents. The runner retains structured receipts.
    FileHandle.standardError.write(Data("Personal target example failed.\n".utf8))
    exit(1)
}
