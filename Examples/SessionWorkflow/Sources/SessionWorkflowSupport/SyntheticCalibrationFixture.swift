import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

/// Fixture generation only. Summaries, listening labels and validation receipts
/// are deliberately fabricated contract inputs. They are not DSP measurements,
/// listening evidence, or a recipe for accepting a real personal target.
public enum SyntheticCalibrationFixture {
    public static func generate(referenceURL: URL, outputDirectory: URL) throws {
        guard !FileManager.default.fileExists(atPath: outputDirectory.path) else {
            throw Failure.existingOutput
        }
        let referenceBytes = try Data(contentsOf: referenceURL)
        let reference = try JSONDecoder().decode(Reference.self, from: referenceBytes)
        guard reference.schemaVersion == 1, reference.syntheticOnly,
            let scenario = reference.cases.first(where: { $0.name == "separated" }),
            scenario.rows.count == 64, scenario.activated,
            Set(scenario.rows.map(\.id)) == Set(1...64),
            Set(scenario.rows.map(\.session)) == Set(800...803)
        else { throw Failure.invalidReference }
        let profile = try profile()
        let rows = Dictionary(uniqueKeysWithValues: scenario.rows.map { (id($0.id), $0) })
        let sessions = try Dictionary(grouping: scenario.rows, by: \.session).map { session, rows in
            try CalibrationSession(
                id: id(session), takes: rows.map { try take($0, profile: profile) })
        }
        let dataset = try CalibrationDataset(
            id: id(900), revision: 1,
            notes:
                "Fabricated contract fixture; no listening, recording or validated personal target",
            sessions: sessions)
        let split = try CalibrationSplitPlan(
            dataset: dataset, sessionEvaluationIDs: Array(dataset.sessions.suffix(2).map(\.id)),
            recordingEvaluationFraction: 0.5, seed: 53)
        let partition = try split.partition(dataset: dataset)
        guard let first = partition.fitting.first else { throw Failure.invalidReference }
        func analyses(_ members: [CalibrationAssignedTake]) throws -> [UUID:
            CalibrationAnalysisRecord]
        {
            try Dictionary(
                uniqueKeysWithValues: members.map { member in
                    guard let row = rows[member.take.id], row.role == member.role,
                        row.groupSHA256 == member.recordingGroup.sha256
                    else { throw Failure.invalidReference }
                    return (member.take.id, try analysis(member.take, row: row))
                })
        }
        let training = try analyses(partition.fitting)
        let evaluation = try analyses(partition.recordingEvaluation + partition.sessionEvaluation)
        let fabricated = CalibrationDigest(
            bytes: Data("fabricated-session-contract-validation-not-DSP-evidence".utf8))
        let validation = try PersonalTargetValidationEvidence(
            profile: profile, sourceIdentity: fabricated,
            components: [.cpps, .fundamentalFrequency, .levelDBFS].map {
                try PersonalTargetMetricValidation(
                    metric: $0, referenceIdentity: fabricated, reportIdentity: fabricated,
                    referenceCases: 1, chunkComparisons: 1, boundaryCases: 1,
                    maximumReferenceErrorToBudget: 0, maximumChunkErrorToBudget: 0,
                    maximumBoundaryErrorToBudget: 0)
            })
        let fit = try PersonalTargetFitter.fit(
            dataset: dataset, split: split, trainingAnalyses: training,
            referenceTakeID: first.take.id, validation: validation, policy: PersonalTargetPolicy())
        let evaluated = try PersonalTargetFitter.evaluate(
            fit, dataset: dataset, split: split, evaluationAnalyses: evaluation)
        guard let candidate = fit.candidate, evaluated.activated != nil,
            candidate.rule.preferredInterval.lower == scenario.preferredInterval.lower,
            candidate.rule.preferredInterval.upper == scenario.preferredInterval.upper,
            candidate.rule.observedCPPS.lower == scenario.observedCPPS.lower,
            candidate.rule.observedCPPS.upper == scenario.observedCPPS.upper,
            candidate.rule.direction.rawValue == scenario.direction,
            candidate.rule.preferredTraining.count == 7, candidate.rule.usualTraining.count == 7
        else { throw Failure.invalidReference }
        let target = try SessionArchiveTarget(
            datasetIndex: 0, splitIndex: 0, candidate: candidate, validation: validation,
            claimedEvaluationIdentity: evaluated.evaluationIdentity)
        // Preserve a structurally understood rule with an unsupported fitter
        // receipt. Inspection must report incompatibility rather than activate it.
        guard
            var unsupportedJSON =
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(target))
                as? [String: Any],
            var unsupportedCandidate = unsupportedJSON["candidate"] as? [String: Any]
        else { throw Failure.invalidReference }
        unsupportedCandidate["implementation"] = ["name": "personal-cpps-iqr-band", "version": 99]
        unsupportedJSON["candidate"] = unsupportedCandidate
        unsupportedJSON["claimedEvaluationIdentity"] = NSNull()
        let unsupported = try JSONDecoder().decode(
            SessionArchiveTarget.self, from: JSONSerialization.data(withJSONObject: unsupportedJSON)
        )
        // Refuse any existing output directory; generation never silently replaces goldens.
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: false)
        let archive = outputDirectory.appendingPathComponent("calibration-v1.hvps")
        try SessionArchiveFiles.write(
            to: archive,
            header: SessionArchiveHeader(
                id: id(5804),
                producer: VersionedIdentifier(name: "synthetic-calibration-fixture", version: 1),
                createdAtUnixSeconds: 1_700_000_000,
                notes:
                    "Fabricated summaries and validation claims; inspection fixture, not verified DSP or listening evidence"
            ),
            limits: SessionArchiveLimits()
        ) { writer in
            try writer.addProfile(.schedule(profile))
            try writer.addCalibrationDataset(dataset)
            try writer.addCalibrationSplit(
                SessionArchiveCalibrationSplit(datasetIndex: 0, plan: split))
            let all = training.merging(evaluation) { left, _ in left }
            for key in all.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                try writer.addCalibrationAnalysis(
                    SessionArchiveCalibrationAnalysis(
                        datasetIndex: 0, takeID: key, record: all[key]!))
            }
            try writer.addTarget(target)
            try writer.addTarget(unsupported)
        }
        let bytes = try Data(contentsOf: archive)
        let manifest = Manifest(
            schemaVersion: 1, generator: "synthetic-calibration-fixture-v1",
            containsHumanVoice: false,
            sourceReferenceSHA256: CalibrationDigest(bytes: referenceBytes).sha256,
            name: "calibration-v1.hvps", byteCount: bytes.count,
            sha256: CalibrationDigest(bytes: bytes).sha256,
            profileSHA256: try profile.identity().sha256,
            datasetSHA256: try dataset.identity().sha256,
            splitSHA256: try CalibrationDigest(bytes: split.canonicalJSON()).sha256,
            targetSHA256: try candidate.identity().sha256,
            sessionCount: dataset.sessions.count, takeCount: dataset.takeCount,
            analysisCount: training.count + evaluation.count,
            fittingCount: partition.fitting.count,
            recordingEvaluationCount: partition.recordingEvaluation.count,
            sessionEvaluationCount: partition.sessionEvaluation.count,
            targetCount: 2, selectedSamplesPerTake: 3184)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(manifest) + Data([10])).write(
            to: outputDirectory.appendingPathComponent("calibration-manifest.json"),
            options: .withoutOverwriting)
    }

    private enum Failure: Error { case invalidReference, existingOutput }
    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
    private static func profile() throws -> AnalysisScheduleProfile {
        try AnalysisScheduleProfile(
            inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
            channels: PCMChannelSelection(channelIndex: 0),
            levels: LevelConfiguration(
                sampleRate: 16000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
                accumulation: .compensatedSliding, weighting: .none),
            pitch: YINProfile(
                estimator: YINConfiguration(
                    sampleRate: 16000, inputPrecision: .float64, pitchFloorHz: 50,
                    pitchCeilingHz: 700, hopLength: 160)),
            cpps: CPPSProfile.murtonRecipePraat7(
                sourceSampleRate: 16000, declaredInputBandwidthHz: 8000))
    }
    private static func take(_ row: Reference.Row, profile: AnalysisScheduleProfile) throws
        -> CalibrationTake
    {
        let source = try SourceInterval(
            epoch: StreamEpoch(streamID: id(row.id)), startSample: 0,
            sampleCount: 3200, sampleRate: 16000)
        let mask = try MaskPlan(
            source: source,
            provenances: [
                MaskProvenance(
                    kind: .externalAnnotation,
                    identifier: VersionedIdentifier(
                        name: "fabricated-phonation-annotation", version: 1))
            ],
            policy: MaskSelectionPolicy(),
            observations: [
                MaskObservation(source: source, provenanceIndex: 0, tags: [.speechDetected])
            ])
        return try CalibrationTake(
            id: id(row.id),
            media: CalibrationMediaReference(
                referenceIdentifier: "synthetic-summary-\(row.id)", originalRecordingID: id(row.id),
                content: CalibrationDigest(bytes: Data("test-audio-\(row.id)".utf8)),
                byteCount: 10000),
            task: CalibrationTask(
                category: .sustainedVowel, promptIdentifier: "software-fixture",
                prompt: "Synthetic café 原稿; no listening performed", languageTag: "en"),
            repetition: 1, instruction: .preferred,
            instructionNotes: "Fabricated instruction, independent of label",
            label: CalibrationListeningLabel(
                preference: row.label, confidence: 1,
                notes: "Scripted fixture label", exposure: .blindedBeforeFeatures),
            source: source,
            exclusions: [
                CalibrationExclusion(
                    source: SourceInterval(
                        epoch: source.epoch, startSample: 0, sampleCount: 16, sampleRate: 16000),
                    kind: .userSelection, reason: "Synthetic lead-in exclusion")
            ],
            conditions: CalibrationRecordingConditions(
                routeIdentifier: "synthetic-route", roomIdentifier: "synthetic-room",
                microphoneDistanceMeters: 0.2, inputGainDB: 0,
                recordingSettings: ["automaticGainControl": .boolean(false)]), profile: profile,
            mask: mask)
    }
    private static func analysis(_ take: CalibrationTake, row: Reference.Row) throws
        -> CalibrationAnalysisRecord
    {
        let decoder = try CalibrationDecoderProvenance(
            identifier: "fabricated-summary-fixture", runtime: "synthetic-session-contract-v1",
            storage: ["syntheticOnly": .boolean(true)], decodedPCM: take.profile.inputFormat,
            fileSampleCount: take.source.endSample)
        let mask = try PreparedAnalysisMask(
            timeline: MaskTimeline(take.effectiveMaskPlan()), scope: .selected)
        let payload = try Record(
            key: CalibrationAnalysisKey(take: take, decoder: decoder),
            coverage: CalibrationCoverage(mask.coverage(of: take.source)),
            summaries: [
                Summary(.cpps, row.cpps), Summary(.cpp, row.cpps),
                Summary(.fundamentalFrequency, row.pitch), Summary(.levelDBFS, row.level),
                Summary(.rms, pow(10, row.level / 20)),
            ])
        return try CalibrationAnalysisRecord.decode(JSONEncoder().encode(payload), for: take)
    }
    private struct Summary: Encodable {
        let metric: ScheduledMetric
        let availableCount = 8
        let unavailable: [String: Int] = [:]
        let warnings: [String: Int] = [:]
        let minimum, lowerQuartile, median, upperQuartile, maximum: Double
        init(_ metric: ScheduledMetric, _ value: Double) {
            self.metric = metric
            minimum = value
            lowerQuartile = value
            median = value
            upperQuartile = value
            maximum = value
        }
    }
    private struct Record: Encodable {
        let key: CalibrationAnalysisKey
        let coverage: CalibrationCoverage
        let summaries: [Summary]
    }
    private struct Reference: Decodable {
        struct Bounds: Decodable { let lower, upper: Double }
        struct Row: Decodable {
            let id, session: Int
            let role: CalibrationSplitRole
            let groupSHA256: String
            let label: CalibrationListeningPreference
            let cpps, pitch, level: Double
        }
        struct Scenario: Decodable {
            let name, direction: String
            let rows: [Row]
            let activated: Bool
            let preferredInterval, observedCPPS: Bounds
        }
        let schemaVersion: Int
        let syntheticOnly: Bool
        let cases: [Scenario]
    }
    private struct Manifest: Encodable {
        let schemaVersion: Int
        let generator: String
        let containsHumanVoice: Bool
        let sourceReferenceSHA256, name: String
        let byteCount: Int
        let sha256, profileSHA256, datasetSHA256, splitSHA256, targetSHA256: String
        let sessionCount, takeCount, analysisCount, fittingCount, recordingEvaluationCount,
            sessionEvaluationCount: Int
        let targetCount, selectedSamplesPerTake: Int
    }
}
