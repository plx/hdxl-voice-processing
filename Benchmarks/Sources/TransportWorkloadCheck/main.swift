import Foundation
import TransportWorkload

struct Receipt: Encodable {
    let name: String
    let configuration: TransportCase
    let operation: TransportOperation
    let verified: [String: UInt64]
}

var receipts: [Receipt] = []
for item in TransportCase.matrix {
    for operation in TransportOperation.allCases {
        let batch = try TransportBatch(item: item, operation: operation)
        batch.prepareIteration()
        let checksum = batch.run()
        receipts.append(
            Receipt(
                name: "Transport.\(operation.rawValue).\(item.name)", configuration: item,
                operation: operation, verified: batch.verify(checksum: checksum)))
    }
}
print(String(decoding: try JSONEncoder().encode(receipts), as: UTF8.self))
