import Foundation
import ScheduleWorkload

let matrix = try ScheduleCase.matrix()
precondition(matrix.count == 20 && Set(matrix.map(\.name)).count == 20)
let records = try matrix.map { try $0.makeWorkload().verify() }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(records))
FileHandle.standardOutput.write(Data([0x0A]))
