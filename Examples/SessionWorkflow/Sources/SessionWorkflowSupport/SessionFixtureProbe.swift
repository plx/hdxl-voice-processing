import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

/// A public-API, synthetic-only probe compiled into the macOS example and the
/// iOS host's test bundle. No microphone/session activation or private inputs.
public enum SessionFixtureProbe {
    public struct Result: Sendable, Hashable, Codable {
        public let schemaVersion: Int
        public let status: String
        public let checks: [String]
        public let fixtures: Int
        public let completeRoundTrips: Int
        public let scalarMeasurements: Int
        public let replayedMeasurements: Int
        public let calibrationTakes: Int
        public let calibrationTargets: Int
        public let evidence: String
    }

    public static let checks = [
        "fixture-hashes-and-lengths", "complete-byte-roundtrips",
        "scalar-status-clocks-intermediates-gap", "sealed-partial-session",
        "strict-truncation-refused", "explicit-prefix-inspection",
        "original-pcm-pinned-profile-replay", "audio-free-replay-refused",
        "private-copy-cleanup", "calibration-labels-splits-masks-analysis",
        "target-rule-compatibility-inspection", "unsupported-fitter-display-only",
    ]

    public static func run(fixtures: URL, scratch: URL) throws -> Result {
        let names = [
            "scalars-v1.hvps", "partial-v1.hvps", "interrupted-v1.hvps",
            "embedded-pcm-v1.hvps", "omitted-pcm-v1.hvps",
        ]
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: fixtures.appendingPathComponent("manifest.json")))
        try require(manifest.schemaVersion == 1 && !manifest.containsHumanVoice)
        try require(manifest.sourceStartSample == (1 << 54) + 29)
        try require(Set(manifest.files.map(\.name)) == Set(names) && manifest.files.count == 5)
        let limits = try SessionArchiveLimits()
        var scalarCount = 0
        for name in names {
            let pin = manifest.files.first { $0.name == name }!
            try require((1...1024 * 1024).contains(pin.byteCount))
            let bytes = try Data(contentsOf: fixtures.appendingPathComponent(name))
            try require(
                bytes.count == pin.byteCount && CalibrationDigest(bytes: bytes).sha256 == pin.sha256
            )
            if name == "interrupted-v1.hvps" {
                do {
                    let strict = try reader(bytes)
                    while try strict.next() != nil {}
                    throw Failure.failedCheck
                } catch SessionArchiveError.truncated {}
                let recovered = try reader(bytes, recovery: .inspectCompletePrefix)
                var count = 0
                while let event = try recovered.next() {
                    if case .measurement = event { count += 1 }
                }
                try require(recovered.isIncomplete && recovered.seal == nil && count == 15)
                continue
            }
            let imported = try reader(bytes)
            var reencoded = Data()
            let writer = try SessionArchiveWriter(header: imported.header, limits: limits) {
                reencoded.append($0)
            }
            var measurements: [SessionArchiveMeasurement] = []
            var gaps: [SessionArchiveGap] = []
            while let event = try imported.next() {
                try copy(event, to: writer)
                if case .measurement(_, let value) = event { measurements.append(value) }
                if case .gap(let value) = event { gaps.append(value) }
            }
            try require(reencoded == bytes)
            if name == "scalars-v1.hvps" || name == "partial-v1.hvps" {
                try require(measurements.count == 15 && gaps.count == 1)
                let first = measurements[0]
                try require(first.timestamp.sourceSample == manifest.sourceStartSample + 2)
                try require(first.result.timing.hostStartNanoseconds == UInt64.max - 100)
                try require(first.result.timing.completedHostNanoseconds == UInt64.max - 1)
                try require(first.result.intermediates.count == 1)
                try require(first.result.intermediates[0].values == [0, 0.125, -4, 1e20])
                let reasons: [UnavailabilityReason] = [
                    .insufficientData, .silence, .clipping,
                    .unsupportedRange, .inapplicableTask, .lowConfidence, .invalidInput,
                    .discontinuity,
                    .analysisFailure, .cancelled, .missingAcquisition, .excluded, .stale,
                ]
                try require(
                    measurements.dropFirst().prefix(13).map(\.result.outcome)
                        == reasons.map(MeasurementOutcome.unavailable))
                try require(
                    gaps[0].missingSource?.sampleCount == 5
                        && gaps[0].pendingSourceSamplesDiscarded == 2)
                try require(
                    measurements.last?.result.timing.source.startSample == manifest
                        .sourceStartSample + 229)
                try require(
                    imported.seal?.completion == (name == "partial-v1.hvps" ? .partial : .completed)
                )
                if name == "scalars-v1.hvps" { scalarCount = measurements.count }
            }
        }
        try inspectCalibration(fixtures)
        let directory = scratch.appendingPathComponent("synthetic-session-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var replayed = 0
        let replay = try SessionArchiveAudioReplay.run(
            at: fixtures.appendingPathComponent("embedded-pcm-v1.hvps"), planIndex: 0,
            scratchDirectory: directory, archiveLimits: limits,
            replayLimits: SessionArchiveReplayLimits(
                decodedChunkCapacity: 13, sourceTileCapacity: 128)
        ) { value in
            try require(value.result.outcome == .available(try ScalarEstimate(value: 0.25)))
            try require(
                value.result.timing.source.startSample == manifest.sourceStartSample
                    + Int64(8 * replayed))
            try require(
                value.result.timing.source.sampleCount == 8
                    && value.dependencyCoverage.selected == 8)
            try require(
                value.frameCenterSecondsFromOrigin == Double(8 * replayed) / 16000 + 0.00025)
            try require(value.workerBatchingUpperBoundSeconds == 0.008)
            replayed += 1
        }
        try require(replayed == 4 && replay.decodedSamples == 32)
        try require(replay.originalDecoder.runtime == "synthetic-fixture-origin")
        try require(replay.actualDecoder.runtime != "synthetic-fixture-origin")
        do {
            _ = try SessionArchiveAudioReplay.run(
                at: fixtures.appendingPathComponent("omitted-pcm-v1.hvps"), planIndex: 0,
                scratchDirectory: directory, archiveLimits: limits,
                replayLimits: SessionArchiveReplayLimits()
            ) { _ in throw Failure.failedCheck }
            throw Failure.failedCheck
        } catch SessionArchiveError.missingMedia {}
        try require(FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        return Result(
            schemaVersion: 1, status: "passed", checks: checks, fixtures: 6,
            completeRoundTrips: 5, scalarMeasurements: scalarCount, replayedMeasurements: replayed,
            calibrationTakes: 64, calibrationTargets: 2,
            evidence:
                "synthetic session fixtures and original PCM; no microphone, activation or personal data"
        )
    }

    private static func inspectCalibration(_ fixtures: URL) throws {
        let pin = try JSONDecoder().decode(
            CalibrationManifest.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("calibration-manifest.json")))
        try require(
            pin.schemaVersion == 1 && !pin.containsHumanVoice && pin.name == "calibration-v1.hvps")
        try require((1...1024 * 1024).contains(pin.byteCount))
        let bytes = try Data(contentsOf: fixtures.appendingPathComponent(pin.name))
        try require(
            bytes.count == pin.byteCount && CalibrationDigest(bytes: bytes).sha256 == pin.sha256)
        let imported = try reader(bytes)
        var reencoded = Data()
        let writer = try SessionArchiveWriter(
            header: imported.header, limits: SessionArchiveLimits()
        ) { reencoded.append($0) }
        var analyses = 0
        var targets = 0
        while let event = try imported.next() {
            try copy(event, to: writer)
            if case .calibrationAnalysis = event { analyses += 1 }
            if case .target = event { targets += 1 }
        }
        try require(bytes == reencoded && analyses == 64 && targets == 2)
        try require(imported.header.audioPolicy == .omit && imported.seal?.embeddedMediaBytes == 0)
        let dataset = try imported.calibrationDataset(at: 0)
        let split = try imported.calibrationSplit(at: 0).plan
        try require(dataset.sessions.count == 4 && dataset.takeCount == 64 && dataset.revision == 1)
        try require(dataset.identity().sha256 == pin.datasetSHA256)
        try require(CalibrationDigest(bytes: split.canonicalJSON()).sha256 == pin.splitSHA256)
        let partition = try split.partition(dataset: dataset)
        try require(
            partition.fitting.count == 14 && partition.recordingEvaluation.count == 18
                && partition.sessionEvaluation.count == 32)
        let takes = Dictionary(
            uniqueKeysWithValues: dataset.sessions.flatMap(\.takes).map { ($0.id, $0) })
        for index in 0..<64 {
            let analysis = try imported.calibrationAnalysis(at: UInt32(index))
            guard let take = takes[analysis.takeID] else { throw Failure.failedCheck }
            try analysis.record.validate(for: take)
            try require(
                take.label?.notes == "Scripted fixture label"
                    && take.label?.exposure == .blindedBeforeFeatures)
            try require(
                take.mask?.observations.count == 1
                    && take.exclusions.first?.source.sampleCount == 16)
            try require(
                analysis.record.coverage.source == 3200 && analysis.record.coverage.selected == 3184
            )
            try require(analysis.record.coverage.tags[MaskTag.speechDetected.rawValue] == 3200)
            try require(
                analysis.record.summaries.first(where: { $0.metric == .cpps })?.median
                    == (take.label?.preference == .preferred ? 10 : 4))
            try require(imported.mediaReferenceIndex(matching: take.media) == nil)
        }
        guard case .schedule(let profile) = try imported.profile(at: 0) else {
            throw Failure.failedCheck
        }
        try require(
            profile.identity().sha256
                == "c9fbb8420ee5ac5f76254129d42d10358dd393f868a5173ee7dea45e0ce9b01b")
        try require(profile.identity().sha256 == pin.profileSHA256)
        let target = try imported.target(at: 0)
        try require(target.candidate.identity().sha256 == pin.targetSHA256)
        try require(
            target.candidate.rule.preferredInterval.lower == 10
                && target.candidate.rule.preferredInterval.upper == 10)
        try require(
            target.candidate.rule.observedCPPS.lower == 4
                && target.candidate.rule.observedCPPS.upper == 10)
        try require(target.candidate.rule.featureScaling == "identity; CPPS dB")
        try require(target.candidate.rule.statistic == .selectedIntervalLowerMedianV1)
        try require(
            target.candidate.rule.preferredTraining.count == 7
                && target.candidate.rule.usualTraining.count == 7)
        try require(
            target.candidate.contextRules.count == 6 && target.claimedEvaluationIdentity != nil)
        try require(target.validationClaim.identity() == target.candidate.validationIdentity)
        try require(target.compatibility(with: profile) == .requiresVerifiedEvaluation)
        let changed = try AnalysisScheduleProfile(
            inputFormat: profile.inputFormat, channels: profile.channels, levels: profile.levels)
        try require(target.compatibility(with: changed) == .differentProfile)
        let future = try imported.target(at: 1)
        try require(
            future.candidate.implementation.version == 99 && future.claimedEvaluationIdentity == nil
        )
        try require(future.compatibility(with: profile) == .unsupportedFittingImplementation)
        // No fitting, evaluation or activation API is called by this probe.
        // A claimed passing receipt remains an inspection document on both OSes.
    }

    private struct CalibrationManifest: Decodable {
        let schemaVersion: Int
        let containsHumanVoice: Bool
        let name, sha256: String
        let byteCount: Int
        let profileSHA256, datasetSHA256, splitSHA256, targetSHA256: String
    }
    private enum Failure: Error { case failedCheck }
    private static func require(_ condition: Bool) throws {
        guard condition else { throw Failure.failedCheck }
    }
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let containsHumanVoice: Bool
        let sourceStartSample: Int64
        let files: [File]
        struct File: Decodable {
            let name: String
            let sha256: String
            let byteCount: Int
        }
    }
    private static func reader(_ bytes: Data, recovery: SessionArchiveRecovery = .requireComplete)
        throws -> SessionArchiveReader
    {
        var offset = 0
        return try SessionArchiveReader(
            limits: SessionArchiveLimits(ioChunkCapacity: 256), recovery: recovery,
            mediaAccess: .deliverBytes
        ) { n in
            let value = Data(bytes.dropFirst(offset).prefix(min(n, 17)))
            offset += value.count
            return value
        }
    }
    private static func copy(_ event: SessionArchiveEvent, to writer: SessionArchiveWriter) throws {
        switch event {
        case .profile(let index, let value): try require(writer.addProfile(value) == index)
        case .source(let index, let value): try require(writer.addSource(value) == index)
        case .series(let index, let value): try require(writer.addSeries(value) == index)
        case .measurement(let index, let value): try writer.append(value, to: index)
        case .gap(let value): try writer.append(value)
        case .calibrationDataset(let index, let value):
            try require(writer.addCalibrationDataset(value) == index)
        case .calibrationSplit(let index, let value):
            try require(writer.addCalibrationSplit(value) == index)
        case .calibrationAnalysis(let index, let value):
            try require(writer.addCalibrationAnalysis(value) == index)
        case .target(let index, let value): try require(writer.addTarget(value) == index)
        case .mediaReference(let index, let value):
            try require(writer.addMediaReference(value) == index)
        case .mediaChunk(let chunk):
            guard let bytes = chunk.bytes else { throw Failure.failedCheck }
            try writer.appendMedia(bytes, to: chunk.referenceIndex)
        case .replayPlan(let index, let value): try require(writer.addReplayPlan(value) == index)
        case .seal(let value): try require(writer.finish(value.completion) == value)
        case .incomplete: throw Failure.failedCheck
        }
    }
}
