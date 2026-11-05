import CryptoKit
import Foundation
import HDXLVoiceProcessing

/// Test-only corpus access. Production products do not bundle or decode these assets.
struct VoiceCorpus: Decodable {
    struct InputOutcome: Decodable {
        let status: String
        let reason: UnavailabilityReason?
    }

    struct Decoded: Decodable {
        let sampleRate: Int
        let sampleCount: Int
        let channelCount: Int
        let encoding: String
        let durationSeconds: Double
        let normalizedFloat64LESHA256: String
        let peak: Double
        let meanSquare: Double
        let zeroSampleCount: Int
        let railSampleCount: Int
    }

    struct Support: Decodable {
        let startSample: Int
        let sampleCount: Int
        let sampleRate: Int
    }

    struct Fixture: Decodable {
        let id: String
        let sourceID: String
        let path: String
        let sha256: String
        let byteCount: Int
        let task: String
        let condition: String
        let sourceSupport: Support
        let expectedInput: InputOutcome
        let decoded: Decoded?
    }

    struct Source: Decodable {
        let id: String
        let path: String
        let sha256: String
        let byteCount: Int
        let sampleRate: Int
        let sampleCount: Int
        let normalizedFloat64LESHA256: String
    }

    struct Coverage: Decodable {
        let total: Int
        let available: [String]
        let unavailable: [String: [String]]
    }

    let schemaVersion: Int
    let corpusVersion: String
    let sources: [Source]
    let fixtures: [Fixture]
    let subsets: [String: [String]]
    let coverage: Coverage

    static func url(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
            let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil)
        else { throw CorpusInputError(.invalidInput) }
        return root.appending(path: "Corpus/" + path)
    }

    static func bytes(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: bytes("manifest.json"))
    }

    func fixture(_ id: String) throws -> Fixture {
        guard let result = fixtures.first(where: { $0.id == id }) else {
            throw CorpusInputError(.invalidInput)
        }
        return result
    }

    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func pcmHash(_ samples: [Double]) -> String {
        var hash = SHA256()
        for value in samples {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { hash.update(bufferPointer: $0) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct CorpusInputError: Error, Equatable {
    let reason: UnavailabilityReason
    init(_ reason: UnavailabilityReason) { self.reason = reason }
}

/// Independent native decoder for the declared fixture formats. Bounded file data,
/// unaligned little-endian reads, and owned samples; no audio-framework conversion.
struct CorpusPCM {
    let samples: [Double]
    let sampleRate: Int

    init(data: Data) throws {
        guard data.startIndex == 0 else { throw CorpusInputError(.invalidInput) }
        guard data.count <= 64 * 1024 * 1024 else {
            throw CorpusInputError(.unsupportedRange)
        }
        func u16(_ offset: Int) -> UInt16 {
            data.withUnsafeBytes {
                UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            }
        }
        func u32(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        func tag(_ offset: Int) -> String {
            String(decoding: data[offset..<offset + 4], as: UTF8.self)
        }
        guard data.count >= 44, tag(0) == "RIFF", tag(8) == "WAVE",
            Int(u32(4)) + 8 == data.count
        else { throw CorpusInputError(.invalidInput) }
        var offset = 12
        var chunks: [String: Range<Int>] = [:]
        while offset < data.count {
            guard offset + 8 <= data.count else { throw CorpusInputError(.invalidInput) }
            let name = tag(offset)
            let size = Int(u32(offset + 4))
            offset += 8
            guard chunks[name] == nil, size <= data.count - offset,
                offset + size + size % 2 <= data.count
            else { throw CorpusInputError(.invalidInput) }
            chunks[name] = offset..<offset + size
            offset += size + size % 2
        }
        guard let format = chunks["fmt "], format.count == 16, let payload = chunks["data"]
        else { throw CorpusInputError(.invalidInput) }
        let encoding = u16(format.lowerBound)
        let channels = u16(format.lowerBound + 2)
        let rate = Int(u32(format.lowerBound + 4))
        let byteRate = Int(u32(format.lowerBound + 8))
        let alignment = Int(u16(format.lowerBound + 12))
        let bits = Int(u16(format.lowerBound + 14))
        guard channels == 1,
            encoding == 1 && bits == 16 || encoding == 3 && (bits == 32 || bits == 64),
            (4000...192000).contains(rate)
        else { throw CorpusInputError(.unsupportedRange) }
        guard alignment == bits / 8, byteRate == rate * alignment, payload.count % alignment == 0
        else { throw CorpusInputError(.invalidInput) }
        let count = payload.count / alignment
        guard count > 0 else { throw CorpusInputError(.insufficientData) }
        guard count <= 44100 * 60 else { throw CorpusInputError(.unsupportedRange) }
        var samples = [Double]()
        samples.reserveCapacity(count)
        for position in stride(from: payload.lowerBound, to: payload.upperBound, by: alignment) {
            let value: Double
            if encoding == 1 {
                value = Double(Int16(bitPattern: u16(position))) / 32768
            } else if bits == 32 {
                value = Double(Float(bitPattern: u32(position)))
            } else {
                value = data.withUnsafeBytes {
                    Double(
                        bitPattern: UInt64(
                            littleEndian:
                                $0.loadUnaligned(fromByteOffset: position, as: UInt64.self)))
                }
            }
            guard value.isFinite, abs(value) <= 1 else { throw CorpusInputError(.invalidInput) }
            samples.append(value)
        }
        self.samples = samples
        sampleRate = rate
    }
}
