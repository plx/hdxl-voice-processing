import CepstrumWorkload
import Foundation

let matrix = try CepstralCase.matrix()
precondition(matrix.count == 38 && Set(matrix.map(\.name)).count == 38)
let records = try matrix.map { try $0.makeWorkload().verify() }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(records))
FileHandle.standardOutput.write(Data([0x0A]))
