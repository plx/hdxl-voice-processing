import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

/// Public-API host example. All methods are synchronous worker operations, never
/// capture callbacks. Callers serialize access to their own trusted directories.
/// No method logs paths, identifiers, measured values, labels or audio.
public enum StoredSessionWorkflow {
    public static func failureCode(_ error: any Error) -> String {
        (error as? SessionArchiveError)?.rawValue ?? "storageFailure"
    }

    public struct Inspection: Sendable, Codable, Equatable {
        public let completion: String
        public let audioPolicy: String
        public let embeddedAudioBytes: UInt64
        public let measurements: UInt64
        public let gaps: UInt64
        public let targetsForInspection: Int
        public let replayPlans: Int
    }

    /// Deliberately smaller than the library ceilings for this example host.
    public static func limits() throws -> SessionArchiveLimits {
        try SessionArchiveLimits(
            maximumArchiveBytes: 64 * 1024 * 1024, maximumRecordBytes: 1024 * 1024,
            maximumCatalogBytes: 8 * 1024 * 1024, maximumRecords: 100_000,
            maximumEmbeddedMediaBytes: 32 * 1024 * 1024)
    }

    /// One second of original, deterministic PCM16 square-wave samples, analyzed
    /// by the real level scheduler. Audio is omitted unless explicitly requested.
    /// This demonstration is not a calibration or voice-quality validation input.
    public static func createSynthetic(
        at destination: URL, scratch: URL, includeAudio: Bool = false,
        publication: SessionArchiveFilePublication = .create,
        shouldContinue: @escaping () -> Bool = { true }
    ) throws -> Inspection {
        let fm = FileManager.default
        let directory = scratch.appendingPathComponent(
            "session-example-\(UUID())", isDirectory: true)
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.wav")
        let bytes = syntheticWAV()
        try bytes.write(to: original, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        let levels = try LevelConfiguration(
            sampleRate: 16_000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
            accumulation: .compensatedSliding, weighting: .none)
        let profile = try AnalysisScheduleProfile(
            inputFormat: PCMFormat(sampleRate: 16_000, channelCount: 1, encoding: .float64),
            channels: .arithmeticMean, levels: levels)
        let epoch = StreamEpoch(streamID: UUID())
        let interval = try SourceInterval(
            epoch: epoch, startSample: 0, sampleCount: 16_000, sampleRate: 16_000)
        let origin = try AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: 16_000),
            continuityEpoch: StreamEpoch(streamID: UUID()))
        let source = try SessionArchiveSource(
            origin: origin,
            acquisition: SessionAcquisitionMetadata(
                conditions: CalibrationRecordingConditions(routeIdentifier: "synthetic-PCM")))
        let worker = try PreparedAudioFileSchedule<Double>(
            url: original, profile: profile, origin: origin, sampleCount: interval.sampleCount,
            chunkCapacity: 1024, sourceTileCapacity: 256)
        defer { worker.cancel() }
        let reference = try SessionArchiveMediaReference(
            media: CalibrationMediaReference(
                referenceIdentifier: "synthetic-one-second", originalRecordingID: UUID(),
                content: CalibrationDigest(bytes: bytes), byteCount: Int64(bytes.count)),
            decoder: CalibrationDecoderProvenance(worker.decoding),
            inclusion: includeAudio ? .embedded : .omitted,
            provenance: VersionedIdentifier(name: "session-example-square-wave", version: 1),
            mappings: [
                SessionArchiveMediaMapping(sourceIndex: 0, source: interval, fileStartSample: 0)
            ])
        let header = try SessionArchiveHeader(
            id: UUID(), producer: VersionedIdentifier(name: "session-storage-example", version: 1),
            audioPolicy: includeAudio ? .explicitlyInclude : .omit,
            notes: "Synthetic PCM analysis; no microphone, person or target validation.")
        try SessionArchiveFiles.write(
            to: destination, publication: publication, header: header, limits: limits(),
            shouldContinue: shouldContinue
        ) { writer in
            try writer.addProfile(.schedule(profile))
            try writer.addSource(source)
            var seriesIndex: UInt32?
            while worker.completion == nil {
                guard shouldContinue() else { throw SessionArchiveError.cancelled }
                var problem: (any Error)?
                try worker.read { output in
                    guard problem == nil else { return }
                    do {
                        let export = try output.frame.export(.rms)
                        if seriesIndex == nil {
                            seriesIndex = try writer.addSeries(
                                SessionArchiveSeries(
                                    profileIndex: 0, sourceIndex: 0,
                                    measurement: export.result.measurement,
                                    clock: .secondsFromOrigin, isScheduled: true))
                        }
                        guard let seriesIndex else { throw SessionArchiveError.invalidState }
                        try writer.append(export, to: seriesIndex)
                    } catch { problem = error }
                }
                if let problem { throw problem }
            }
            guard let seriesIndex else { throw SessionArchiveError.analysisFailure }
            let mediaIndex: UInt32
            if includeAudio {
                mediaIndex = try SessionArchiveFiles.appendMediaFile(
                    at: original, reference: reference, to: writer, shouldContinue: shouldContinue)
            } else {
                mediaIndex = try writer.addMediaReference(reference)
            }
            try writer.addReplayPlan(
                SessionArchiveReplayPlan(
                    seriesIndex: seriesIndex, mediaReferenceIndex: mediaIndex, mappingIndex: 0))
        }
        return try inspect(at: destination)
    }

    /// Full validation completes before returning a display summary. Imports are
    /// inspectable data; this example never fits, evaluates or activates targets.
    public static func inspect(at url: URL) throws -> Inspection {
        var targets = 0
        var plans = 0
        let reader = try SessionArchiveFiles.inspect(
            at: url, limits: limits(),
            visit: { event in
                if case .target = event { targets += 1 }
                if case .replayPlan = event { plans += 1 }
            })
        guard let seal = reader.seal else { throw SessionArchiveError.truncated }
        return Inspection(
            completion: seal.completion.rawValue, audioPolicy: reader.header.audioPolicy.rawValue,
            embeddedAudioBytes: reader.statistics.embeddedMediaBytes,
            measurements: reader.statistics.measurementRecords, gaps: reader.statistics.gapRecords,
            targetsForInspection: targets, replayPlans: plans)
    }

    /// A host-selected import may contain audio; retain its exact declared policy
    /// and bytes privately. Failed verification leaves an existing session intact.
    public static func importArchive(from source: URL, to destination: URL) throws -> Inspection {
        try SessionArchiveFiles.copyVerified(
            from: source, to: destination, publication: .replace,
            audioPolicy: .explicitlyInclude, limits: limits())
        return try inspect(at: destination)
    }

    /// Explicitly prepare a share destination. The same input handle enforces the
    /// requested audio policy. This performs no network or system-share operation.
    public static func shareCopy(
        from source: URL, to destination: URL, includeAudio: Bool = false
    ) throws {
        try SessionArchiveFiles.copyVerified(
            from: source, to: destination,
            audioPolicy: includeAudio ? .explicitlyInclude : .omit, limits: limits())
    }

    /// Replays the first retained plan only, from verified original PCM. No
    /// imported scalar is substituted when audio is absent; no values are logged.
    public static func replay(at url: URL, scratch: URL) throws -> UInt64 {
        let result = try SessionArchiveAudioReplay.run(
            at: url, planIndex: 0, scratchDirectory: scratch, archiveLimits: limits(),
            replayLimits: SessionArchiveReplayLimits(maximumSourceSeconds: 60)
        ) { _ in }
        return result.emittedMeasurements
    }

    public static func delete(at url: URL) throws { try SessionArchiveFiles.delete(at: url) }

    private static func syntheticWAV() -> Data {
        var result = Data()
        func text(_ value: String) { result.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        text("RIFF")
        integer(UInt32(36 + 32_000))
        text("WAVEfmt ")
        integer(UInt32(16))
        integer(UInt16(1))
        integer(UInt16(1))
        integer(UInt32(16_000))
        integer(UInt32(32_000))
        integer(UInt16(2))
        integer(UInt16(16))
        text("data")
        integer(UInt32(32_000))
        for index in 0..<16_000 { integer(Int16(index % 80 < 40 ? 8192 : -8192)) }
        return result
    }
}
