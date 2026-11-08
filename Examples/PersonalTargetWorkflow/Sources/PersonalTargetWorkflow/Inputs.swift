import Foundation
import HDXLVoiceProcessing

enum ExampleError: Error { case invalidInput, verificationFailed }

func require(_ condition: Bool) throws {
    guard condition else { throw ExampleError.verificationFailed }
}

func identifier(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

struct ReferenceInputs: Decodable {
    struct Row: Decodable {
        let id, session: Int
        let role: CalibrationSplitRole
        let groupSHA256: String
        let label: CalibrationListeningPreference
        let cpps, pitch, level: Double
    }
    struct Scenario: Decodable {
        let name: String
        let rows: [Row]
        let activated: Bool
    }
    let schemaVersion: Int
    let syntheticOnly: Bool
    let cases: [Scenario]
}

/// The evidence runner verifies the actual native report and retained independent
/// references before writing this envelope. It is host provenance, not a signature.
struct CheckedEvidence: Decodable {
    struct Component: Decodable {
        let metric: ScheduledMetric
        let referenceCases, chunkComparisons, boundaryCases: Int
        let maximumReferenceErrorToBudget, maximumChunkErrorToBudget: Double
        let maximumBoundaryErrorToBudget: Double
    }
    let schemaVersion: Int
    let status: String
    let profile: AnalysisScheduleProfile
    let sourceIdentity, referenceIdentity, reportIdentity: CalibrationDigest
    let analysisImplementation: VersionedIdentifier
    let components: [Component]

    func validation() throws -> PersonalTargetValidationEvidence {
        try require(schemaVersion == 1 && status == "passed")
        try require(
            try profile.identity().sha256
                == "c9fbb8420ee5ac5f76254129d42d10358dd393f868a5173ee7dea45e0ce9b01b")
        return try PersonalTargetValidationEvidence(
            profile: profile, analysisImplementation: analysisImplementation,
            sourceIdentity: sourceIdentity,
            components: components.map {
                try PersonalTargetMetricValidation(
                    metric: $0.metric, referenceIdentity: referenceIdentity,
                    reportIdentity: reportIdentity,
                    referenceCases: $0.referenceCases, chunkComparisons: $0.chunkComparisons,
                    boundaryCases: $0.boundaryCases,
                    maximumReferenceErrorToBudget: $0.maximumReferenceErrorToBudget,
                    maximumChunkErrorToBudget: $0.maximumChunkErrorToBudget,
                    maximumBoundaryErrorToBudget: $0.maximumBoundaryErrorToBudget)
            })
    }
}

/// Fabricated records are only a test of the public import/fitting contracts.
/// Real applications obtain records from CalibrationFileAnalysisBatch.
private struct SyntheticSummary: Encodable {
    let metric: ScheduledMetric
    let availableCount = 8
    let unavailable: [String: Int] = [:]
    let warnings: [String: Int] = [:]
    let minimum, lowerQuartile, median, upperQuartile, maximum: Double

    init(metric: ScheduledMetric, value: Double) {
        self.metric = metric
        minimum = value
        lowerQuartile = value
        median = value
        upperQuartile = value
        maximum = value
    }
}

private struct SyntheticRecord: Encodable {
    let key: CalibrationAnalysisKey
    let coverage: CalibrationCoverage
    let summaries: [SyntheticSummary]
}

func syntheticAnalysis(take: CalibrationTake, cpps: Double, pitch: Double, level: Double) throws
    -> CalibrationAnalysisRecord
{
    let decoder = try CalibrationDecoderProvenance(
        identifier: "fabricated-summary-fixture", runtime: "personal-target-software-evidence-v1",
        storage: ["syntheticOnly": .boolean(true)], decodedPCM: take.profile.inputFormat,
        fileSampleCount: take.source.sampleCount)
    let mask = try PreparedAnalysisMask(
        timeline: MaskTimeline(take.effectiveMaskPlan()), scope: .selected)
    let payload = try SyntheticRecord(
        key: CalibrationAnalysisKey(take: take, decoder: decoder),
        coverage: CalibrationCoverage(mask.coverage(of: take.source)),
        summaries: [
            SyntheticSummary(metric: .cpps, value: cpps),
            SyntheticSummary(metric: .cpp, value: cpps),
            SyntheticSummary(metric: .fundamentalFrequency, value: pitch),
            SyntheticSummary(metric: .levelDBFS, value: level),
            SyntheticSummary(metric: .rms, value: pow(10, level / 20)),
        ])
    return try CalibrationAnalysisRecord.decode(JSONEncoder().encode(payload), for: take)
}

func syntheticTake(
    id: Int, label: CalibrationListeningPreference, profile: AnalysisScheduleProfile,
    source: SourceInterval? = nil
)
    throws
    -> CalibrationTake
{
    try CalibrationTake(
        id: identifier(id),
        media: CalibrationMediaReference(
            referenceIdentifier: "synthetic-summary-\(id)", originalRecordingID: identifier(id),
            content: CalibrationDigest(bytes: Data("test-audio-\(id)".utf8)), byteCount: 10000),
        task: CalibrationTask(
            category: .sustainedVowel, promptIdentifier: "software-fixture",
            prompt: "Synthetic software scenario; no listening performed", languageTag: "en"),
        repetition: 1, instruction: .preferred,
        label: CalibrationListeningLabel(
            preference: label, confidence: 1, exposure: .blindedBeforeFeatures),
        source: source
            ?? SourceInterval(
                epoch: StreamEpoch(streamID: identifier(id)), startSample: 0,
                sampleCount: 3200, sampleRate: 16000),
        conditions: CalibrationRecordingConditions(
            routeIdentifier: "synthetic-route", roomIdentifier: "synthetic-room",
            microphoneDistanceMeters: 0.2, inputGainDB: 0,
            recordingSettings: ["automaticGainControl": .boolean(false)]), profile: profile)
}

struct PreparedInputs {
    let dataset: CalibrationDataset
    let split: CalibrationSplitPlan
    let referenceTakeID: UUID
    let training, evaluation: [UUID: CalibrationAnalysisRecord]
    let validation: PersonalTargetValidationEvidence

    init(rows: [ReferenceInputs.Row], evidence: CheckedEvidence) throws {
        let sessions = try Dictionary(grouping: rows, by: \.session).map { session, members in
            try CalibrationSession(
                id: identifier(session),
                takes: members.map {
                    try syntheticTake(id: $0.id, label: $0.label, profile: evidence.profile)
                })
        }
        dataset = try CalibrationDataset(id: identifier(900), revision: 1, sessions: sessions)
        split = try CalibrationSplitPlan(
            dataset: dataset, sessionEvaluationIDs: Array(dataset.sessions.suffix(2).map(\.id)),
            recordingEvaluationFraction: 0.5, seed: 53)
        let partition = try split.partition(dataset: dataset)
        guard let first = partition.fitting.first else { throw ExampleError.invalidInput }
        referenceTakeID = first.take.id
        let byID = Dictionary(uniqueKeysWithValues: rows.map { (identifier($0.id), $0) })
        func analyses(_ members: [CalibrationAssignedTake]) throws -> [UUID:
            CalibrationAnalysisRecord]
        {
            try Dictionary(
                uniqueKeysWithValues: members.map { member in
                    guard let row = byID[member.take.id] else { throw ExampleError.invalidInput }
                    if !row.groupSHA256.isEmpty {
                        try require(
                            member.role == row.role
                                && member.recordingGroup.sha256 == row.groupSHA256)
                    }
                    return (
                        member.take.id,
                        try syntheticAnalysis(
                            take: member.take, cpps: row.cpps, pitch: row.pitch, level: row.level)
                    )
                })
        }
        training = try analyses(partition.fitting)
        evaluation = try analyses(partition.recordingEvaluation + partition.sessionEvaluation)
        validation = try evidence.validation()
    }

    func fit() throws -> PersonalTargetFit {
        try PersonalTargetFitter.fit(
            dataset: dataset, split: split, trainingAnalyses: training,
            referenceTakeID: referenceTakeID, validation: validation, policy: PersonalTargetPolicy()
        )
    }

    func evaluate(_ fit: PersonalTargetFit) throws -> PersonalTargetEvaluation {
        try PersonalTargetFitter.evaluate(
            fit, dataset: dataset, split: split, evaluationAnalyses: evaluation)
    }
}
