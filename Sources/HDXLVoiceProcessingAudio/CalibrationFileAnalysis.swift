import AVFAudio
import Foundation
import HDXLVoiceProcessing

/// Synchronous offline work: call from a serialized worker, never capture/UI.
/// The caller explicitly supplies a private scratch directory for a temporary
/// verified audio copy. Normal success, failure and cancellation remove the copy;
/// hosts should remove abandoned calibration-* directories after process crashes.
public enum CalibrationFileAnalysis {
    public static func run(
        take: CalibrationTake, mediaURL: URL, scratchDirectory: URL,
        limits: CalibrationFileLimits, cached: CalibrationAnalysisRecord? = nil,
        shouldContinue: (CalibrationFileCheckpoint) -> Bool = { _ in true },
        emit: (ScheduledFrame) -> Void = { _ in }
    ) throws -> CalibrationFileAnalysisResult {
        do {
            guard take.media.byteCount <= limits.maximumMediaBytes else {
                throw CalibrationFileFailure.mediaTooLarge
            }
            guard take.source.sampleCount <= limits.maximumSourceSamples,
                Double(take.source.sampleCount) / take.source.sampleRate
                    <= limits.maximumSourceSeconds
            else { throw CalibrationFileFailure.analysisCapacityExceeded }
            let mask = try PreparedAnalysisMask(
                timeline: MaskTimeline(take.effectiveMaskPlan()), scope: .selected)
            // Validate every whole-interval region before any decoder/kernel allocation.
            if let cpps = take.profile.cpps, cpps.cepstrogram.previewHopLength == nil {
                for region in mask.regions {
                    _ = try IntervalCepstrogramLayout(
                        configuration: cpps.cepstrogram, inputSampleCount: Int(region.sampleCount))
                }
            }
            let snapshot = try CalibrationMediaSnapshot(
                take: take, original: mediaURL, scratchDirectory: scratchDirectory,
                limits: limits, shouldContinue: shouldContinue)
            // Keep the immutable copy alive through decoder close and callbacks.
            return try withExtendedLifetime(snapshot) {
                var execution = CalibrationFileExecution()
                execution.snapshotBytes = snapshot.byteCount
                execution.maximumSnapshotChunkBytes = snapshot.maximumChunkBytes
                guard shouldContinue(checkpoint(take, .preparation, execution)) else {
                    throw CalibrationFileFailure.cancelled
                }
                let decoder = try inspect(snapshot.url, profile: take.profile)
                guard take.source.endSample <= decoder.fileSampleCount else {
                    throw CalibrationFileFailure.invalidRange
                }
                let key = try CalibrationAnalysisKey(take: take, decoder: decoder)
                if let cached, cached.key == key,
                    cached.summaries.allSatisfy({
                        $0.observationCount <= limits.maximumObservationsPerMetric
                    }),
                    (try? cached.validate(for: take)) != nil
                {
                    guard shouldContinue(checkpoint(take, .summary, execution)) else {
                        throw CalibrationFileFailure.cancelled
                    }
                    return CalibrationFileAnalysisResult(
                        record: cached, reusedCache: true, execution: execution)
                }
                if take.profile.inputPrecision == .float32 {
                    return try analyze(
                        Float.self, take: take, url: snapshot.url, mask: mask, key: key,
                        limits: limits, execution: execution, shouldContinue: shouldContinue,
                        emit: emit)
                } else {
                    return try analyze(
                        Double.self, take: take, url: snapshot.url, mask: mask, key: key,
                        limits: limits, execution: execution, shouldContinue: shouldContinue,
                        emit: emit)
                }
            }
        } catch {
            throw failure(error)
        }
    }

    private static func inspect(_ url: URL, profile: AnalysisScheduleProfile) throws
        -> CalibrationDecoderProvenance
    {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: profile.inputPrecision == .float32
                    ? .pcmFormatFloat32 : .pcmFormatFloat64,
                interleaved: profile.inputFormat.layout == .interleaved)
        } catch { throw CalibrationFileFailure.invalidMedia }
        defer { file.close() }
        guard file.processingFormat.sampleRate == profile.inputFormat.sampleRate,
            Int(file.processingFormat.channelCount) == profile.inputFormat.channelCount,
            file.processingFormat.isInterleaved == (profile.inputFormat.layout == .interleaved)
        else { throw CalibrationFileFailure.incompatibleFormat }
        return try provenance(
            storage: AudioFileStorageFormat(file.fileFormat), profile: profile,
            fileSampleCount: file.length,
            identifier: "apple-avaudiofile-native-pcm-v1",
            runtime: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private static func provenance(
        storage: AudioFileStorageFormat, profile: AnalysisScheduleProfile, fileSampleCount: Int64,
        identifier: String, runtime: String
    ) throws -> CalibrationDecoderProvenance {
        try CalibrationDecoderProvenance(
            identifier: identifier, runtime: runtime,
            storage: [
                "sampleRate": .real(storage.sampleRate),
                "formatID": .integer(Int64(storage.formatID)),
                "formatFlags": .integer(Int64(storage.formatFlags)),
                "bytesPerPacket": .integer(Int64(storage.bytesPerPacket)),
                "framesPerPacket": .integer(Int64(storage.framesPerPacket)),
                "bytesPerFrame": .integer(Int64(storage.bytesPerFrame)),
                "channelsPerFrame": .integer(Int64(storage.channelsPerFrame)),
                "bitsPerChannel": .integer(Int64(storage.bitsPerChannel)),
            ], decodedPCM: profile.inputFormat, fileSampleCount: fileSampleCount)
    }

    private static func analyze<Sample: BinaryFloatingPoint & Sendable>(
        _: Sample.Type, take: CalibrationTake, url: URL, mask: PreparedAnalysisMask,
        key: CalibrationAnalysisKey, limits: CalibrationFileLimits,
        execution initialExecution: CalibrationFileExecution,
        shouldContinue: (CalibrationFileCheckpoint) -> Bool, emit: (ScheduledFrame) -> Void
    ) throws -> CalibrationFileAnalysisResult {
        let origin = try AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: take.source.epoch, startSample: take.source.startSample,
                sampleCount: 0, sampleRate: take.source.sampleRate),
            continuityEpoch: take.source.epoch,
            sourceStartSeconds: Double(take.source.startSample) / take.source.sampleRate)
        let worker = try PreparedAudioFileSchedule<Sample>(
            url: url, profile: take.profile, origin: origin,
            sampleCount: take.source.sampleCount, chunkCapacity: limits.decodedChunkCapacity,
            mask: mask)
        let actual = try provenance(
            storage: worker.decoding.storage, profile: take.profile,
            fileSampleCount: worker.decoding.fileSampleCount,
            identifier: worker.decoding.decoderIdentifier, runtime: worker.decoding.platformVersion)
        guard actual == key.decoder else { throw CalibrationFileFailure.incompatibleFormat }
        var collector = try CalibrationSummaryAccumulator(
            profile: take.profile, maximumObservationsPerMetric: limits.maximumObservationsPerMetric
        )
        var execution = initialExecution
        execution.maximumPreparedBufferBytes = worker.preparedBufferBytes
        execution.reservedScalarBytes = collector.reservedValueBytes
        var callbackFailure: CalibrationFileFailure?
        while worker.completion == nil {
            guard shouldContinue(checkpoint(take, .analysis, execution, worker.nextSourceSample))
            else {
                worker.cancel()
                throw CalibrationFileFailure.cancelled
            }
            let progress = try worker.read(maximumChunks: 1) { output in
                guard callbackFailure == nil else { return }
                guard
                    shouldContinue(
                        checkpoint(take, .analysis, execution, output.frame.timing.source.endSample)
                    )
                else {
                    callbackFailure = .cancelled
                    worker.cancel()
                    return
                }
                do {
                    try collector.append(output.frame)
                    emit(output.frame)
                } catch {
                    callbackFailure = failure(error)
                    worker.cancel()
                }
            } regionCompleted: { _ in
                execution.maximumPreparedBufferBytes = max(
                    execution.maximumPreparedBufferBytes, worker.preparedBufferBytes)
            }
            if let callbackFailure { throw callbackFailure }
            execution.decoderReadCount += 1
            execution.decodedSamples += progress.decodedSampleCount
            execution.maximumDecodedChunkSamples = max(
                execution.maximumDecodedChunkSamples, Int(progress.decodedSampleCount))
            execution.maximumPreparedBufferBytes = max(
                execution.maximumPreparedBufferBytes, worker.preparedBufferBytes)
            if worker.isCancelled { throw CalibrationFileFailure.cancelled }
        }
        let counts: AnalysisCoverageCounts
        switch worker.completion {
        case .masked(let completion): counts = completion.coverage
        case .analyzed(let completion): counts = completion.coverage
        default: throw CalibrationFileFailure.analysisFailed
        }
        guard shouldContinue(checkpoint(take, .summary, execution, worker.nextSourceSample)) else {
            throw CalibrationFileFailure.cancelled
        }
        let record = try collector.finish(key: key, coverage: CalibrationCoverage(counts))
        try record.validate(for: take)
        execution.retainedScalarCount = collector.retainedValueCount
        return CalibrationFileAnalysisResult(
            record: record, reusedCache: false, execution: execution)
    }

    private static func checkpoint(
        _ take: CalibrationTake, _ stage: CalibrationFileStage,
        _ execution: CalibrationFileExecution,
        _ nextSample: Int64? = nil
    ) -> CalibrationFileCheckpoint {
        CalibrationFileCheckpoint(
            takeID: take.id, stage: stage, copiedBytes: execution.snapshotBytes,
            nextSourceSample: nextSample ?? take.source.startSample)
    }

    private static func failure(_ error: any Error) -> CalibrationFileFailure {
        if let error = error as? CalibrationFileFailure { return error }
        if error as? CalibrationError == .capacityExceeded
            || error as? AnalysisScheduleError == .capacityExceeded
            || error as? ConditioningError == .capacityExceeded
            || error as? CPPSError == .capacityExceeded
        {
            return .analysisCapacityExceeded
        }
        if let error = error as? AudioFileScheduleError {
            switch error {
            case .formatMismatch: return .incompatibleFormat
            case .invalidRange: return .invalidRange
            case .invalidCapacity: return .analysisCapacityExceeded
            default: return .invalidMedia
            }
        }
        return .analysisFailed
    }
}

/// Processes canonical session/take order, one private snapshot and numerical
/// worker at a time. Results are delivered immediately and not retained here.
/// Reusing cached summaries emits no raw frames. Failed/cancelled inputs never
/// produce a partial cache, and do not prevent later inputs from being analyzed.
public enum CalibrationFileAnalysisBatch {
    public static func run(
        dataset: CalibrationDataset, scratchDirectory: URL, limits: CalibrationFileLimits,
        resolveMedia: (CalibrationMediaReference) throws -> URL?,
        cached: (CalibrationTake) -> CalibrationAnalysisRecord? = { _ in nil },
        control: (CalibrationFileCheckpoint) -> AudioFileBatchAction = { _ in .proceed },
        emit: (UUID, ScheduledFrame) -> Void = { _, _ in },
        inputCompleted: (UUID, CalibrationFileInputResult) -> Void
    ) -> CalibrationFileBatchReport {
        var analyzed = 0
        var reused = 0
        var failed = 0
        var excluded = 0
        var cancelled = 0
        var cancelRemaining = false
        for session in dataset.sessions {
            for take in session.takes {
                let start = CalibrationFileCheckpoint(
                    takeID: take.id, stage: .snapshot, copiedBytes: 0,
                    nextSourceSample: take.source.startSample)
                let action = cancelRemaining ? .cancelBatch : control(start)
                if action != .proceed {
                    if action == .cancelBatch { cancelRemaining = true }
                    cancelled += 1
                    inputCompleted(take.id, .cancelled)
                    continue
                }
                if take.exclusionReason != nil {
                    excluded += 1
                    inputCompleted(take.id, .excluded)
                    continue
                }
                do {
                    let url: URL?
                    do { url = try resolveMedia(take.media) } catch {
                        throw CalibrationFileFailure.unreadableMedia
                    }
                    guard let url else { throw CalibrationFileFailure.missingMedia }
                    let result = try CalibrationFileAnalysis.run(
                        take: take, mediaURL: url, scratchDirectory: scratchDirectory,
                        limits: limits, cached: cached(take),
                        shouldContinue: { checkpoint in
                            let action = control(checkpoint)
                            if action == .cancelBatch { cancelRemaining = true }
                            return action == .proceed
                        }, emit: { emit(take.id, $0) })
                    if result.reusedCache { reused += 1 } else { analyzed += 1 }
                    inputCompleted(take.id, .completed(result))
                } catch {
                    let failure = (error as? CalibrationFileFailure) ?? .analysisFailed
                    if failure == .cancelled {
                        cancelled += 1
                        inputCompleted(take.id, .cancelled)
                    } else {
                        failed += 1
                        inputCompleted(take.id, .failed(failure))
                    }
                }
            }
        }
        return CalibrationFileBatchReport(
            analyzed: analyzed, reused: reused, failed: failed, excluded: excluded,
            cancelled: cancelled)
    }
}
