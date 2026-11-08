import CryptoKit
import Foundation

enum SessionArchiveRecordKind: UInt8 {
    case header = 1
    case profile, source, series, measurement, gap
    case calibrationDataset, calibrationSplit, calibrationAnalysis, target
    case mediaReference, mediaChunk
    case replayPlan
    case footer = 255
}

enum SessionArchiveWire {
    // "HDXLVOICE\0", little-endian major=1, minor=0, reserved=0.
    static let magic = Data([72, 68, 88, 76, 86, 79, 73, 67, 69, 0, 1, 0, 0, 0, 0, 0])
    static let headerBytes = 48

    static func append<Integer: FixedWidthInteger>(_ value: Integer, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    static func unsigned(_ data: Data, offset: Int, bytes: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<bytes {
            value |= UInt64(data[data.startIndex + offset + index]) << (index * 8)
        }
        return value
    }

    static func digest(_ hash: SHA256) -> String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct SessionArchiveWireRecord {
    let kind: SessionArchiveRecordKind
    let ordinal: UInt64
    let payload: Data
    /// Prefix identity before this record, used to verify the final seal.
    let precedingSHA256: String
}

/// Single-owner framing. Semantic records and the final seal are validated by
/// the session layer. A failed sink makes this instance permanently unusable.
final class SessionArchiveWireWriter {
    let limits: SessionArchiveLimits
    private let sink: (Data) throws -> Void
    private var hash = SHA256()
    private var failed = false
    private(set) var byteCount: UInt64 = 0
    private(set) var recordCount: UInt64 = 0
    private(set) var maximumWriteChunkBytes = 0
    private(set) var maximumBufferedRecordBytes = 0
    var prefixSHA256: String { SessionArchiveWire.digest(hash) }

    init(limits: SessionArchiveLimits, sink: @escaping (Data) throws -> Void) throws {
        self.limits = limits
        self.sink = sink
        try write(SessionArchiveWire.magic)
        hash.update(data: SessionArchiveWire.magic)
    }

    func append(_ kind: SessionArchiveRecordKind, payload: Data) throws {
        guard !failed else { throw SessionArchiveError.invalidState }
        guard payload.count <= limits.maximumRecordBytes else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        guard recordCount < limits.maximumRecords else {
            throw SessionArchiveError.recordLimitExceeded
        }
        let extent = UInt64(SessionArchiveWire.headerBytes) + UInt64(payload.count)
        guard extent <= limits.maximumArchiveBytes - byteCount else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        var prefix = Data([kind.rawValue, 0, 0, 0])
        SessionArchiveWire.append(UInt32(payload.count), to: &prefix)
        SessionArchiveWire.append(recordCount, to: &prefix)
        var checksum = SHA256()
        checksum.update(data: prefix)
        checksum.update(data: payload)
        var header = prefix
        header.append(contentsOf: checksum.finalize())
        try write(header)
        try write(payload)
        hash.update(data: header)
        hash.update(data: payload)
        recordCount += 1
        maximumBufferedRecordBytes = max(maximumBufferedRecordBytes, payload.count)
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = min(limits.ioChunkCapacity, data.count - offset)
            let chunk = Data(data.dropFirst(offset).prefix(count))
            do { try sink(chunk) } catch {
                failed = true
                throw SessionArchiveError.outputFailure
            }
            byteCount += UInt64(count)
            maximumWriteChunkBytes = max(maximumWriteChunkBytes, count)
            offset += count
        }
    }
}

/// Each requested read is capped independently from the record limit. A record's
/// length is checked before its buffer is allocated; only complete checksum- and
/// sequence-validated records leave this layer. No history is retained.
final class SessionArchiveWireReader {
    let limits: SessionArchiveLimits
    private let input: (Int) throws -> Data
    private var hash = SHA256()
    private var failed = false
    private var ended = false
    private(set) var byteCount: UInt64 = 0
    private(set) var recordCount: UInt64 = 0
    private(set) var maximumReadChunkBytes = 0
    private(set) var maximumBufferedRecordBytes = 0
    var prefixSHA256: String { SessionArchiveWire.digest(hash) }

    init(limits: SessionArchiveLimits, input: @escaping (Int) throws -> Data) throws {
        self.limits = limits
        self.input = input
        let magic = try readExactly(SessionArchiveWire.magic.count)!
        guard magic.prefix(10) == SessionArchiveWire.magic.prefix(10) else {
            throw SessionArchiveError.invalidMetadata
        }
        guard magic == SessionArchiveWire.magic else {
            throw SessionArchiveError.unsupportedVersion
        }
        hash.update(data: magic)
    }

    func next() throws -> SessionArchiveWireRecord? {
        guard !failed else { throw SessionArchiveError.invalidState }
        if ended { return nil }
        do {
            guard let header = try readExactly(SessionArchiveWire.headerBytes, allowEOF: true)
            else {
                ended = true
                return nil
            }
            guard header[1...3].allSatisfy({ $0 == 0 }) else {
                throw SessionArchiveError.malformedRecord
            }
            guard let kind = SessionArchiveRecordKind(rawValue: header[0]) else {
                throw SessionArchiveError.unsupportedRecord
            }
            let length = SessionArchiveWire.unsigned(header, offset: 4, bytes: 4)
            let ordinal = SessionArchiveWire.unsigned(header, offset: 8, bytes: 8)
            guard length <= UInt64(limits.maximumRecordBytes),
                length <= limits.maximumArchiveBytes - byteCount
            else { throw SessionArchiveError.sizeLimitExceeded }
            guard recordCount < limits.maximumRecords else {
                throw SessionArchiveError.recordLimitExceeded
            }
            guard ordinal == recordCount else { throw SessionArchiveError.outOfOrder }
            let payload = try readExactly(Int(length))!
            var checksum = SHA256()
            checksum.update(data: header.prefix(16))
            checksum.update(data: payload)
            guard Data(checksum.finalize()) == header.suffix(32) else {
                throw SessionArchiveError.integrityMismatch
            }
            let preceding = prefixSHA256
            hash.update(data: header)
            hash.update(data: payload)
            recordCount += 1
            maximumBufferedRecordBytes = max(maximumBufferedRecordBytes, payload.count)
            return SessionArchiveWireRecord(
                kind: kind, ordinal: ordinal, payload: payload, precedingSHA256: preceding)
        } catch {
            failed = true
            throw (error as? SessionArchiveError) ?? .inputFailure
        }
    }

    private func readExactly(_ count: Int, allowEOF: Bool = false) throws -> Data? {
        guard allowEOF || UInt64(count) <= limits.maximumArchiveBytes - byteCount else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        var bytes = Data()
        // Reserve only a bounded read chunk; an advertised record length must not
        // allocate its entire budget when the input is immediately truncated.
        bytes.reserveCapacity(min(count, limits.ioChunkCapacity))
        while bytes.count < count {
            let remaining = limits.maximumArchiveBytes - byteCount
            // A one-byte EOF probe is necessary at the exact archive ceiling.
            // It is never retained or accepted beyond that ceiling.
            let requested = min(
                limits.ioChunkCapacity, count - bytes.count, Int(max(1, remaining)))
            let chunk: Data
            do { chunk = try input(requested) } catch { throw SessionArchiveError.inputFailure }
            guard chunk.count <= requested else { throw SessionArchiveError.malformedRecord }
            if chunk.isEmpty {
                if allowEOF && bytes.isEmpty { return nil }
                throw SessionArchiveError.truncated
            }
            guard UInt64(chunk.count) <= remaining else {
                throw SessionArchiveError.sizeLimitExceeded
            }
            bytes.append(chunk)
            byteCount += UInt64(chunk.count)
            maximumReadChunkBytes = max(maximumReadChunkBytes, chunk.count)
        }
        return bytes
    }
}
