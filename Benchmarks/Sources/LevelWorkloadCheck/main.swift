import Foundation
import LevelWorkload

let matrix = try LevelCase.matrix()
precondition(matrix.count == 100 && Set(matrix.map(\.name)).count == 100)
let records = try matrix.map { try $0.makeWorkload().verify() }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(records))
FileHandle.standardOutput.write(Data([0x0A]))
