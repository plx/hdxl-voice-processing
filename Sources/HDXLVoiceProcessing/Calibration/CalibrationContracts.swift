import CryptoKit
import Foundation

public enum CalibrationError: Error, Sendable, Equatable {
    case invalidRecord, invalidRange, duplicateIdentity, capacityExceeded
    case incompatibleDataset, invalidSplit, recordingLeakage
    case missingLabels, unknownReplay, invalidState, arithmeticOverflow
}

/// Control-plane bounds for version-1 calibration records. These do not describe
/// capture callback capacity or a statistical minimum for fitting a target.
public enum CalibrationRecordLimits {
    public static let maximumDatasetBytes = 16 * 1024 * 1024
    public static let maximumSessions = 32
    public static let maximumTakes = 512
    public static let maximumExclusionsPerTake = 64
    public static let maximumMaskObservationsPerTake = 256
    public static let maximumMaskBytesPerTake = 64 * 1024
    public static let maximumTextBytes = 4096
}

/// Exact content identity. A media reference's digest identifies file bytes,
/// including its container, rather than an assumed amplitude-normalized signal.
public struct CalibrationDigest: Sendable, Hashable, Codable {
    public let sha256: String

    public init(sha256: String) throws {
        guard sha256.utf8.count == 64,
            sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ContractError.invalidFingerprint }
        self.sha256 = sha256
    }

    public init(bytes: Data) {
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case sha256 }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(sha256: c.decode(String.self, forKey: .sha256))
    }
}

func calibrationText(_ value: String, maximum: Int = 4096, allowEmpty: Bool = true) throws
    -> String
{
    let normalized = value.precomposedStringWithCanonicalMapping
    guard normalized.utf8.count <= maximum,
        allowEmpty || !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw CalibrationError.invalidRecord }
    return normalized
}

func calibrationOptionalText(_ value: String?, maximum: Int = 128) throws -> String? {
    try value.map { try calibrationText($0, maximum: maximum, allowEmpty: false) }
}

func calibrationTimestamp(_ value: Double?) throws -> Double? {
    guard value?.isFinite != false else { throw CalibrationError.invalidRecord }
    return value.map { $0 == 0 ? 0 : $0 }
}

func calibrationDigest<Value: Encodable>(_ value: Value) throws -> CalibrationDigest {
    CalibrationDigest(bytes: try canonicalContractJSON(value))
}

public enum CalibrationTaskCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case sustainedVowel, mostlyVoicedSentence, repeatedOrdinaryPassage, novelPassage
}

/// Prompt identity is independent of language and of the requested production.
/// A "mostly voiced" task does not assert a measured voiced fraction.
public struct CalibrationTask: Sendable, Hashable, Codable {
    public let category: CalibrationTaskCategory
    public let promptIdentifier: String
    public let prompt: String?
    public let languageTag: String?

    public init(
        category: CalibrationTaskCategory, promptIdentifier: String,
        prompt: String? = nil, languageTag: String? = nil
    ) throws {
        self.category = category
        self.promptIdentifier = try calibrationText(
            promptIdentifier, maximum: 128, allowEmpty: false)
        self.prompt = try calibrationOptionalText(prompt, maximum: 4096)
        self.languageTag = try calibrationOptionalText(languageTag)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case category, promptIdentifier, prompt, languageTag
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            category: c.decode(CalibrationTaskCategory.self, forKey: .category),
            promptIdentifier: c.decode(String.self, forKey: .promptIdentifier),
            prompt: c.decodeIfPresent(String.self, forKey: .prompt),
            languageTag: c.decodeIfPresent(String.self, forKey: .languageTag))
    }
}

public enum CalibrationProductionInstruction: String, Sendable, Hashable, Codable {
    case usual, preferred, other
}

public enum CalibrationListeningPreference: String, Sendable, Hashable, Codable {
    case usual, preferred, other, uncertain
}

/// Declared collection protocol, not cryptographic proof of a listener's history.
public enum CalibrationLabelExposure: String, Sendable, Hashable, Codable {
    case blindedBeforeFeatures, unblindedBeforeFeatures, afterFeatures, unknown
}

public struct CalibrationListeningLabel: Sendable, Hashable, Codable {
    public let preference: CalibrationListeningPreference
    public let confidence: Double?
    public let notes: String
    public let recordedAtUnixSeconds: Double?
    public let exposure: CalibrationLabelExposure

    public init(
        preference: CalibrationListeningPreference, confidence: Double? = nil,
        notes: String = "", recordedAtUnixSeconds: Double? = nil,
        exposure: CalibrationLabelExposure
    ) throws {
        if let confidence {
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw ContractError.invalidConfidence
            }
        }
        self.preference = preference
        self.confidence = confidence.map { $0 == 0 ? 0 : $0 }
        self.notes = try calibrationText(notes)
        self.recordedAtUnixSeconds = try calibrationTimestamp(recordedAtUnixSeconds)
        self.exposure = exposure
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case preference, confidence, notes, recordedAtUnixSeconds, exposure
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            preference: c.decode(CalibrationListeningPreference.self, forKey: .preference),
            confidence: c.decodeIfPresent(Double.self, forKey: .confidence),
            notes: c.decode(String.self, forKey: .notes),
            recordedAtUnixSeconds: c.decodeIfPresent(Double.self, forKey: .recordedAtUnixSeconds),
            exposure: c.decode(CalibrationLabelExposure.self, forKey: .exposure))
    }
}

/// The host resolves referenceIdentifier to media. No URL, audio bytes, or private
/// filename is implicitly exported. Hash and length are verified again at analysis.
/// Excerpts/transforms of one acquisition must retain its originalRecordingID.
public struct CalibrationMediaReference: Sendable, Hashable, Codable {
    public let referenceIdentifier: String
    public let originalRecordingID: UUID
    public let content: CalibrationDigest
    public let byteCount: Int64

    public init(
        referenceIdentifier: String, originalRecordingID: UUID,
        content: CalibrationDigest, byteCount: Int64
    ) throws {
        guard validContractIdentifier(referenceIdentifier), byteCount >= 0 else {
            throw CalibrationError.invalidRecord
        }
        self.referenceIdentifier = referenceIdentifier
        self.originalRecordingID = originalRecordingID
        self.content = content
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case referenceIdentifier, originalRecordingID, content, byteCount
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            referenceIdentifier: c.decode(String.self, forKey: .referenceIdentifier),
            originalRecordingID: c.decode(UUID.self, forKey: .originalRecordingID),
            content: c.decode(CalibrationDigest.self, forKey: .content),
            byteCount: c.decode(Int64.self, forKey: .byteCount))
    }
}

/// Host-reported acquisition conditions. Nil is unknown, not evidence that two
/// recordings used the same room, distance, gain, route or processing settings.
public struct CalibrationRecordingConditions: Sendable, Hashable, Codable {
    public let routeIdentifier: String?
    public let roomIdentifier: String?
    public let microphoneDistanceMeters: Double?
    public let inputGainDB: Double?
    /// Materialized host settings (for example AGC, voice processing and codec).
    /// Nil means unreported; an empty dictionary explicitly reports no extras.
    public let recordingSettings: [String: ProfileSetting]?
    public let notes: String

    public init(
        routeIdentifier: String? = nil, roomIdentifier: String? = nil,
        microphoneDistanceMeters: Double? = nil, inputGainDB: Double? = nil,
        recordingSettings: [String: ProfileSetting]? = nil, notes: String = ""
    ) throws {
        if let distance = microphoneDistanceMeters {
            guard distance.isFinite, distance > 0 else { throw CalibrationError.invalidRecord }
        }
        guard inputGainDB?.isFinite != false else { throw CalibrationError.invalidRecord }
        if let settings = recordingSettings {
            guard settings.count <= 32, settings.keys.allSatisfy(validContractIdentifier) else {
                throw CalibrationError.capacityExceeded
            }
        }
        self.routeIdentifier = try calibrationOptionalText(routeIdentifier)
        self.roomIdentifier = try calibrationOptionalText(roomIdentifier)
        self.microphoneDistanceMeters = microphoneDistanceMeters
        self.inputGainDB = inputGainDB.map { $0 == 0 ? 0 : $0 }
        self.recordingSettings = try recordingSettings?.mapValues { try $0.validated() }
        self.notes = try calibrationText(notes)
        if let settings = self.recordingSettings {
            guard try canonicalContractJSON(settings).count <= 16 * 1024 else {
                throw CalibrationError.capacityExceeded
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case routeIdentifier, roomIdentifier, microphoneDistanceMeters, inputGainDB
        case recordingSettings, notes
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            routeIdentifier: c.decodeIfPresent(String.self, forKey: .routeIdentifier),
            roomIdentifier: c.decodeIfPresent(String.self, forKey: .roomIdentifier),
            microphoneDistanceMeters: c.decodeIfPresent(
                Double.self, forKey: .microphoneDistanceMeters),
            inputGainDB: c.decodeIfPresent(Double.self, forKey: .inputGainDB),
            recordingSettings: c.decodeIfPresent(
                [String: ProfileSetting].self, forKey: .recordingSettings),
            notes: c.decode(String.self, forKey: .notes))
    }
}

public enum CalibrationExclusionKind: String, Sendable, Hashable, Codable {
    case userSelection, invalidRecording, missingAcquisition
}

/// A source interval excluded from numerical analysis, with an inspectable reason.
/// A missing-acquisition interval must never be interpreted as recorded silence.
public struct CalibrationExclusion: Sendable, Hashable, Codable {
    public let source: SourceInterval
    public let kind: CalibrationExclusionKind
    public let reason: String

    public init(source: SourceInterval, kind: CalibrationExclusionKind, reason: String) throws {
        guard source.sampleCount > 0 else { throw CalibrationError.invalidRange }
        self.source = source
        self.kind = kind
        self.reason = try calibrationText(reason, allowEmpty: false)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case source, kind, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            source: c.decode(SourceInterval.self, forKey: .source),
            kind: c.decode(CalibrationExclusionKind.self, forKey: .kind),
            reason: c.decode(String.self, forKey: .reason))
    }
}
