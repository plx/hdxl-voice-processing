import Foundation
import FourierWorkload

let matrix = try FourierCase.matrix()
precondition(matrix.count == 22 && Set(matrix.map(\.name)).count == 22)
for item in matrix { try item.makeWorkload().verify() }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(matrix))
FileHandle.standardOutput.write(Data([0x0A]))
