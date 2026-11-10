import Foundation
import FramingWorkload

let matrix = try FramingCase.matrix()
precondition(matrix.count == 88)
precondition(Set(matrix.map(\.name)).count == matrix.count)
for item in matrix {
    let workload = try item.makeWorkload()
    precondition(workload.preparedBufferBytes == item.preparedBufferBytes)
    for chunk in [item.inputSampleCount, item.smallChunkSamples] {
        try workload.restart()
        try workload.run(chunkSize: chunk)
        precondition(workload.checksum == workload.expectedChecksum)
        precondition(workload.frameCount == item.expectedFrameCount)
        precondition(workload.preparedBufferBytes == item.preparedBufferBytes)
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
FileHandle.standardOutput.write(try encoder.encode(matrix))
FileHandle.standardOutput.write(Data([0x0A]))
