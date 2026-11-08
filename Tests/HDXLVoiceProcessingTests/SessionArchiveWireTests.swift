import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func sessionWireReader(
    _ data: Data, limits: SessionArchiveLimits, chunk: Int = .max
) throws -> SessionArchiveWireReader {
    var offset = 0
    return try SessionArchiveWireReader(limits: limits) { requested in
        let count = min(requested, chunk, data.count - offset)
        defer { offset += count }
        return Data(data.dropFirst(offset).prefix(count))
    }
}

@Test func sessionWireCanonicalFrameAndArbitraryReadPartitions() throws {
    let limits = try SessionArchiveLimits(ioChunkCapacity: 256)
    var bytes = Data()
    let writer = try SessionArchiveWireWriter(limits: limits) { bytes.append($0) }
    try writer.append(.header, payload: Data("{}".utf8))
    // Independently computed little-endian framing and SHA256(prefix || payload).
    let expected =
        "4844584c564f4943450001000000000001000000020000000000000000000000"
        + "5a6f8a7566484e311752dac29e76b5386fd0a9111122251fa43f49ee54824f247b7d"
    #expect(bytes.map { String(format: "%02x", $0) }.joined() == expected)
    let firstPrefix = writer.prefixSHA256
    let payload = Data((0..<70_000).map { UInt8($0 % 251) })
    try writer.append(.measurement, payload: payload)
    let reader = try sessionWireReader(bytes, limits: limits, chunk: 17)
    let first = try #require(try reader.next())
    let second = try #require(try reader.next())
    #expect(first.kind == .header && first.ordinal == 0 && first.payload == Data("{}".utf8))
    #expect(second.kind == .measurement && second.ordinal == 1 && second.payload == payload)
    #expect(second.precedingSHA256 == firstPrefix)
    #expect(try reader.next() == nil)
    #expect(try reader.next() == nil)
    #expect(reader.prefixSHA256 == writer.prefixSHA256)
    #expect(reader.byteCount == writer.byteCount && reader.recordCount == 2)
    #expect(reader.maximumReadChunkBytes <= 17)
    #expect(reader.maximumBufferedRecordBytes == payload.count)
    #expect(writer.maximumWriteChunkBytes <= limits.ioChunkCapacity)
}

@Test func sessionWireRejectsCorruptionTruncationAndReordering() throws {
    let limits = try SessionArchiveLimits()
    var bytes = Data()
    let writer = try SessionArchiveWireWriter(limits: limits) { bytes.append($0) }
    try writer.append(.header, payload: Data("{}".utf8))
    var corrupt = bytes
    corrupt[corrupt.count - 1] ^= 1
    let damaged = try sessionWireReader(corrupt, limits: limits)
    #expect(throws: SessionArchiveError.integrityMismatch) { _ = try damaged.next() }
    #expect(throws: SessionArchiveError.invalidState) { _ = try damaged.next() }
    let truncated = try sessionWireReader(Data(bytes.dropLast()), limits: limits)
    #expect(throws: SessionArchiveError.truncated) { _ = try truncated.next() }
    var reordered = bytes
    reordered[16 + 8] = 1
    let wrongOrder = try sessionWireReader(reordered, limits: limits)
    #expect(throws: SessionArchiveError.outOfOrder) { _ = try wrongOrder.next() }
    var future = bytes
    future[10] = 2
    #expect(throws: SessionArchiveError.unsupportedVersion) {
        _ = try sessionWireReader(future, limits: limits)
    }
    var unknown = bytes
    unknown[16] = 254
    let unknownRecord = try sessionWireReader(unknown, limits: limits)
    #expect(throws: SessionArchiveError.unsupportedRecord) { _ = try unknownRecord.next() }
}

@Test func sessionWireChecksAdvertisedSizeBeforeReadingPayload() throws {
    let limits = try SessionArchiveLimits(maximumRecordBytes: 128)
    var bytes = Data()
    let writer = try SessionArchiveWireWriter(limits: limits) { bytes.append($0) }
    #expect(throws: SessionArchiveError.sizeLimitExceeded) {
        try writer.append(.measurement, payload: Data(repeating: 0, count: 129))
    }
    #expect(bytes == SessionArchiveWire.magic && writer.recordCount == 0)
    try writer.append(.header, payload: Data("{}".utf8))
    for index in 20..<24 { bytes[index] = 255 }
    var readBytes = 0
    let reader = try SessionArchiveWireReader(limits: limits) { requested in
        let output = Data(bytes.dropFirst(readBytes).prefix(requested))
        readBytes += output.count
        return output
    }
    #expect(throws: SessionArchiveError.sizeLimitExceeded) { _ = try reader.next() }
    #expect(readBytes == 16 + 48)
    #expect(reader.maximumBufferedRecordBytes == 0)
}

@Test func sessionWireAcceptsExactByteCeilingAndRejectsOneMoreByte() throws {
    let limits = try SessionArchiveLimits(
        maximumArchiveBytes: 256, maximumRecordBytes: 192, maximumCatalogBytes: 128,
        maximumEmbeddedMediaBytes: 0, ioChunkCapacity: 256)
    var bytes = Data()
    let writer = try SessionArchiveWireWriter(limits: limits) { bytes.append($0) }
    try writer.append(.measurement, payload: Data(repeating: 7, count: 192))
    #expect(bytes.count == 256)
    let exact = try sessionWireReader(bytes, limits: limits)
    _ = try #require(try exact.next())
    #expect(try exact.next() == nil)
    bytes.append(1)
    let excessive = try sessionWireReader(bytes, limits: limits)
    _ = try #require(try excessive.next())
    #expect(throws: SessionArchiveError.sizeLimitExceeded) { _ = try excessive.next() }
}

@Test func sessionWireIOFailuresAreSafeAndTerminal() throws {
    var writes = 0
    let writer = try SessionArchiveWireWriter(limits: SessionArchiveLimits()) { _ in
        writes += 1
        if writes > 1 { throw NSError(domain: "/private/user/media.wav", code: 1) }
    }
    #expect(throws: SessionArchiveError.outputFailure) {
        try writer.append(.header, payload: Data("{}".utf8))
    }
    #expect(throws: SessionArchiveError.invalidState) {
        try writer.append(.header, payload: Data("{}".utf8))
    }
    #expect(throws: SessionArchiveError.inputFailure) {
        _ = try SessionArchiveWireReader(limits: SessionArchiveLimits()) { _ in
            throw NSError(domain: "/private/user/media.wav", code: 2)
        }
    }
    let once = try SessionArchiveLimits(maximumRecords: 1)
    var bytes = Data()
    let limited = try SessionArchiveWireWriter(limits: once) { bytes.append($0) }
    try limited.append(.header, payload: Data("{}".utf8))
    let before = bytes
    #expect(throws: SessionArchiveError.recordLimitExceeded) {
        try limited.append(.footer, payload: Data())
    }
    #expect(bytes == before)
}

@Test func sessionHeaderPreservesOptInAndRefusesUnknownSchema() throws {
    let header = try SessionArchiveHeader(
        id: calibrationTestID(7001),
        producer: VersionedIdentifier(name: "session-test", version: 1),
        createdAtUnixSeconds: -0.0, notes: "Cafe\u{301}")
    let encoded = try header.canonicalJSON()
    let decoded = try JSONDecoder().decode(SessionArchiveHeader.self, from: encoded)
    #expect(decoded == header && decoded.audioPolicy == .omit && decoded.notes == "Café")
    #expect(try decoded.canonicalJSON() == encoded)
    let future = Data(
        String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
    #expect(throws: SessionArchiveError.unsupportedVersion) {
        _ = try JSONDecoder().decode(SessionArchiveHeader.self, from: future)
    }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveHeader(
            id: header.id, producer: header.producer, createdAtUnixSeconds: .infinity)
    }
}
