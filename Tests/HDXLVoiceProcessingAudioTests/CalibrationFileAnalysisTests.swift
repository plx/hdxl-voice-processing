import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingAudio

private func calibrationAudioID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

/// Independent integer PCM16 RIFF construction: decoded samples are integer/32768.
private func calibrationAudioWAV(_ samples: [Int16], rate: Int = 16000) -> Data {
    var data = Data()
    func tag(_ value: String) { data.append(contentsOf: value.utf8) }
    func integer<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    tag("RIFF")
    integer(UInt32(36 + samples.count * 2))
    tag("WAVEfmt ")
    integer(UInt32(16))
    integer(UInt16(1))
    integer(UInt16(1))
    integer(UInt32(rate))
    integer(UInt32(rate * 2))
    integer(UInt16(2))
    integer(UInt16(16))
    tag("data")
    integer(UInt32(samples.count * 2))
    for sample in samples { integer(sample) }
    return data
}

private func calibrationAudioProfile(
    precision: AnalysisPrecision = .float64, complete: Bool = false,
    reference: Bool = false, hop: Int = 160, rate: Int = 16000
) throws -> AnalysisScheduleProfile {
    try AnalysisScheduleProfile(
        inputFormat: PCMFormat(
            sampleRate: Double(rate), channelCount: 1,
            encoding: precision == .float64 ? .float64 : .float32),
        channels: PCMChannelSelection(channelIndex: 0),
        levels: LevelConfiguration(
            sampleRate: rate, inputPrecision: precision, windowLength: 160, hopLength: hop,
            accumulation: .compensatedSliding, weighting: .none),
        pitch: complete
            ? YINProfile(
                estimator: YINConfiguration(
                    sampleRate: rate, inputPrecision: precision, pitchFloorHz: 50,
                    pitchCeilingHz: 700, hopLength: hop)) : nil,
        cpps: complete
            ? CPPSProfile(
                cepstrogram: CepstrogramConfiguration(
                    sourceSampleRate: rate, inputPrecision: precision, hopSeconds: 0.01,
                    declaredInputBandwidthHz: Double(rate) / 2,
                    conditioningMethod: reference
                        ? .praat7WholeInterval(interpolationDepth: 50)
                        : .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
                settings: CPPSConfiguration(
                    timeWindowSeconds: 0.02,
                    prominence: CPPConfiguration(fitMethod: .leastSquares))) : nil)
}

private final class CalibrationAudioFixture {
    let root: URL
    let scratch: URL
    let url: URL
    let samples: [Int16]
    let bytes: Data
    let take: CalibrationTake

    init(
        id: Int = 1, samples: [Int16] = Array(repeating: 8192, count: 6400),
        profile: AnalysisScheduleProfile? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "calibration-test-\(UUID())")
        scratch = root.appendingPathComponent("scratch", isDirectory: true)
        url = root.appendingPathComponent("private-sensitive-speaker.wav")
        self.samples = samples
        bytes = calibrationAudioWAV(samples)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try bytes.write(to: url)
        let profile = try profile ?? calibrationAudioProfile()
        take = try CalibrationTake(
            id: calibrationAudioID(id),
            media: CalibrationMediaReference(
                referenceIdentifier: "media-\(id)", originalRecordingID: calibrationAudioID(id),
                content: CalibrationDigest(bytes: bytes), byteCount: Int64(bytes.count)),
            task: CalibrationTask(category: .sustainedVowel, promptIdentifier: "test-prompt"),
            repetition: 1, instruction: .preferred,
            label: CalibrationListeningLabel(preference: .usual, exposure: .blindedBeforeFeatures),
            source: SourceInterval(
                epoch: StreamEpoch(streamID: calibrationAudioID(id)), startSample: 0,
                sampleCount: Int64(samples.count), sampleRate: profile.inputFormat.sampleRate),
            conditions: CalibrationRecordingConditions(
                routeIdentifier: "generated-pcm", roomIdentifier: "synthetic",
                microphoneDistanceMeters: 1, inputGainDB: 0, recordingSettings: [:]),
            profile: profile)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func run(
        take: CalibrationTake? = nil, limits: CalibrationFileLimits? = nil,
        cached: CalibrationAnalysisRecord? = nil,
        control: (CalibrationFileCheckpoint) -> Bool = { _ in true },
        emit: (ScheduledFrame) -> Void = { _ in }
    ) throws -> CalibrationFileAnalysisResult {
        try CalibrationFileAnalysis.run(
            take: take ?? self.take, mediaURL: url, scratchDirectory: scratch,
            limits: limits ?? CalibrationFileLimits(), cached: cached,
            shouldContinue: control, emit: emit)
    }

    func checkClean() throws {
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    func changed(
        bytes: Data? = nil, profile: AnalysisScheduleProfile? = nil,
        source: SourceInterval? = nil, exclusions: [CalibrationExclusion] = []
    ) throws -> CalibrationTake {
        try CalibrationTake(
            id: take.id,
            media: bytes.map {
                try CalibrationMediaReference(
                    referenceIdentifier: take.media.referenceIdentifier,
                    originalRecordingID: take.media.originalRecordingID,
                    content: CalibrationDigest(bytes: $0), byteCount: Int64($0.count))
            } ?? take.media,
            task: take.task, repetition: take.repetition, instruction: take.instruction,
            label: take.label, source: source ?? take.source, exclusions: exclusions,
            conditions: take.conditions, profile: profile ?? take.profile)
    }
}

@Test func calibrationFileMeasuresRawLevelsAndReusesOnlyVerifiedCache() throws {
    let f = try CalibrationAudioFixture()
    var frames = 0
    let result = try f.run(
        limits: CalibrationFileLimits(decodedChunkCapacity: 113), emit: { _ in frames += 1 })
    #expect(!result.reusedCache)
    #expect(frames == 40)
    let rms = try #require(result.record.summary(.rms))
    let level = try #require(result.record.summary(.levelDBFS))
    #expect(rms.availableCount == 40 && rms.unavailable.isEmpty)
    #expect(rms.minimum == 0.25 && rms.median == 0.25 && rms.maximum == 0.25)
    #expect(abs(try #require(level.median) - 20 * log10(0.25)) < 1e-12)
    #expect(level.unit == .decibelsFullScale && rms.unit == .normalizedAmplitude)
    #expect(result.record.coverage.source == 6400 && result.record.coverage.selected == 6400)
    #expect(result.execution.snapshotBytes == f.bytes.count)
    #expect(result.execution.maximumSnapshotChunkBytes <= 65536)
    #expect(result.execution.maximumDecodedChunkSamples == 113)
    #expect(result.execution.decodedSamples == 6400 && result.execution.retainedScalarCount == 80)
    #expect(result.execution.reservedScalarBytes == 2 * 30000 * 8)
    try f.checkClean()
    let bytes = try result.record.canonicalJSON()
    #expect(!String(decoding: bytes, as: UTF8.self).contains("private-sensitive-speaker"))
    let cached = try CalibrationAnalysisRecord.decode(bytes, for: f.take)
    let reuse = try f.run(
        cached: cached, emit: { _ in Issue.record("Cache reuse emitted a decoded frame") })
    #expect(reuse.reusedCache && reuse.record == result.record)
    #expect(reuse.execution.snapshotBytes == f.bytes.count)
    #expect(reuse.execution.decodedSamples == 0 && reuse.execution.maximumPreparedBufferBytes == 0)
    let relabeled = try f.take.replacingLabel(
        CalibrationListeningLabel(preference: .preferred, exposure: .afterFeatures))
    #expect(try f.run(take: relabeled, cached: cached).reusedCache)
    let changed = try f.changed(profile: calibrationAudioProfile(hop: 80))
    #expect(try !f.run(take: changed, cached: cached).reusedCache)
    try f.checkClean()
}

@Test func calibrationFileMissingReplacedCorruptAndIncompatibleMediaRemainExplicit() throws {
    let f = try CalibrationAudioFixture()
    let cached = try f.run().record
    var different = f.bytes
    different[different.count - 1] ^= 1
    try different.write(to: f.url)
    #expect(throws: CalibrationFileFailure.audioDigestMismatch) { try f.run(cached: cached) }
    try f.checkClean()
    different.append(0)
    try different.write(to: f.url)
    #expect(throws: CalibrationFileFailure.audioLengthMismatch) { try f.run(cached: cached) }
    try f.checkClean()
    let corrupt = Data("This is not audio".utf8)
    try corrupt.write(to: f.url)
    #expect(throws: CalibrationFileFailure.invalidMedia) {
        try f.run(take: f.changed(bytes: corrupt))
    }
    try f.checkClean()
    try f.bytes.write(to: f.url)
    let otherProfile = try calibrationAudioProfile(rate: 48000)
    let otherSource = try SourceInterval(
        epoch: f.take.source.epoch, startSample: 0, sampleCount: 6400, sampleRate: 48000)
    #expect(throws: CalibrationFileFailure.incompatibleFormat) {
        try f.run(take: f.changed(profile: otherProfile, source: otherSource))
    }
    let longSource = try SourceInterval(
        epoch: f.take.source.epoch, startSample: 0, sampleCount: 6401, sampleRate: 16000)
    #expect(throws: CalibrationFileFailure.invalidRange) {
        try f.run(take: f.changed(source: longSource))
    }
    try FileManager.default.removeItem(at: f.url)
    #expect(throws: CalibrationFileFailure.missingMedia) { try f.run(cached: cached) }
    try f.checkClean()
}

@Test func calibrationFileDecodesVerifiedSnapshotWhenOriginalChangesAfterCopy() throws {
    let f = try CalibrationAudioFixture()
    var replaced = false
    let result = try f.run(control: { checkpoint in
        if checkpoint.stage == .preparation && !replaced {
            replaced = true
            do {
                try calibrationAudioWAV(Array(repeating: 16384, count: 6400)).write(
                    to: f.url, options: .atomic)
            } catch { Issue.record(error) }
        }
        return true
    })
    #expect(replaced)
    #expect(result.record.summary(.rms)?.median == 0.25)
    #expect(result.record.key.audio == f.take.media.content)
    #expect(throws: CalibrationFileFailure.audioDigestMismatch) { try f.run(cached: result.record) }
    try f.checkClean()
}

@Test func calibrationFileRejectsPartialSnapshotMutationAndCleansCancellationAndCapacityFailures()
    throws
{
    let f = try CalibrationAudioFixture(samples: Array(repeating: 8192, count: 80000))
    var changed = false
    #expect(throws: CalibrationFileFailure.audioDigestMismatch) {
        try f.run(control: { checkpoint in
            if checkpoint.stage == .snapshot && checkpoint.copiedBytes >= 65536 && !changed {
                changed = true
                do {
                    let handle = try FileHandle(forWritingTo: f.url)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(f.bytes.count - 1))
                    try handle.write(contentsOf: Data([0]))
                } catch { Issue.record(error) }
            }
            return true
        })
    }
    #expect(changed)
    try f.checkClean()
    try f.bytes.write(to: f.url)
    for stage in [CalibrationFileStage.snapshot, .preparation, .analysis, .summary] {
        #expect(throws: CalibrationFileFailure.cancelled) {
            try f.run(control: { $0.stage != stage })
        }
        try f.checkClean()
    }
    #expect(throws: CalibrationFileFailure.mediaTooLarge) {
        try f.run(limits: CalibrationFileLimits(maximumMediaBytes: 100))
    }
    #expect(throws: CalibrationFileFailure.analysisCapacityExceeded) {
        try f.run(limits: CalibrationFileLimits(maximumSourceSamples: 100))
    }
    #expect(throws: CalibrationFileFailure.analysisCapacityExceeded) {
        try f.run(limits: CalibrationFileLimits(maximumObservationsPerMetric: 2))
    }
    try f.checkClean()
}

@Test func calibrationFileExclusionsPreserveUniqueCoverageAndDoNotImputeMissingAudio() throws {
    let f = try CalibrationAudioFixture()
    func region(_ start: Int64, _ count: Int64) throws -> SourceInterval {
        try SourceInterval(
            epoch: f.take.source.epoch, startSample: start, sampleCount: count, sampleRate: 16000)
    }
    let take = try f.changed(exclusions: [
        CalibrationExclusion(source: region(1600, 800), kind: .missingAcquisition, reason: "lost"),
        CalibrationExclusion(
            source: region(3200, 1600), kind: .userSelection, reason: "not selected"),
    ])
    let result = try f.run(take: take, limits: CalibrationFileLimits(decodedChunkCapacity: 257))
    #expect(result.record.coverage.source == 6400)
    #expect(result.record.coverage.missing == 800)
    #expect(result.record.coverage.excludedEligible == 1600)
    #expect(result.record.coverage.selected == 4000)
    #expect(result.record.summary(.rms)?.availableCount == 25)
    #expect(result.record.summary(.rms)?.median == 0.25)
    #expect(result.execution.decodedSamples == 5600)
    #expect(result.execution.maximumDecodedChunkSamples <= 257)
    let plain = try f.run(cached: result.record)
    #expect(!plain.reusedCache && plain.record.coverage.selected == 6400)
    let empty = try f.changed(source: region(0, 0))
    let emptyResult = try f.run(take: empty)
    #expect(emptyResult.record.coverage.source == 0)
    #expect(
        emptyResult.record.summaries.allSatisfy { $0.observationCount == 0 && $0.median == nil })
    try f.checkClean()
}

@Test func calibrationFileSnapshotIsPrivateAndRejectsNonregularMedia() throws {
    let f = try CalibrationAudioFixture()
    var inspected = false
    #expect(throws: CalibrationFileFailure.cancelled) {
        try f.run(control: { checkpoint in
            guard checkpoint.stage == .preparation else { return true }
            do {
                let directories = try FileManager.default.contentsOfDirectory(
                    at: f.scratch, includingPropertiesForKeys: nil)
                #expect(directories.count == 1)
                let directory = try #require(directories.first)
                let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)
                #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
                let files = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)
                #expect(files.count == 1)
                let file = try #require(files.first)
                #expect(file.lastPathComponent == "media.audio")
                let filePermissions = try FileManager.default.attributesOfItem(atPath: file.path)
                #expect((filePermissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                inspected = true
            } catch { Issue.record(error) }
            return false
        })
    }
    #expect(inspected)
    try f.checkClean()
    #expect(throws: CalibrationFileFailure.notRegularFile) {
        try CalibrationFileAnalysis.run(
            take: f.take, mediaURL: f.root, scratchDirectory: f.scratch,
            limits: CalibrationFileLimits())
    }
    let link = f.root.appendingPathComponent("linked.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.url)
    #expect(throws: CalibrationFileFailure.unreadableMedia) {
        try CalibrationFileAnalysis.run(
            take: f.take, mediaURL: link, scratchDirectory: f.scratch,
            limits: CalibrationFileLimits())
    }
    try f.checkClean()
}

@Test func calibrationFileFullProfilesMatchIndependentFrameReductionAcrossPrecisionsAndPartitions()
    throws
{
    let samples: [Int16] = (0..<6401).map { index in
        Int16(8000 * sin(2 * .pi * 160 * Double(index) / 16000))
    }
    for precision in [AnalysisPrecision.float32, .float64] {
        for reference in [false, true] {
            let f = try CalibrationAudioFixture(
                samples: samples,
                profile: calibrationAudioProfile(
                    precision: precision, complete: true, reference: reference))
            var independentlyReduced: [ScheduledMetric: [Double]] = [:]
            let first = try f.run(
                limits: CalibrationFileLimits(decodedChunkCapacity: 97),
                emit: {
                    frame in
                    let metrics: [ScheduledMetric]
                    switch frame.algorithm {
                    case .levels: metrics = [.rms, .levelDBFS]
                    case .yin: metrics = [.fundamentalFrequency]
                    case .cpps: metrics = [.cpp, .cpps]
                    }
                    for metric in metrics {
                        do {
                            if let value = try frame.measurementResult(metric).outcome.estimate?
                                .value
                            {
                                independentlyReduced[metric, default: []].append(value)
                            }
                        } catch { Issue.record(error) }
                    }
                })
            let second = try f.run(limits: CalibrationFileLimits(decodedChunkCapacity: 512))
            #expect(first.record == second.record)
            #expect(first.record.summaries.count == 5)
            for summary in first.record.summaries {
                let ordered = (independentlyReduced[summary.metric] ?? []).sorted()
                #expect(summary.availableCount == ordered.count)
                let expectedMedian: Double? =
                    ordered.isEmpty ? nil : ordered[(ordered.count - 1) / 2]
                #expect(summary.median == expectedMedian)
                #expect(summary.minimum == ordered.first && summary.maximum == ordered.last)
            }
            #expect(
                abs(try #require(first.record.summary(.fundamentalFrequency)?.median) - 160) < 1)
            #expect(first.record.summary(.cpps)?.availableCount ?? 0 > 0)
            try f.checkClean()
        }
    }
}

@Test func calibrationFileBatchIsolatesFailuresAndHonorsInputAndBatchCancellation() throws {
    let first = try CalibrationAudioFixture(id: 1)
    let missing = try CalibrationAudioFixture(id: 2)
    let last = try CalibrationAudioFixture(id: 3)
    let excluded = try CalibrationAudioFixture(id: 4)
    let dataset = try CalibrationDataset(
        id: calibrationAudioID(99), revision: 1,
        sessions: [
            CalibrationSession(
                id: calibrationAudioID(100),
                takes: [
                    last.take, missing.take, first.take,
                    excluded.take.replacingLabel(nil, exclusionReason: "No usable recording"),
                ])
        ])
    let cached = try first.run().record
    var outcomes: [UUID: CalibrationFileInputResult] = [:]
    let report = try CalibrationFileAnalysisBatch.run(
        dataset: dataset, scratchDirectory: first.scratch, limits: CalibrationFileLimits(),
        resolveMedia: { reference in
            if reference == first.take.media { return first.url }
            if reference == last.take.media { return last.url }
            if reference == excluded.take.media { Issue.record("Excluded media was resolved") }
            return nil
        }, cached: { $0.id == first.take.id ? cached : nil },
        inputCompleted: { outcomes[$0] = $1 })
    #expect(
        report.analyzed == 1 && report.reused == 1 && report.failed == 1 && report.excluded == 1)
    #expect(outcomes[missing.take.id] == .failed(.missingMedia))
    #expect(outcomes[excluded.take.id] == .excluded)
    let cancelOne = try CalibrationFileAnalysisBatch.run(
        dataset: dataset, scratchDirectory: first.scratch, limits: CalibrationFileLimits(),
        resolveMedia: { _ in last.url },
        control: { $0.takeID == first.take.id ? .cancelInput : .proceed },
        inputCompleted: { _, _ in })
    #expect(cancelOne.cancelled == 1 && cancelOne.analyzed == 2 && cancelOne.excluded == 1)
    var resolved = 0
    let cancelAll = try CalibrationFileAnalysisBatch.run(
        dataset: dataset, scratchDirectory: first.scratch, limits: CalibrationFileLimits(),
        resolveMedia: { _ in
            resolved += 1
            return last.url
        }, control: { _ in .cancelBatch },
        inputCompleted: { _, result in #expect(result == .cancelled) })
    #expect(cancelAll.cancelled == 4 && resolved == 0)
    try first.checkClean()
}
