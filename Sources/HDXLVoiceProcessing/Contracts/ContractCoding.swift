import Foundation

/// Invalid persisted or constructed contract data never becomes a valid measurement.
public enum ContractError: Error, Sendable, Equatable {
    case invalidIdentifier
    case invalidVersion
    case invalidUnit
    case invalidValue
    case invalidConfidence
    case invalidInterval
    case arithmeticOverflow
    case invalidTiming
    case invalidCoverage
    case invalidConfiguration
    case invalidFingerprint
    case intermediateBudgetExceeded
    case unsupportedSchemaVersion(Int)
}

private struct AnyContractKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension Decoder {
    /// Version 1 fails closed on unknown fields, including nested configuration fields.
    func contractContainer<Key: CodingKey & CaseIterable>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> {
        let all = try container(keyedBy: AnyContractKey.self)
        let known = Set(Key.allCases.map(\.stringValue))
        guard all.allKeys.allSatisfy({ known.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: codingPath, debugDescription: "Unknown contract field"))
        }
        return try container(keyedBy: type)
    }
}

func validContractIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
        && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
}

func canonicalContractJSON<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
