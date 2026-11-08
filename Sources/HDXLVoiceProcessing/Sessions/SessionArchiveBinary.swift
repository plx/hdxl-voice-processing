import Foundation

/// Explicit little-endian encoding; no native struct layout, alignment, or
/// pointer reinterpretation enters the file format. Every append checks its
/// ceiling, including intermediate metadata preceding large scalar arrays.
struct SessionArchiveBinaryEncoder {
    let limit: Int
    private(set) var data = Data()

    mutating func bytes(_ value: Data) throws {
        guard value.count <= limit - data.count else { throw SessionArchiveError.sizeLimitExceeded }
        data.append(value)
    }
    mutating func integer<Value: FixedWidthInteger>(_ value: Value) throws {
        guard MemoryLayout<Value>.size <= limit - data.count else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        SessionArchiveWire.append(value, to: &data)
    }
    mutating func real(_ value: Double) throws {
        guard value.isFinite else { throw SessionArchiveError.invalidMetadata }
        try integer((value == 0 ? 0.0 : value).bitPattern)
    }
    mutating func text(_ value: String) throws {
        guard let count = UInt16(exactly: value.utf8.count) else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        try integer(count)
        try bytes(Data(value.utf8))
    }
}

struct SessionArchiveBinaryDecoder {
    let data: Data
    private(set) var offset = 0
    var remaining: Int { data.count - offset }

    mutating func unsigned<Value: FixedWidthInteger & UnsignedInteger>(_ type: Value.Type) throws
        -> Value
    {
        let count = MemoryLayout<Value>.size
        guard count <= remaining else { throw SessionArchiveError.malformedRecord }
        let value = SessionArchiveWire.unsigned(data, offset: offset, bytes: count)
        offset += count
        return Value(value)
    }
    mutating func nonnegativeInteger() throws -> Int64 {
        let value = try unsigned(UInt64.self)
        guard let signed = Int64(exactly: value) else { throw SessionArchiveError.malformedRecord }
        return signed
    }
    mutating func real() throws -> Double {
        let bits = try unsigned(UInt64.self)
        let value = Double(bitPattern: bits)
        guard value.isFinite, value != 0 || bits == 0 else {
            throw SessionArchiveError.malformedRecord
        }
        return value
    }
    mutating func text() throws -> String {
        let count = Int(try unsigned(UInt16.self))
        guard count <= remaining else { throw SessionArchiveError.malformedRecord }
        let bytes = data.dropFirst(offset).prefix(count)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw SessionArchiveError.malformedRecord
        }
        offset += count
        return value
    }
    func finish() throws {
        guard remaining == 0 else { throw SessionArchiveError.malformedRecord }
    }
}
