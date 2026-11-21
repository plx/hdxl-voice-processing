import Foundation
import SpectralProductWorkload

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if CommandLine.arguments.dropFirst().elementsEqual(["--stream-memory"]) {
    FileHandle.standardOutput.write(try encoder.encode(spectralMemoryProbe()))
    exit(0)
}
precondition(CommandLine.arguments.count == 1)
let matrix = try ProductCase.matrix()
precondition(matrix.count == 18 && Set(matrix.map(\.name)).count == 18)
for item in matrix {
    let cepstral = try CepstralProductTrial(item)
    for operation in CepstralProductOperation.allCases {
        try cepstral.prepare(operation)
        try cepstral.run(operation)
        cepstral.verify(operation)
    }
    let trial = try ProductTrial(item)
    for operation in ProductOperation.allCases {
        try trial.prepare(operation)
        try trial.run(operation)
        try trial.verify(operation)
    }
}
FileHandle.standardOutput.write(try encoder.encode(matrix))
