import Foundation

/// An independently labeled take. `source` uses sample positions in the referenced
/// media, while originalRecordingID groups excerpts/transforms for leakage checks.
public struct CalibrationTake: Sendable, Hashable, Codable {
    public let id: UUID
    public let media: CalibrationMediaReference
    public let task: CalibrationTask
    public let repetition: Int
    public let instruction: CalibrationProductionInstruction
    public let instructionNotes: String
    public let label: CalibrationListeningLabel?
    public let exclusionReason: String?
    public let source: SourceInterval
    public let exclusions: [CalibrationExclusion]
    public let conditions: CalibrationRecordingConditions
    public let profile: AnalysisScheduleProfile
    public let profileIdentity: ProfileIdentity
    /// Optional resolved-input recipe from the existing segmentation API. Its
    /// selected regions are intersected with explicit calibration exclusions.
    public let mask: MaskPlan?

    public init(
        id: UUID, media: CalibrationMediaReference, task: CalibrationTask, repetition: Int,
        instruction: CalibrationProductionInstruction, instructionNotes: String = "",
        label: CalibrationListeningLabel? = nil, exclusionReason: String? = nil,
        source: SourceInterval, exclusions: [CalibrationExclusion] = [],
        conditions: CalibrationRecordingConditions, profile: AnalysisScheduleProfile,
        mask: MaskPlan? = nil
    ) throws {
        guard (1...10_000).contains(repetition), source.sampleRate == profile.inputFormat.sampleRate
        else { throw CalibrationError.invalidRecord }
        guard exclusions.count <= CalibrationRecordLimits.maximumExclusionsPerTake else {
            throw CalibrationError.capacityExceeded
        }
        for exclusion in exclusions {
            guard exclusion.source.epoch == source.epoch,
                exclusion.source.sampleRate == source.sampleRate,
                exclusion.source.startSample >= source.startSample,
                exclusion.source.endSample <= source.endSample
            else { throw CalibrationError.invalidRange }
        }
        if let mask {
            guard mask.source == source else { throw CalibrationError.invalidRange }
            guard mask.observations.count <= CalibrationRecordLimits.maximumMaskObservationsPerTake,
                mask.provenances.count <= 8,
                try mask.canonicalJSON().count <= CalibrationRecordLimits.maximumMaskBytesPerTake
            else { throw CalibrationError.capacityExceeded }
        }
        self.id = id
        self.media = media
        self.task = task
        self.repetition = repetition
        self.instruction = instruction
        self.instructionNotes = try calibrationText(instructionNotes)
        self.label = label
        self.exclusionReason = try calibrationOptionalText(exclusionReason, maximum: 4096)
        self.source = source
        self.exclusions = exclusions.sorted {
            if $0.source.startSample != $1.source.startSample {
                return $0.source.startSample < $1.source.startSample
            }
            if $0.source.endSample != $1.source.endSample {
                return $0.source.endSample < $1.source.endSample
            }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.reason < $1.reason
        }
        self.conditions = conditions
        self.profile = profile
        self.profileIdentity = try profile.identity()
        self.mask = mask
    }

    /// The previous take remains immutable. Publishing changed labels in a dataset
    /// requires a new dataset revision, which changes its complete fingerprint.
    public func replacingLabel(
        _ label: CalibrationListeningLabel?, exclusionReason: String? = nil
    ) throws -> Self {
        try Self(
            id: id, media: media, task: task, repetition: repetition,
            instruction: instruction, instructionNotes: instructionNotes,
            label: label, exclusionReason: exclusionReason, source: source,
            exclusions: exclusions, conditions: conditions, profile: profile, mask: mask)
    }

    /// Uses #34's mask algebra; this is not another speech or pitch detector.
    /// Original evidence tags survive selection composition. Explicit missing
    /// acquisition is ineligible and does not become zero-valued recorded PCM.
    public func effectiveMaskPlan() throws -> MaskPlan {
        var parameters: [String: ProfileSetting] = [
            "exclusionsSHA256": .text(try calibrationDigest(exclusions).sha256)
        ]
        if let mask {
            parameters["upstreamPlanSHA256"] = .text(
                CalibrationDigest(bytes: try mask.canonicalJSON()).sha256)
        }
        let selection = try MaskProvenance(
            kind: .externalAnnotation,
            identifier: VersionedIdentifier(name: "calibration-resolved-input", version: 1),
            parameters: parameters)
        let manual = try MaskProvenance(
            kind: .externalAnnotation,
            identifier: VersionedIdentifier(name: "calibration-explicit-exclusions", version: 1))
        var observations: [MaskObservation] = []
        if let mask {
            for segment in try MaskTimeline(mask).segments {
                observations.append(
                    try MaskObservation(
                        source: segment.source, provenanceIndex: 0,
                        selection: segment.isSelected ? .selected : .rejected, tags: segment.tags))
            }
        } else if source.sampleCount > 0 {
            observations.append(
                try MaskObservation(source: source, provenanceIndex: 0, selection: .selected))
        }
        if source.sampleCount > 0 {
            observations.append(
                try MaskObservation(
                    source: source, provenanceIndex: 1,
                    selection: exclusionReason == nil ? .selected : .rejected))
        }
        for exclusion in exclusions {
            observations.append(
                try MaskObservation(
                    source: exclusion.source, provenanceIndex: 1, selection: .rejected,
                    tags: exclusion.kind == .missingAcquisition ? [.missingAcquisition] : []))
        }
        return try MaskPlan(
            source: source, provenances: [selection, manual],
            policy: MaskSelectionPolicy(selectionSources: [0, 1], combination: .all),
            observations: observations, effectiveDelaySeconds: mask?.effectiveDelaySeconds ?? 0)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, media, task, repetition, instruction, instructionNotes, label, exclusionReason
        case source, exclusions, conditions, profile, profileIdentity, mask
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            media: c.decode(CalibrationMediaReference.self, forKey: .media),
            task: c.decode(CalibrationTask.self, forKey: .task),
            repetition: c.decode(Int.self, forKey: .repetition),
            instruction: c.decode(CalibrationProductionInstruction.self, forKey: .instruction),
            instructionNotes: c.decode(String.self, forKey: .instructionNotes),
            label: c.decodeIfPresent(CalibrationListeningLabel.self, forKey: .label),
            exclusionReason: c.decodeIfPresent(String.self, forKey: .exclusionReason),
            source: c.decode(SourceInterval.self, forKey: .source),
            exclusions: c.decode([CalibrationExclusion].self, forKey: .exclusions),
            conditions: c.decode(CalibrationRecordingConditions.self, forKey: .conditions),
            profile: c.decode(AnalysisScheduleProfile.self, forKey: .profile),
            mask: c.decodeIfPresent(MaskPlan.self, forKey: .mask))
        guard try c.decode(ProfileIdentity.self, forKey: .profileIdentity) == profileIdentity else {
            throw ContractError.invalidFingerprint
        }
    }
}

public struct CalibrationSession: Sendable, Hashable, Codable {
    public let id: UUID
    public let recordedAtUnixSeconds: Double?
    public let notes: String
    /// Canonical order is take identity, not acquisition or presentation order.
    public let takes: [CalibrationTake]

    public init(
        id: UUID, recordedAtUnixSeconds: Double? = nil, notes: String = "",
        takes: [CalibrationTake]
    ) throws {
        guard takes.count <= CalibrationRecordLimits.maximumTakes else {
            throw CalibrationError.capacityExceeded
        }
        guard Set(takes.map(\.id)).count == takes.count else {
            throw CalibrationError.duplicateIdentity
        }
        self.id = id
        self.recordedAtUnixSeconds = try calibrationTimestamp(recordedAtUnixSeconds)
        self.notes = try calibrationText(notes)
        self.takes = takes.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, recordedAtUnixSeconds, notes, takes
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            recordedAtUnixSeconds: c.decodeIfPresent(Double.self, forKey: .recordedAtUnixSeconds),
            notes: c.decode(String.self, forKey: .notes),
            takes: c.decode([CalibrationTake].self, forKey: .takes))
    }
}

/// An immutable version of a personal dataset. Numerical measurements and later
/// fitted targets are separate values; neither is needed to complete listening labels.
public struct CalibrationDataset: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let id: UUID
    public let revision: UInt64
    public let notes: String
    public let sessions: [CalibrationSession]
    public var takeCount: Int { sessions.reduce(0) { $0 + $1.takes.count } }

    public init(id: UUID, revision: UInt64, notes: String = "", sessions: [CalibrationSession])
        throws
    {
        guard revision > 0 else { throw CalibrationError.invalidRecord }
        guard sessions.count <= CalibrationRecordLimits.maximumSessions,
            sessions.reduce(0, { $0 + $1.takes.count }) <= CalibrationRecordLimits.maximumTakes
        else { throw CalibrationError.capacityExceeded }
        guard Set(sessions.map(\.id)).count == sessions.count else {
            throw CalibrationError.duplicateIdentity
        }
        var takes = Set<UUID>()
        var references: [String: CalibrationMediaReference] = [:]
        var lengths: [CalibrationDigest: Int64] = [:]
        for session in sessions {
            for take in session.takes {
                guard takes.insert(take.id).inserted else {
                    throw CalibrationError.duplicateIdentity
                }
                if let previous = references[take.media.referenceIdentifier], previous != take.media
                {
                    throw CalibrationError.invalidRecord
                }
                if let previous = lengths[take.media.content], previous != take.media.byteCount {
                    throw CalibrationError.invalidRecord
                }
                references[take.media.referenceIdentifier] = take.media
                lengths[take.media.content] = take.media.byteCount
            }
        }
        schemaVersion = 1
        self.id = id
        self.revision = revision
        self.notes = try calibrationText(notes)
        self.sessions = sessions.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Bounded interchange entry point. It imports references, never media bytes,
    /// opens no files, performs no analysis and produces no unified log content.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= CalibrationRecordLimits.maximumDatasetBytes else {
            throw CalibrationError.capacityExceeded
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func canonicalJSON() throws -> Data {
        let bytes = try canonicalContractJSON(self)
        guard bytes.count <= CalibrationRecordLimits.maximumDatasetBytes else {
            throw CalibrationError.capacityExceeded
        }
        return bytes
    }

    /// Includes labels, instructions, conditions, exclusions, media identities and
    /// every executable analysis setting, as well as the explicit dataset revision.
    public func identity() throws -> CalibrationDigest {
        CalibrationDigest(bytes: try canonicalJSON())
    }

    /// Explicit new version. Existing datasets and any fits bound to them remain unchanged.
    public func revised(sessions: [CalibrationSession]) throws -> Self {
        let next = revision.addingReportingOverflow(1)
        guard !next.overflow else { throw CalibrationError.arithmeticOverflow }
        return try Self(id: id, revision: next.partialValue, notes: notes, sessions: sessions)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, revision, notes, sessions
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            revision: c.decode(UInt64.self, forKey: .revision),
            notes: c.decode(String.self, forKey: .notes),
            sessions: c.decode([CalibrationSession].self, forKey: .sessions))
    }
}
