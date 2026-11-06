import Foundation

public enum CalibrationSplitRole: String, Sendable, Hashable, Codable, CaseIterable {
    case fitting, recordingEvaluation, sessionEvaluation
}

public struct CalibrationSplitAssignment: Sendable, Hashable, Codable {
    public let takeID: UUID
    /// Connected group of original acquisitions and identical media hashes.
    public let recordingGroup: CalibrationDigest
    public let role: CalibrationSplitRole

    init(takeID: UUID, recordingGroup: CalibrationDigest, role: CalibrationSplitRole) {
        self.takeID = takeID
        self.recordingGroup = recordingGroup
        self.role = role
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case takeID, recordingGroup, role
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        self.init(
            takeID: try c.decode(UUID.self, forKey: .takeID),
            recordingGroup: try c.decode(CalibrationDigest.self, forKey: .recordingGroup),
            role: try c.decode(CalibrationSplitRole.self, forKey: .role))
    }
}

private struct CalibrationGroupingEntry {
    let sessionID: UUID
    let take: CalibrationTake
}

private struct CalibrationGroupIdentity: Encodable {
    let domain = "calibration-recording-group-v1"
    let acquisitions: [UUID]
    let contents: [CalibrationDigest]
}

private struct CalibrationGroupSplitSeed: Encodable {
    let domain = "calibration-recording-holdout-v1"
    let seed: UInt64
    let group: CalibrationDigest
}

/// Immutable, inspectable assignment of complete recordings and complete sessions.
/// This is a sampling policy, not evidence that a personal target can be activated.
/// Use partition(dataset:) or decode(_:for:) to verify a persisted plan's binding.
public struct CalibrationSplitPlan: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let datasetIdentity: CalibrationDigest
    public let seed: UInt64
    public let sessionEvaluationIDs: [UUID]
    public let recordingEvaluationFraction: Double
    public let assignments: [CalibrationSplitAssignment]

    /// Within non-held-out sessions, a seeded hash assigns a whole connected
    /// recording group to recording evaluation or fitting. All takes from explicit
    /// held-out sessions are session evaluation. A recording shared across that
    /// session boundary is rejected rather than silently contaminating either side.
    public init(
        dataset: CalibrationDataset, sessionEvaluationIDs: [UUID],
        recordingEvaluationFraction: Double, seed: UInt64
    ) throws {
        guard dataset.takeCount > 0, recordingEvaluationFraction.isFinite,
            (0...1).contains(recordingEvaluationFraction),
            Set(sessionEvaluationIDs).count == sessionEvaluationIDs.count
        else { throw CalibrationError.invalidSplit }
        let evaluation = Set(sessionEvaluationIDs)
        let nonemptySessions = Set(dataset.sessions.filter { !$0.takes.isEmpty }.map(\.id))
        guard evaluation.isSubset(of: nonemptySessions) else { throw CalibrationError.invalidSplit }
        let entries = dataset.sessions.flatMap { session in
            session.takes.map { CalibrationGroupingEntry(sessionID: session.id, take: $0) }
        }
        var parents = Array(entries.indices)
        func root(_ index: Int) -> Int {
            var current = index
            while parents[current] != current { current = parents[current] }
            return current
        }
        var acquisitionIndices: [UUID: Int] = [:]
        var contentIndices: [CalibrationDigest: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if let prior = acquisitionIndices[entry.take.media.originalRecordingID] {
                let left = root(index)
                let right = root(prior)
                parents[max(left, right)] = min(left, right)
            }
            if let prior = contentIndices[entry.take.media.content] {
                let left = root(index)
                let right = root(prior)
                parents[max(left, right)] = min(left, right)
            }
            acquisitionIndices[entry.take.media.originalRecordingID] = index
            contentIndices[entry.take.media.content] = index
        }
        var groups: [Int: [CalibrationGroupingEntry]] = [:]
        for index in entries.indices { groups[root(index), default: []].append(entries[index]) }
        var assignments: [CalibrationSplitAssignment] = []
        for group in groups.values {
            let heldOut = group.filter { evaluation.contains($0.sessionID) }.count
            guard heldOut == 0 || heldOut == group.count else {
                throw CalibrationError.recordingLeakage
            }
            let identity = try calibrationDigest(
                CalibrationGroupIdentity(
                    acquisitions: Array(Set(group.map { $0.take.media.originalRecordingID }))
                        .sorted { $0.uuidString < $1.uuidString },
                    contents: Array(Set(group.map { $0.take.media.content }))
                        .sorted { $0.sha256 < $1.sha256 }))
            let role: CalibrationSplitRole
            if heldOut == group.count {
                role = .sessionEvaluation
            } else {
                let digest = try calibrationDigest(
                    CalibrationGroupSplitSeed(seed: seed, group: identity))
                // Exactly representable UInt32 / 2^32 draw; independent of Swift's
                // randomized Hasher, platform endian order and caller array order.
                let integer = UInt32(digest.sha256.prefix(8), radix: 16)!
                let draw = Double(integer) / 4_294_967_296
                role = draw < recordingEvaluationFraction ? .recordingEvaluation : .fitting
            }
            for entry in group {
                assignments.append(
                    CalibrationSplitAssignment(
                        takeID: entry.take.id, recordingGroup: identity, role: role))
            }
        }
        try self.init(
            datasetIdentity: dataset.identity(), seed: seed,
            sessionEvaluationIDs: sessionEvaluationIDs,
            recordingEvaluationFraction: recordingEvaluationFraction, assignments: assignments)
    }

    private init(
        datasetIdentity: CalibrationDigest, seed: UInt64, sessionEvaluationIDs: [UUID],
        recordingEvaluationFraction: Double, assignments: [CalibrationSplitAssignment]
    ) throws {
        guard !assignments.isEmpty, assignments.count <= CalibrationRecordLimits.maximumTakes,
            sessionEvaluationIDs.count <= CalibrationRecordLimits.maximumSessions,
            recordingEvaluationFraction.isFinite, (0...1).contains(recordingEvaluationFraction),
            Set(sessionEvaluationIDs).count == sessionEvaluationIDs.count,
            Set(assignments.map(\.takeID)).count == assignments.count
        else { throw CalibrationError.invalidSplit }
        var groupRoles: [CalibrationDigest: CalibrationSplitRole] = [:]
        for assignment in assignments {
            if let previous = groupRoles[assignment.recordingGroup], previous != assignment.role {
                throw CalibrationError.recordingLeakage
            }
            groupRoles[assignment.recordingGroup] = assignment.role
        }
        schemaVersion = 1
        self.datasetIdentity = datasetIdentity
        self.seed = seed
        self.sessionEvaluationIDs = sessionEvaluationIDs.sorted { $0.uuidString < $1.uuidString }
        self.recordingEvaluationFraction =
            recordingEvaluationFraction == 0 ? 0 : recordingEvaluationFraction
        self.assignments = assignments.sorted { $0.takeID.uuidString < $1.takeID.uuidString }
    }

    /// Full identity includes labels, conditions and revision. Changed held-out
    /// examples cannot affect an existing plan/fit through an unnoticed mutation.
    public func validate(for dataset: CalibrationDataset) throws {
        guard try dataset.identity() == datasetIdentity else {
            throw CalibrationError.incompatibleDataset
        }
        let expected = try Self(
            dataset: dataset, sessionEvaluationIDs: sessionEvaluationIDs,
            recordingEvaluationFraction: recordingEvaluationFraction, seed: seed)
        guard expected == self else { throw CalibrationError.invalidSplit }
    }

    public func partition(dataset: CalibrationDataset) throws -> CalibrationDatasetPartition {
        try validate(for: dataset)
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.takeID, $0) })
        var members: [CalibrationAssignedTake] = []
        for session in dataset.sessions {
            for take in session.takes {
                guard let assignment = byID[take.id] else { throw CalibrationError.invalidSplit }
                members.append(
                    CalibrationAssignedTake(
                        sessionID: session.id, take: take,
                        recordingGroup: assignment.recordingGroup, role: assignment.role))
            }
        }
        return CalibrationDatasetPartition(
            plan: self,
            fitting: members.filter { $0.role == .fitting },
            recordingEvaluation: members.filter { $0.role == .recordingEvaluation },
            sessionEvaluation: members.filter { $0.role == .sessionEvaluation })
    }

    public func canonicalJSON() throws -> Data { try canonicalContractJSON(self) }

    public static func decode(_ data: Data, for dataset: CalibrationDataset) throws -> Self {
        guard data.count <= 1024 * 1024 else { throw CalibrationError.capacityExceeded }
        let plan = try JSONDecoder().decode(Self.self, from: data)
        try plan.validate(for: dataset)
        return plan
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, datasetIdentity, seed, sessionEvaluationIDs
        case recordingEvaluationFraction, assignments
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            datasetIdentity: c.decode(CalibrationDigest.self, forKey: .datasetIdentity),
            seed: c.decode(UInt64.self, forKey: .seed),
            sessionEvaluationIDs: c.decode([UUID].self, forKey: .sessionEvaluationIDs),
            recordingEvaluationFraction: c.decode(
                Double.self, forKey: .recordingEvaluationFraction),
            assignments: c.decode([CalibrationSplitAssignment].self, forKey: .assignments))
    }
}

public struct CalibrationAssignedTake: Sendable, Hashable {
    public let sessionID: UUID
    public let take: CalibrationTake
    public let recordingGroup: CalibrationDigest
    public let role: CalibrationSplitRole
}

/// Only a plan validated against the exact dataset can produce this partition.
/// Separate arrays keep evaluation examples distinct from the fitting population.
public struct CalibrationDatasetPartition: Sendable, Hashable {
    public let plan: CalibrationSplitPlan
    public let fitting: [CalibrationAssignedTake]
    public let recordingEvaluation: [CalibrationAssignedTake]
    public let sessionEvaluation: [CalibrationAssignedTake]
}
