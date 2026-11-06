import Foundation
import Testing

@testable import HDXLVoiceProcessing

// Contract tests use deliberately fabricated summaries and evidence receipts.
// They are not DSP reference evidence or real listening/calibration observations.
func targetTestValidation(_ profile: AnalysisScheduleProfile) throws
    -> PersonalTargetValidationEvidence
{
    let identity = CalibrationDigest(bytes: Data("fabricated-contract-test-only".utf8))
    return try PersonalTargetValidationEvidence(
        profile: profile, sourceIdentity: identity,
        components: [.cpps, .fundamentalFrequency, .levelDBFS].map {
            try PersonalTargetMetricValidation(
                metric: $0, referenceIdentity: identity, reportIdentity: identity,
                referenceCases: 1, chunkComparisons: 1, boundaryCases: 1,
                maximumReferenceErrorToBudget: 0, maximumChunkErrorToBudget: 0,
                maximumBoundaryErrorToBudget: 0)
        })
}

func targetTestRecord(
    _ take: CalibrationTake, cpps: Double? = nil, pitch: Double = 200, level: Double = -20,
    available: Int = 8, unavailable: Int = 0, warnings: [String: Int] = [:]
) throws -> CalibrationAnalysisRecord {
    let decoder = try CalibrationDecoderProvenance(
        identifier: "fabricated-test-decoder", runtime: "contract-tests-v1", storage: [:],
        decodedPCM: take.profile.inputFormat, fileSampleCount: take.source.endSample)
    let mask = try PreparedAnalysisMask(
        timeline: MaskTimeline(take.effectiveMaskPlan()), scope: .selected)
    let prominence = cpps ?? (take.label?.preference == .preferred ? 10 : 4)
    return try CalibrationAnalysisRecord(
        key: CalibrationAnalysisKey(take: take, decoder: decoder),
        coverage: CalibrationCoverage(mask.coverage(of: take.source)),
        summaries: calibrationMetrics(for: take.profile).map { metric in
            let value: Double
            switch metric {
            case .cpp, .cpps: value = prominence
            case .fundamentalFrequency, .trackedFundamentalFrequency: value = pitch
            case .levelDBFS: value = level
            case .rms: value = pow(10, level / 20)
            default: throw PersonalTargetError.invalidObservation
            }
            return try CalibrationMetricSummary(
                metric: metric, values: Array(repeating: value, count: available),
                unavailable: unavailable > 0 ? ["insufficientData": unavailable] : [:],
                warnings: warnings)
        })
}

func targetTestCopy(
    _ take: CalibrationTake, id: UUID? = nil, task: CalibrationTask? = nil,
    conditions: CalibrationRecordingConditions? = nil, profile: AnalysisScheduleProfile? = nil,
    exclusions: [CalibrationExclusion]? = nil
) throws -> CalibrationTake {
    try CalibrationTake(
        id: id ?? take.id, media: take.media, task: task ?? take.task,
        repetition: take.repetition, instruction: take.instruction,
        instructionNotes: take.instructionNotes, label: take.label,
        exclusionReason: take.exclusionReason, source: take.source,
        exclusions: exclusions ?? take.exclusions, conditions: conditions ?? take.conditions,
        profile: profile ?? take.profile, mask: take.mask)
}

struct TargetTestFixture {
    let dataset: CalibrationDataset
    let split: CalibrationSplitPlan
    let partition: CalibrationDatasetPartition
    let reference: CalibrationTake
    let validation: PersonalTargetValidationEvidence
    let training: [UUID: CalibrationAnalysisRecord]
    let evaluation: [UUID: CalibrationAnalysisRecord]

    init(
        dataset: CalibrationDataset,
        makeRecord: (CalibrationAssignedTake) throws -> CalibrationAnalysisRecord = {
            try targetTestRecord($0.take)
        }
    ) throws {
        self.dataset = dataset
        split = try CalibrationSplitPlan(
            dataset: dataset, sessionEvaluationIDs: Array(dataset.sessions.suffix(2).map(\.id)),
            recordingEvaluationFraction: 0.5, seed: 53)
        partition = try split.partition(dataset: dataset)
        reference = try #require(partition.fitting.first?.take)
        validation = try targetTestValidation(reference.profile)
        training = try Dictionary(
            uniqueKeysWithValues: partition.fitting.map {
                ($0.take.id, try makeRecord($0))
            })
        evaluation = try Dictionary(
            uniqueKeysWithValues: (partition.recordingEvaluation + partition.sessionEvaluation).map
            {
                ($0.take.id, try makeRecord($0))
            })
    }

    func fit(
        training: [UUID: CalibrationAnalysisRecord]? = nil,
        policy: PersonalTargetPolicy? = nil
    ) throws -> PersonalTargetFit {
        try PersonalTargetFitter.fit(
            dataset: dataset, split: split, trainingAnalyses: training ?? self.training,
            referenceTakeID: reference.id, validation: validation,
            policy: policy ?? PersonalTargetPolicy())
    }

    func evaluate(
        _ fit: PersonalTargetFit, analyses: [UUID: CalibrationAnalysisRecord]? = nil
    ) throws -> PersonalTargetEvaluation {
        try PersonalTargetFitter.evaluate(
            fit, dataset: dataset, split: split, evaluationAnalyses: analyses ?? evaluation)
    }
}

// Labels are assigned after deterministic role partitioning only to construct
// balanced software scenarios. This is explicitly not a real-data study design.
func targetTestDataset(sessions: Int = 4, takesPerSession: Int = 16) throws -> CalibrationDataset {
    let records = try (0..<sessions).map { session in
        try CalibrationSession(
            id: calibrationTestID(800 + session),
            takes: (0..<takesPerSession).map {
                try calibrationTestTake(1 + session * takesPerSession + $0)
            })
    }
    let initial = try CalibrationDataset(id: calibrationTestID(900), revision: 1, sessions: records)
    let split = try CalibrationSplitPlan(
        dataset: initial, sessionEvaluationIDs: Array(records.suffix(2).map(\.id)),
        recordingEvaluationFraction: 0.5, seed: 53)
    let roles = Dictionary(uniqueKeysWithValues: split.assignments.map { ($0.takeID, $0.role) })
    let labeled = try records.map { session in
        var counts: [CalibrationSplitRole: Int] = [:]
        let takes = try session.takes.map { take in
            let role = roles[take.id]!
            let index = counts[role, default: 0]
            counts[role] = index + 1
            return try take.replacingLabel(
                CalibrationListeningLabel(
                    preference: index.isMultiple(of: 2) ? .preferred : .usual,
                    confidence: 1, exposure: .blindedBeforeFeatures))
        }
        return try CalibrationSession(id: session.id, takes: takes)
    }
    return try CalibrationDataset(id: initial.id, revision: 1, sessions: labeled)
}

func targetTestRevised(
    _ dataset: CalibrationDataset,
    transform: (CalibrationTake) throws -> CalibrationTake
) throws -> CalibrationDataset {
    try dataset.revised(
        sessions: dataset.sessions.map { session in
            try CalibrationSession(id: session.id, takes: session.takes.map(transform))
        })
}
