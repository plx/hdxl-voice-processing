import Foundation
import LargeFourierWorkload

let matrix = try LargeFourierCase.matrix()
precondition(matrix.count == 12 && Set(matrix.map(\.name)).count == 12)
for item in matrix {
    for operation in LargeFourierOperation.allCases {
        try item.makeWorkload(operation).verify()
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(matrix))
FileHandle.standardOutput.write(Data([0x0A]))
