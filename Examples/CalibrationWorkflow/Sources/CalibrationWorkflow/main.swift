import Darwin
import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

enum ExampleError: Error { case invalidInput, verificationFailed }

func require(_ condition: Bool) throws {
    guard condition else { throw ExampleError.verificationFailed }
}

struct Fixture: Decodable {
    let id: UUID
    let mediaID: String
    let recordingID: UUID
    let sessionID: UUID
    let task: CalibrationTaskCategory
    let promptID: String
    let repetition: Int
    let instruction: CalibrationProductionInstruction
    let listeningLabel: CalibrationListeningPreference
    let confidence: Double
    let filename: String
    let sha256: String
    let byteCount: Int64
    let sampleCount: Int64
    let sampleRate: Double
    let routeID: String
    let roomID: String
    let selectedStartSample: Int64
    let sourceStartSample: Int64
    let notes: String
}

struct Manifest: Decodable {
    let schemaVersion: Int
    let datasetID: UUID
    let evaluationSessionID: UUID
    let splitSeed: UInt64
    let recordingEvaluationFraction: Double
    let containsHumanVoice: Bool
    let takes: [Fixture]
}

struct ClipComparison: Encodable {
    let takeID: UUID
    let sessionID: UUID
    let task: CalibrationTask
    let productionInstruction: CalibrationProductionInstruction
    let listeningLabel: CalibrationListeningLabel
    let role: CalibrationSplitRole
    let coverage: CalibrationCoverage
    let rawSummaries: [CalibrationMetricSummary]
    let findings: [String]
}

struct PassEvidence: Encodable {
    let seconds: Double
    let analyzed: Int
    let reused: Int
    let decodedSamples: Int64
    let snapshotBytes: Int64
    let maximumSnapshotChunkBytes: Int
    let maximumDecodedChunkSamples: Int
    let maximumPreparedBufferBytes: Int
    let maximumReservedScalarBytes: Int
    let maximumRetainedScalarCount: Int
    let peakResidentBytes: Int64
}

struct Counters {
    var snapshotBytes: Int64 = 0
    var decodedSamples: Int64 = 0
    var maximumSnapshotChunkBytes = 0
    var maximumDecodedChunkSamples = 0
    var maximumPreparedBufferBytes = 0
    var reservedScalarBytes = 0
    var retainedScalarCount = 0
}

struct ImportEvidence: Encodable {
    let sessions: Int
    let takes: Int
    let encodedBytes: Int
    let identity: CalibrationDigest
    let trialsSeconds: [Double]
    let peakResidentBytes: Int64
}

struct Report: Encodable {
    let schemaVersion = 1
    let status = "passed"
    let syntheticOnly = true
    let humanListeningPerformed = false
    let labelingCompletedBeforeAnalysis = true
    let fittedTargetProduced = false
    let physicalDeviceEvidence = false
    let manifestSHA256: CalibrationDigest
    let datasetIdentity: CalibrationDigest
    let profileIdentity: ProfileIdentity
    let replayTakeIDs: [UUID]
    let fittingTakeIDs: [UUID]
    let recordingEvaluationTakeIDs: [UUID]
    let sessionEvaluationTakeIDs: [UUID]
    let withinSessionComparisons: [ClipComparison]
    let separateSessionEvaluation: [ClipComparison]
    let maximumDatasetImport: ImportEvidence
    let analysisPasses: [PassEvidence]
    let cachePass: PassEvidence
}

func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url)
}

func peakResidentBytes() throws -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
        throw ExampleError.verificationFailed
    }
    // Darwin reports bytes; this executable is explicitly macOS-only.
    return Int64(usage.ru_maxrss)
}

func seconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

func profile() throws -> AnalysisScheduleProfile {
    try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: PCMChannelSelection(channelIndex: 0),
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
            accumulation: .compensatedSliding, weighting: .none),
        pitch: YINProfile(
            estimator: YINConfiguration(
                sampleRate: 16000, inputPrecision: .float64,
                pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 160)),
        cpps: CPPSProfile(
            cepstrogram: CepstrogramConfiguration(
                sourceSampleRate: 16000, hopSeconds: 0.01, declaredInputBandwidthHz: 8000,
                conditioningMethod: .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
            settings: CPPSConfiguration(
                timeWindowSeconds: 0.02, prominence: CPPConfiguration(fitMethod: .leastSquares))))
}

func dataset(_ manifest: Manifest, profile: AnalysisScheduleProfile) throws -> CalibrationDataset {
    var sessions: [UUID: [CalibrationTake]] = [:]
    for fixture in manifest.takes {
        let source = try SourceInterval(
            epoch: StreamEpoch(streamID: fixture.recordingID),
            startSample: fixture.sourceStartSample,
            sampleCount: fixture.sampleCount, sampleRate: fixture.sampleRate)
        let exclusions: [CalibrationExclusion] =
            try fixture.selectedStartSample == source.startSample
            ? []
            : [
                CalibrationExclusion(
                    source: SourceInterval(
                        epoch: source.epoch, startSample: source.startSample,
                        sampleCount: fixture.selectedStartSample - source.startSample,
                        sampleRate: source.sampleRate),
                    kind: .userSelection, reason: "Synthetic demonstration of excluded lead-in")
            ]
        let take = try CalibrationTake(
            id: fixture.id,
            media: CalibrationMediaReference(
                referenceIdentifier: fixture.mediaID, originalRecordingID: fixture.recordingID,
                content: CalibrationDigest(sha256: fixture.sha256), byteCount: fixture.byteCount),
            task: CalibrationTask(
                category: fixture.task, promptIdentifier: fixture.promptID,
                prompt: "Synthetic metadata example; no spoken language is represented."),
            repetition: fixture.repetition, instruction: fixture.instruction,
            instructionNotes: fixture.notes, source: source, exclusions: exclusions,
            conditions: CalibrationRecordingConditions(
                routeIdentifier: fixture.routeID, roomIdentifier: fixture.roomID,
                inputGainDB: 0,
                recordingSettings: ["synthetic": .boolean(true), "normalization": .boolean(false)],
                notes:
                    "No physical microphone, distance, room acoustics, or vocal-effort observation."
            ),
            profile: profile)
        sessions[fixture.sessionID, default: []].append(take)
    }
    return try CalibrationDataset(
        id: manifest.datasetID, revision: 1,
        notes: "Scripted synthetic workflow, not a personal fitted target.",
        sessions: sessions.map { try CalibrationSession(id: $0.key, takes: $0.value) })
}

func maximumImportEvidence(_ dataset: CalibrationDataset) throws -> ImportEvidence {
    let templates = dataset.sessions.flatMap(\.takes)
    func identity(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!
    }
    // Capacity stress only: these are aliases of 16 recordings, not 512 independent
    // observations. No statistical split/fitting is attempted on this stress value.
    let sessions = try (0..<32).map { sessionIndex in
        try CalibrationSession(
            id: identity(sessionIndex + 10000),
            takes: templates.enumerated().map { index, take in
                try CalibrationTake(
                    id: identity(sessionIndex * templates.count + index), media: take.media,
                    task: take.task, repetition: take.repetition, instruction: take.instruction,
                    label: take.label, source: take.source, exclusions: take.exclusions,
                    conditions: take.conditions, profile: take.profile, mask: take.mask)
            })
    }
    let stress = try CalibrationDataset(
        id: identity(20000), revision: 1,
        notes: "Alias-only import capacity stress; no independent-observation claim.",
        sessions: sessions)
    let bytes = try stress.canonicalJSON()
    let identity = try stress.identity()
    var trials: [Double] = []
    for _ in 0..<10 {
        let start = DispatchTime.now().uptimeNanoseconds
        let decoded = try CalibrationDataset.decode(bytes)
        try require(decoded == stress)
        trials.append(seconds(since: start))
    }
    return try ImportEvidence(
        sessions: stress.sessions.count, takes: stress.takeCount,
        encodedBytes: bytes.count, identity: identity, trialsSeconds: trials,
        peakResidentBytes: peakResidentBytes())
}

func main() throws {
    guard (3...4).contains(CommandLine.arguments.count) else { throw ExampleError.invalidInput }
    let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let passCount = CommandLine.arguments.count == 4 ? Int(CommandLine.arguments[3]) : 1
    guard let passCount, (1...8).contains(passCount),
        !FileManager.default.fileExists(atPath: output.path)
    else {
        throw ExampleError.invalidInput
    }
    let manifestBytes = try Data(contentsOf: input.appendingPathComponent("manifest.json"))
    guard manifestBytes.count <= 128 * 1024 else { throw ExampleError.invalidInput }
    let manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
    try require(
        manifest.schemaVersion == 1 && !manifest.containsHumanVoice && manifest.takes.count == 16)
    for (index, fixture) in manifest.takes.enumerated() {
        try require(fixture.filename == String(format: "take-%02d.wav", index + 1))
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let scratch = output.appendingPathComponent("scratch", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let profile = try profile()
    let unlabeled = try dataset(manifest, profile: profile)
    let fixtureByMedia = Dictionary(uniqueKeysWithValues: manifest.takes.map { ($0.mediaID, $0) })

    // Presenter sees only these opaque tokens/ordinals. In a real host the separate
    // controller plays the media; this offline example submits scripted labels.
    let labeling = try CalibrationLabelingSession(dataset: unlabeled, shuffleSeed: 47)
    try write(labeling.items, to: output.appendingPathComponent("replay-presenter.json"))
    var replayTakeIDs: [UUID] = []
    for item in labeling.items {
        let media = try labeling.replayMedia(for: item.token)
        guard let fixture = fixtureByMedia[media.media.referenceIdentifier] else {
            throw ExampleError.invalidInput
        }
        replayTakeIDs.append(fixture.id)
        try labeling.submit(
            item.token, preference: fixture.listeningLabel, confidence: fixture.confidence,
            notes: fixture.notes)
    }
    let labeled = try labeling.complete()
    try require(labeling.isComplete)
    let datasetBytes = try labeled.canonicalJSON()
    try datasetBytes.write(to: output.appendingPathComponent("dataset.json"))
    try require(try CalibrationDataset.decode(datasetBytes) == labeled)
    let split = try CalibrationSplitPlan(
        dataset: labeled, sessionEvaluationIDs: [manifest.evaluationSessionID],
        recordingEvaluationFraction: manifest.recordingEvaluationFraction, seed: manifest.splitSeed)
    let partition = try split.partition(dataset: labeled)
    try require(
        !partition.fitting.isEmpty && !partition.recordingEvaluation.isEmpty
            && partition.sessionEvaluation.count == 4)
    try write(split, to: output.appendingPathComponent("split.json"))
    let imported = try maximumImportEvidence(labeled)

    var analyses: [UUID: CalibrationAnalysisRecord] = [:]
    func runPass(reuse: Bool) throws -> PassEvidence {
        var counts = Counters()
        var problem = false
        let start = DispatchTime.now().uptimeNanoseconds
        let report = try CalibrationFileAnalysisBatch.run(
            dataset: labeled, scratchDirectory: scratch,
            limits: CalibrationFileLimits(decodedChunkCapacity: 257),
            resolveMedia: { reference in
                fixtureByMedia[reference.referenceIdentifier].map {
                    input.appendingPathComponent($0.filename)
                }
            }, cached: { reuse ? analyses[$0.id] : nil },
            inputCompleted: { id, result in
                guard case .completed(let result) = result else {
                    problem = true
                    return
                }
                analyses[id] = result.record
                let e = result.execution
                counts.snapshotBytes += e.snapshotBytes
                counts.decodedSamples += e.decodedSamples
                counts.maximumSnapshotChunkBytes = max(
                    counts.maximumSnapshotChunkBytes, e.maximumSnapshotChunkBytes)
                counts.maximumDecodedChunkSamples = max(
                    counts.maximumDecodedChunkSamples, e.maximumDecodedChunkSamples)
                counts.maximumPreparedBufferBytes = max(
                    counts.maximumPreparedBufferBytes, e.maximumPreparedBufferBytes)
                counts.reservedScalarBytes = max(counts.reservedScalarBytes, e.reservedScalarBytes)
                counts.retainedScalarCount = max(counts.retainedScalarCount, e.retainedScalarCount)
            })
        let elapsed = seconds(since: start)
        try require(!problem && report.failed == 0 && report.cancelled == 0)
        try require(reuse ? report.reused == 16 : report.analyzed == 16)
        try require(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        return try PassEvidence(
            seconds: elapsed, analyzed: report.analyzed, reused: report.reused,
            decodedSamples: counts.decodedSamples, snapshotBytes: counts.snapshotBytes,
            maximumSnapshotChunkBytes: counts.maximumSnapshotChunkBytes,
            maximumDecodedChunkSamples: counts.maximumDecodedChunkSamples,
            maximumPreparedBufferBytes: counts.maximumPreparedBufferBytes,
            maximumReservedScalarBytes: counts.reservedScalarBytes,
            maximumRetainedScalarCount: counts.retainedScalarCount,
            peakResidentBytes: peakResidentBytes())
    }
    let passes = try (0..<passCount).map { _ in try runPass(reuse: false) }
    let cache = try runPass(reuse: true)
    var comparisons: [ClipComparison] = []
    for assigned in partition.fitting + partition.recordingEvaluation + partition.sessionEvaluation
    {
        let take = assigned.take
        guard let record = analyses[take.id], let label = take.label else {
            throw ExampleError.verificationFailed
        }
        let reference = labeled.sessions.flatMap(\.takes).first { $0.task == take.task }
        let assessment = try CalibrationTakeAssessment(
            take: take, reference: reference, analysis: record,
            policy: CalibrationAssessmentPolicy())
        comparisons.append(
            ClipComparison(
                takeID: take.id, sessionID: assigned.sessionID, task: take.task,
                productionInstruction: take.instruction, listeningLabel: label, role: assigned.role,
                coverage: record.coverage, rawSummaries: record.summaries,
                findings: assessment.findings.map { String(describing: $0) }))
        try record.canonicalJSON().write(
            to: output.appendingPathComponent("analysis-\(take.media.referenceIdentifier).json"))
    }
    comparisons.sort { $0.takeID.uuidString < $1.takeID.uuidString }
    let report = try Report(
        manifestSHA256: CalibrationDigest(bytes: manifestBytes),
        datasetIdentity: labeled.identity(),
        profileIdentity: profile.identity(), replayTakeIDs: replayTakeIDs,
        fittingTakeIDs: partition.fitting.map { $0.take.id },
        recordingEvaluationTakeIDs: partition.recordingEvaluation.map { $0.take.id },
        sessionEvaluationTakeIDs: partition.sessionEvaluation.map { $0.take.id },
        withinSessionComparisons: comparisons.filter {
            $0.sessionID != manifest.evaluationSessionID
        },
        separateSessionEvaluation: comparisons.filter {
            $0.sessionID == manifest.evaluationSessionID
        },
        maximumDatasetImport: imported, analysisPasses: passes, cachePass: cache)
    try write(report, to: output.appendingPathComponent("report.json"))
    print(
        "Verified 16 synthetic takes, blinded-workflow metadata, independent holdouts and matching cache reuse."
    )
}

do { try main() } catch {
    // Do not print paths or arbitrary decoder errors.
    FileHandle.standardError.write(
        Data(
            "Calibration example failed; inspect the supplied synthetic inputs and arguments.\n"
                .utf8))
    exit(1)
}
