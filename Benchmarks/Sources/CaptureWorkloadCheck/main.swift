import CaptureWorkload
import Foundation

struct Row: Encodable {
    let name: String
    let configuration: CaptureCase
    let operationsPerIteration: Int
    let verified: Bool
}
var rows: [Row] = []
for item in CaptureCase.matrix {
    let batch = try CaptureBatch(item: item)
    try batch.prepareIteration()
    batch.run()
    guard batch.verify() else { fatalError("Capture workload verification failed: \(item.name)") }
    rows.append(
        Row(name: item.name, configuration: item, operationsPerIteration: 1, verified: true))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(rows), as: UTF8.self))
