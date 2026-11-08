import Foundation

public struct SessionArchiveCalibrationSplit: Sendable, Hashable, Codable {
    public let datasetIndex: UInt32
    public let plan: CalibrationSplitPlan
    public init(datasetIndex: UInt32, plan: CalibrationSplitPlan) {
        self.datasetIndex = datasetIndex
        self.plan = plan
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case datasetIndex, plan }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            datasetIndex: c.decode(UInt32.self, forKey: .datasetIndex),
            plan: c.decode(CalibrationSplitPlan.self, forKey: .plan))
    }
}

/// Imported analysis is inspectable metadata, not permission to reuse numerical
/// results without verifying the original media and decoder again.
public struct SessionArchiveCalibrationAnalysis: Sendable, Hashable, Codable {
    public let datasetIndex: UInt32
    public let takeID: UUID
    public let record: CalibrationAnalysisRecord
    public init(datasetIndex: UInt32, takeID: UUID, record: CalibrationAnalysisRecord) {
        self.datasetIndex = datasetIndex
        self.takeID = takeID
        self.record = record
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case datasetIndex, takeID, record }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            datasetIndex: c.decode(UInt32.self, forKey: .datasetIndex),
            takeID: c.decode(UUID.self, forKey: .takeID),
            record: c.decode(CalibrationAnalysisRecord.self, forKey: .record))
    }
}

/// Even an exact match remains inspection data until the host supplies a verified
/// evaluation at the explicit activation boundary. No compatibility result means
/// that imported validation claims or audio have been authenticated.
public enum SessionArchiveTargetCompatibility: String, Sendable, Hashable {
    case requiresVerifiedEvaluation, differentProfile
    case unsupportedFittingImplementation, unsupportedAnalysisImplementation
}

extension SessionArchiveTarget {
    public func compatibility(with profile: AnalysisScheduleProfile) throws
        -> SessionArchiveTargetCompatibility
    {
        guard candidate.scope.profile == (try profile.identity()) else { return .differentProfile }
        guard candidate.implementation == PersonalTargetFitter.implementation else {
            return .unsupportedFittingImplementation
        }
        guard candidate.scope.analysisImplementation == CalibrationAnalysisKey.currentImplementation
        else {
            return .unsupportedAnalysisImplementation
        }
        return .requiresVerifiedEvaluation
    }
}

struct SessionArchiveCalibrationState {
    private(set) var datasets: [CalibrationDataset] = []
    private(set) var splits: [SessionArchiveCalibrationSplit] = []
    private(set) var analyses: [SessionArchiveCalibrationAnalysis] = []
    private(set) var targets: [SessionArchiveTarget] = []
    private var datasetIdentities: [CalibrationDigest] = []
    private var datasetRevisions: Set<Revision> = []
    private var splitIdentities: Set<CalibrationDigest> = []
    private var analysisKeys: Set<AnalysisKey> = []
    private var targetIdentities: Set<CalibrationDigest> = []

    private struct Revision: Hashable {
        let id: UUID
        let revision: UInt64
    }
    private struct AnalysisKey: Hashable {
        let dataset: UInt32
        let take: UUID
    }

    mutating func add(_ dataset: CalibrationDataset, payloadBytes: Int) throws -> UInt32 {
        guard payloadBytes <= CalibrationRecordLimits.maximumDatasetBytes else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        let revision = Revision(id: dataset.id, revision: dataset.revision)
        guard !datasetRevisions.contains(revision) else {
            throw SessionArchiveError.duplicateIdentity
        }
        let identity = try dataset.identity()
        let index = UInt32(datasets.count)
        datasets.append(dataset)
        datasetIdentities.append(identity)
        datasetRevisions.insert(revision)
        return index
    }

    mutating func add(_ split: SessionArchiveCalibrationSplit) throws -> UInt32 {
        let dataset = try dataset(at: split.datasetIndex)
        try split.plan.validate(for: dataset)
        let identity = try calibrationDigest(split.plan)
        guard !splitIdentities.contains(identity) else {
            throw SessionArchiveError.duplicateIdentity
        }
        let index = UInt32(splits.count)
        splits.append(split)
        splitIdentities.insert(identity)
        return index
    }

    mutating func add(_ analysis: SessionArchiveCalibrationAnalysis) throws -> UInt32 {
        let dataset = try dataset(at: analysis.datasetIndex)
        guard
            let take = dataset.sessions.lazy.flatMap(\.takes).first(where: {
                $0.id == analysis.takeID
            })
        else {
            throw SessionArchiveError.invalidMetadata
        }
        guard
            try analysis.record.canonicalJSON().count
                <= CalibrationAnalysisRecord.maximumEncodedBytes
        else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        try analysis.record.validate(for: take)
        let key = AnalysisKey(dataset: analysis.datasetIndex, take: analysis.takeID)
        guard !analysisKeys.contains(key) else { throw SessionArchiveError.duplicateIdentity }
        let index = UInt32(analyses.count)
        analyses.append(analysis)
        analysisKeys.insert(key)
        return index
    }

    mutating func add(_ target: SessionArchiveTarget) throws -> UInt32 {
        let dataset = try dataset(at: target.datasetIndex)
        guard Int(target.splitIndex) < splits.count else { throw SessionArchiveError.outOfOrder }
        let split = splits[Int(target.splitIndex)]
        let candidate = target.candidate
        guard split.datasetIndex == target.datasetIndex, candidate.calibrationID == dataset.id,
            candidate.calibrationRevision == dataset.revision,
            candidate.datasetIdentity == datasetIdentities[Int(target.datasetIndex)],
            candidate.splitIdentity == (try calibrationDigest(split.plan)),
            split.plan.assignments.contains(where: {
                $0.takeID == candidate.referenceTakeID && $0.role == .fitting
            }),
            let reference = dataset.sessions.lazy.flatMap(\.takes).first(where: {
                $0.id == candidate.referenceTakeID
            }),
            candidate.scope.profile == reference.profileIdentity,
            candidate.scope.task == reference.task,
            candidate.scope.conditions == reference.conditions
        else { throw SessionArchiveError.incompatibleProfile }
        let identity = try candidate.identity()
        guard !targetIdentities.contains(identity) else {
            throw SessionArchiveError.duplicateIdentity
        }
        let index = UInt32(targets.count)
        targets.append(target)
        targetIdentities.insert(identity)
        return index
    }

    func dataset(at index: UInt32) throws -> CalibrationDataset {
        guard Int(index) < datasets.count else { throw SessionArchiveError.outOfOrder }
        return datasets[Int(index)]
    }
}
