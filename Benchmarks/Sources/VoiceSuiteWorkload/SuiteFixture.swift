import CryptoKit
import Foundation
import HDXLVoiceProcessing

public enum SuiteError: Error {
    case invalidInput(String)
    case mismatch(String)
}

public enum SuiteComposition: String, Codable, CaseIterable, Sendable {
    case cpps, core, full
    /// Same results as full, with independent spectral transforms for shape and LTAS.
    case separateSpectra
    var includesExtensions: Bool { self == .full || self == .separateSpectra }
}

public struct SuiteFixture: Codable, Sendable {
    public struct Region: Codable, Sendable {
        public let start, count: Int
    }
    public let name, condition, source, sourceSHA256, transform, pcmSHA256: String
    public let precision: AnalysisPrecision
    public let sampleRate, sampleCount, repeats: Int
    public let regions: [Region]

    public static func load(in directory: URL) throws -> [Self] {
        struct Manifest: Decodable {
            let schemaVersion: Int
            let cases: [SuiteFixture]
        }
        let file = try Data(contentsOf: directory.appending(path: "manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: file)
        guard manifest.schemaVersion == 1, !manifest.cases.isEmpty,
            Set(manifest.cases.map(\.name)).count == manifest.cases.count
        else { throw SuiteError.invalidInput("manifest") }
        for item in manifest.cases {
            guard [16000, 44100, 48000].contains(item.sampleRate),
                (1...30 * item.sampleRate).contains(item.sampleCount),
                (1...30).contains(item.repeats),
                !item.regions.isEmpty, item.pcmSHA256.count == 64,
                item.pcmSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }
                )
            else { throw SuiteError.invalidInput(item.name) }
            var end = 0
            for region in item.regions {
                guard region.start >= end, region.start < item.sampleCount, region.count > 0,
                    region.count <= item.sampleCount - region.start
                else { throw SuiteError.invalidInput(item.name) }
                end = region.start + region.count
            }
        }
        return manifest.cases
    }

    public func loadInput(in directory: URL, composition: SuiteComposition) throws -> any SuiteInput
    {
        let data = try Data(contentsOf: directory.appending(path: pcmSHA256 + ".pcm"))
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == pcmSHA256
        else { throw SuiteError.invalidInput(name + " PCM hash") }
        if precision == .float32 {
            guard data.count == sampleCount * 4 else { throw SuiteError.invalidInput(name) }
            let pcm = data.withUnsafeBytes { raw in
                (0..<sampleCount).map {
                    Float(
                        bitPattern: UInt32(
                            littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self)
                        ))
                }
            }
            return try TypedSuiteInput(self, composition, pcm)
        }
        guard data.count == sampleCount * 8 else { throw SuiteError.invalidInput(name) }
        let pcm = data.withUnsafeBytes { raw in
            (0..<sampleCount).map {
                Double(
                    bitPattern: UInt64(
                        littleEndian: raw.loadUnaligned(fromByteOffset: 8 * $0, as: UInt64.self)))
            }
        }
        return try TypedSuiteInput(self, composition, pcm)
    }
}

/// Public result fingerprints update in emission order, independently per lane so different
/// callback interleavings can be compared without sorting or retaining every frame.
public struct SuiteLane: Codable, Equatable, Sendable {
    public private(set) var available = 0
    public private(set) var unavailable = 0
    public private(set) var fingerprint: UInt64 = 14_695_981_039_346_656_037
    public private(set) var sum = 0.0
    mutating func record(_ value: Double?, at sample: Int64) {
        fingerprint = (fingerprint ^ UInt64(bitPattern: sample)) &* 1_099_511_628_211
        if let value {
            precondition(value.isFinite)
            available += 1
            sum += value
            fingerprint = (fingerprint ^ value.bitPattern) &* 1_099_511_628_211
        } else {
            unavailable += 1
            fingerprint = (fingerprint ^ UInt64.max) &* 1_099_511_628_211
        }
    }
}

public struct SuiteResult: Codable, Equatable, Sendable {
    public internal(set) var lanes: [String: SuiteLane] = [:]
    public internal(set) var epochs = 0
    public internal(set) var analyzedSamples = 0
    public internal(set) var spectralRows = 0
    public internal(set) var robustFitSlopesPerFit = 0
    public internal(set) var maximumRootSweeps = 0
    public internal(set) var secondRootStarts = 0
    public internal(set) var completePitchWindows = 0
    public internal(set) var omittedPulseRegions = 0
    public internal(set) var pulseTrackingAttempts = 0

    mutating func record(_ lane: String, _ value: Double?, at sample: Int64) {
        lanes[lane, default: SuiteLane()].record(value, at: sample)
    }
}

public protocol SuiteInput: Sendable {
    var recipe: SuiteRecipe { get }
    func run(chunk: Int, diagnostics: RuntimeDiagnosticMode) throws -> SuiteResult
}
