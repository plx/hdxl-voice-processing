import Foundation
import SWIPEPrimeWorkload

let matrix = try SWIPEPrimeCase.matrix()
precondition(matrix.count == 44 && Set(matrix.map(\.name)).count == 44)
let args = Array(CommandLine.arguments.dropFirst())
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
if args == ["--list"] {
    FileHandle.standardOutput.write(try encoder.encode(matrix))
} else {
    let selected: [SWIPEPrimeCase]
    if args.count == 2 && args[0] == "--shard" {
        selected = matrix.filter { $0.shard == args[1] }
    } else if args.count == 2 && args[0] == "--case" {
        selected = matrix.filter { $0.name == args[1] }
    } else {
        precondition(args.isEmpty)
        selected = matrix
    }
    precondition(!selected.isEmpty)
    var records: [SWIPEPrimeWorkloadEvidence] = []
    for item in selected {
        for algorithm in SWIPEPrimeBenchmarkAlgorithm.allCases {
            records.append(try item.makeWorkload(algorithm: algorithm).verify())
            FileHandle.standardError.write(
                Data("Verified \(algorithm.rawValue).\(item.name)\n".utf8))
        }
    }
    FileHandle.standardOutput.write(try encoder.encode(records))
}
FileHandle.standardOutput.write(Data([0x0A]))
