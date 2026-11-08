import Foundation

/// Stable codes only. Paths, decoder messages, personal values and media are
/// deliberately absent; hosts decide how to present failures to their users.
public enum SessionArchiveError: String, Error, Sendable, Hashable {
    case invalidConfiguration, invalidMetadata, unsupportedVersion, unsupportedRecord
    case malformedRecord, sizeLimitExceeded, recordLimitExceeded, catalogLimitExceeded
    case duplicateIdentity, duplicateTimestamp, outOfOrder, incompatibleProfile, incompatibleUnit
    case integrityMismatch, truncated, missingMedia, audioNotOptedIn, invalidState
    case activationRefused, inputFailure, outputFailure, incompatibleMedia, analysisFailure,
        cancelled
}

/// Reader/writer ceilings are supplied by the host, never by an imported file.
/// Timeline length does not increase the per-record or catalog bounds. Foundation,
/// decoder and allocator overhead is additional to the owned byte-buffer limits.
public struct SessionArchiveLimits: Sendable, Hashable {
    public let maximumArchiveBytes: UInt64
    public let maximumRecordBytes: Int
    public let maximumCatalogBytes: Int
    public let maximumCatalogEntries: Int
    public let maximumRecords: UInt64
    public let maximumEmbeddedMediaBytes: UInt64
    public let maximumIntermediateScalars: Int
    public let ioChunkCapacity: Int

    public init(
        maximumArchiveBytes: UInt64 = 4 * 1024 * 1024 * 1024,
        maximumRecordBytes: Int = 16 * 1024 * 1024,
        maximumCatalogBytes: Int = 16 * 1024 * 1024,
        maximumCatalogEntries: Int = 4096,
        maximumRecords: UInt64 = 10_000_000,
        maximumEmbeddedMediaBytes: UInt64 = 256 * 1024 * 1024,
        maximumIntermediateScalars: Int = 65_536,
        ioChunkCapacity: Int = 65_536
    ) throws {
        guard (256...16 * 1024 * 1024 * 1024).contains(maximumArchiveBytes),
            (128...16 * 1024 * 1024).contains(maximumRecordBytes),
            (128...16 * 1024 * 1024).contains(maximumCatalogBytes),
            UInt64(maximumRecordBytes) <= maximumArchiveBytes,
            UInt64(maximumCatalogBytes) <= maximumArchiveBytes,
            (1...4096).contains(maximumCatalogEntries),
            (1...100_000_000).contains(maximumRecords),
            maximumEmbeddedMediaBytes <= 4 * 1024 * 1024 * 1024,
            maximumEmbeddedMediaBytes <= maximumArchiveBytes,
            (0...1_048_576).contains(maximumIntermediateScalars),
            (256...65_536).contains(ioChunkCapacity)
        else { throw SessionArchiveError.invalidConfiguration }
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumRecordBytes = maximumRecordBytes
        self.maximumCatalogBytes = maximumCatalogBytes
        self.maximumCatalogEntries = maximumCatalogEntries
        self.maximumRecords = maximumRecords
        self.maximumEmbeddedMediaBytes = maximumEmbeddedMediaBytes
        self.maximumIntermediateScalars = maximumIntermediateScalars
        self.ioChunkCapacity = ioChunkCapacity
    }
}

/// Permission to embed original media, not a claim that referenced media exists.
/// Actual embedded references and byte counts remain explicit archive records.
public enum SessionArchiveAudioPolicy: String, Sendable, Hashable, Codable {
    case omit, explicitlyInclude
}

/// A sealed partial session is distinct from an interrupted, unsealed file.
public enum SessionArchiveCompletion: String, Sendable, Hashable, Codable {
    case completed, cancelled, partial
}

/// Strict import is the default. Prefix inspection does not produce a complete
/// archive or authorize target activation, even when every recovered record passes.
public enum SessionArchiveRecovery: Sendable, Hashable {
    case requireComplete, inspectCompletePrefix
}

/// Versioned JSON metadata. All personal text is supplied explicitly by the host;
/// construction does not inspect a device, collect audio or emit diagnostic logs.
public struct SessionArchiveHeader: Sendable, Hashable, Codable {
    public let format = "hdxl-voice-session"
    public let schemaVersion = 1
    public let id: UUID
    public let producer: VersionedIdentifier
    public let createdAtUnixSeconds: Double?
    public let audioPolicy: SessionArchiveAudioPolicy
    public let notes: String

    public init(
        id: UUID, producer: VersionedIdentifier, createdAtUnixSeconds: Double? = nil,
        audioPolicy: SessionArchiveAudioPolicy = .omit, notes: String = ""
    ) throws {
        guard createdAtUnixSeconds?.isFinite != false else {
            throw SessionArchiveError.invalidMetadata
        }
        let normalized = notes.precomposedStringWithCanonicalMapping
        guard normalized.utf8.count <= 4096 else { throw SessionArchiveError.sizeLimitExceeded }
        self.id = id
        self.producer = producer
        self.createdAtUnixSeconds = createdAtUnixSeconds.map { $0 == 0 ? 0 : $0 }
        self.audioPolicy = audioPolicy
        self.notes = normalized
    }

    public func canonicalJSON() throws -> Data { try canonicalContractJSON(self) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, schemaVersion, id, producer, createdAtUnixSeconds, audioPolicy, notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .format) == "hdxl-voice-session" else {
            throw SessionArchiveError.invalidMetadata
        }
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw SessionArchiveError.unsupportedVersion
        }
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            producer: c.decode(VersionedIdentifier.self, forKey: .producer),
            createdAtUnixSeconds: c.decodeIfPresent(Double.self, forKey: .createdAtUnixSeconds),
            audioPolicy: c.decode(SessionArchiveAudioPolicy.self, forKey: .audioPolicy),
            notes: c.decode(String.self, forKey: .notes))
    }
}

/// Immutable host-reported acquisition metadata. Unknown remains nil; these
/// descriptions cannot prove that two recordings used equivalent conditions.
public struct SessionAcquisitionMetadata: Sendable, Hashable, Codable {
    public let conditions: CalibrationRecordingConditions
    public let deviceIdentifier: String?
    public let platformDescription: String?

    public init(
        conditions: CalibrationRecordingConditions, deviceIdentifier: String? = nil,
        platformDescription: String? = nil
    ) throws {
        self.conditions = conditions
        self.deviceIdentifier = try Self.text(deviceIdentifier)
        self.platformDescription = try Self.text(platformDescription)
    }

    private static func text(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping
        guard normalized.utf8.count <= 128,
            !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw SessionArchiveError.invalidMetadata }
        return normalized
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case conditions, deviceIdentifier, platformDescription
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            conditions: c.decode(CalibrationRecordingConditions.self, forKey: .conditions),
            deviceIdentifier: c.decodeIfPresent(String.self, forKey: .deviceIdentifier),
            platformDescription: c.decodeIfPresent(String.self, forKey: .platformDescription))
    }
}
