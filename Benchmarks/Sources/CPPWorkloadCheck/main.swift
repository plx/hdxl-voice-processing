import CPPWorkload
import Foundation

let matrix = try CPPCase.matrix()
precondition(matrix.count == 77 && Set(matrix.map(\.name)).count == 77)
// Optional substring is for development probes; the evidence wrapper always
// requests the complete matrix and independently checks its exact membership.
let selected: [CPPCase]
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--shard" {
    selected = matrix.filter { $0.shard == CommandLine.arguments[2] }
} else if CommandLine.arguments.count == 2 {
    selected = matrix.filter { $0.name.contains(CommandLine.arguments[1]) }
} else {
    precondition(CommandLine.arguments.count == 1)
    selected = matrix
}
precondition(!selected.isEmpty)
let records = try selected.map { try $0.makeWorkload().verify() }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(records))
FileHandle.standardOutput.write(Data([0x0A]))
