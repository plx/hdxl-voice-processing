import Foundation
import VoiceSuiteWorkload

/// Verify partitions within one target and precision before comparing different
/// precisions or platforms. Per-metric emission order is part of this contract.
struct PartitionReceipt: Encodable {
    let name: String
    let sizes: [Int]
}

struct Execution: Encodable {
    #if os(iOS) && targetEnvironment(simulator)
        let platform = "iOS Simulator"
    #elseif os(macOS)
        let platform = "macOS"
    #else
        let platform = "unqualified"
    #endif
    #if arch(arm64)
        let architecture = "arm64"
    #elseif arch(x86_64)
        let architecture = "x86_64"
    #else
        let architecture = "unknown"
    #endif
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
}

func write<T: Encodable>(_ value: T, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: URL(filePath: path), options: .atomic)
}

struct Report: Encodable {
    let execution = Execution()
    let fixture: SuiteFixture
    let recipe: SuiteRecipe
    let partitions: [PartitionReceipt]
    let reference: SuiteResult
}

func conformance() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.first == "continuity", args.count == 5 {
        let directory = URL(filePath: args[1], directoryHint: .isDirectory)
        let fixtures = try SuiteFixture.load(in: directory)
        guard let input = fixtures.first(where: { $0.name == args[2] }),
            let route = fixtures.first(where: { $0.name == args[3] })
        else { throw SuiteError.invalidInput("unknown continuity fixture") }
        struct ContinuityReport: Encodable {
            let execution = Execution()
            let result: ContinuityReceipt
        }
        try write(
            ContinuityReport(
                result: verifySuiteContinuity(
                    fixture: input, routeFixture: route,
                    directory: directory)), to: args[4])
        return
    }
    guard args.count == 4, let composition = SuiteComposition(rawValue: args[2]) else {
        throw SuiteError.invalidInput("INPUT_DIRECTORY FIXTURE COMPOSITION OUTPUT_JSON")
    }
    let directory = URL(filePath: args[0], directoryHint: .isDirectory)
    guard let item = try SuiteFixture.load(in: directory).first(where: { $0.name == args[1] })
    else { throw SuiteError.invalidInput("unknown fixture " + args[1]) }
    let input = try item.loadInput(in: directory, composition: composition)
    var seed: UInt64 = 61
    let randomSizes = (0..<97).map { _ in
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return 1 + Int((seed >> 32) % 509)
    }
    let plans = [
        PartitionReceipt(name: "whole-region", sizes: [item.sampleCount]),
        PartitionReceipt(name: "small", sizes: [7]),
        PartitionReceipt(name: "prime", sizes: [173]),
        PartitionReceipt(name: "deterministic-random", sizes: randomSizes),
    ]
    let reference = try input.run(
        partition: SuitePartition(plans[0].sizes), diagnostics: .disabled,
        verifySpectra: true, collectObservations: true)
    for plan in plans.dropFirst() {
        let result = try input.run(
            partition: SuitePartition(plan.sizes), diagnostics: .disabled,
            verifySpectra: true, collectObservations: true)
        guard result == reference else {
            throw SuiteError.mismatch("\(item.name) \(composition.rawValue) \(plan.name)")
        }
    }
    let report = Report(
        fixture: item, recipe: input.recipe, partitions: plans, reference: reference)
    try write(report, to: args[3])
}

do {
    try conformance()
} catch {
    FileHandle.standardError.write(
        Data(("Conformance failed: " + String(describing: error) + "\n").utf8))
    exit(EXIT_FAILURE)
}
