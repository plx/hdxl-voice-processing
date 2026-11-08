import AVFAudio
import Foundation
import HDXLVoiceProcessing

/// Separate expansion/work bounds for explicitly requested offline replay. The
/// archive byte ceiling alone cannot bound compressed audio or numerical scratch.
/// Native profile/whole-interval layout ceilings still apply independently.
public struct SessionArchiveReplayLimits: Sendable, Hashable {
    public let maximumSourceSamples: Int64
    public let maximumSourceSeconds: Double
    /// Decoder read capacity, in `1...65_536` source frames.
    public let decodedChunkCapacity: Int
    /// Scheduler tile capacity, in `1...4096` source frames.
    public let sourceTileCapacity: Int

    public init(
        maximumSourceSamples: Int64 = 172_800_000, maximumSourceSeconds: Double = 3600,
        decodedChunkCapacity: Int = 2048, sourceTileCapacity: Int = 256
    ) throws {
        guard (1...1_000_000_000).contains(maximumSourceSamples),
            maximumSourceSeconds.isFinite, maximumSourceSeconds > 0,
            maximumSourceSeconds <= 86_400,
            (1...65_536).contains(decodedChunkCapacity), (1...4096).contains(sourceTileCapacity)
        else { throw SessionArchiveError.invalidConfiguration }
        self.maximumSourceSamples = maximumSourceSamples
        self.maximumSourceSeconds = maximumSourceSeconds
        self.decodedChunkCapacity = decodedChunkCapacity
        self.sourceTileCapacity = sourceTileCapacity
    }
}

public struct SessionArchiveReplayResult: Sendable, Hashable {
    public let archiveID: UUID
    public let sessionCompletion: SessionArchiveCompletion
    public let planIndex: UInt32
    public let seriesIndex: UInt32
    public let profile: ProfileIdentity
    public let source: SourceInterval
    /// The imported receipt is a claim. Actual storage format/PCM/length/decoder
    /// must match it; runtime may differ and is reported without rewriting either.
    public let originalDecoder: CalibrationDecoderProvenance
    public let actualDecoder: CalibrationDecoderProvenance
    public let decodedSamples: Int64
    public let emittedMeasurements: UInt64
    public let maximumDecodedChunkSamples: Int
    /// Owned worker PCM/core scratch, excluding opaque system decoder buffers.
    public let maximumPreparedBufferBytes: Int
}

/// Explicit worker-only reanalysis, never automatic during inspection/activation.
/// One bounded discovery pass chooses the media reference; a second pass verifies
/// the complete container while extracting only that original into private storage.
/// Every executable recipe and source/mask mapping comes from the verified second
/// pass. No imported timeline values are used as numerical input or validation.
public enum SessionArchiveAudioReplay {
    public static func run(
        at archiveURL: URL, planIndex: UInt32, scratchDirectory: URL,
        archiveLimits: SessionArchiveLimits, replayLimits: SessionArchiveReplayLimits,
        shouldContinue: () -> Bool = { true },
        emit: (ScheduledMeasurementExport) throws -> Void
    ) throws -> SessionArchiveReplayResult {
        do {
            let referenceIndex = try discoverReference(
                archiveURL, planIndex: planIndex, limits: archiveLimits,
                shouldContinue: shouldContinue)
            return try SessionArchiveFiles.withVerifiedMedia(
                at: archiveURL, referenceIndex: referenceIndex, scratchDirectory: scratchDirectory,
                limits: archiveLimits, shouldContinue: shouldContinue
            ) { reader, url in
                let plan = try reader.replayPlan(at: planIndex)
                guard plan.mediaReferenceIndex == referenceIndex else {
                    throw SessionArchiveError.incompatibleMedia
                }
                let series = try reader.series(at: plan.seriesIndex)
                let source = try reader.source(at: series.sourceIndex)
                let reference = try reader.mediaReference(at: referenceIndex)
                guard case .schedule(let profile) = try reader.profile(at: series.profileIndex),
                    let seal = reader.seal
                else { throw SessionArchiveError.incompatibleProfile }
                let mapping = reference.mappings[Int(plan.mappingIndex)]
                guard mapping.source.sampleCount <= replayLimits.maximumSourceSamples,
                    Double(mapping.source.sampleCount) / mapping.source.sampleRate
                        <= replayLimits.maximumSourceSeconds
                else { throw SessionArchiveError.sizeLimitExceeded }
                if let cpps = profile.cpps, cpps.cepstrogram.previewHopLength == nil {
                    _ = try IntervalCepstrogramLayout(
                        configuration: cpps.cepstrogram,
                        inputSampleCount: Int(mapping.source.sampleCount))
                }
                let mask: PreparedAnalysisMask?
                if let storedMask = plan.mask {
                    guard let provenance = series.mask else {
                        throw SessionArchiveError.incompatibleProfile
                    }
                    mask = try PreparedAnalysisMask(
                        timeline: MaskTimeline(storedMask), scope: provenance.scope)
                } else {
                    mask = nil
                }
                if let hnr = profile.hnr, hnr.normalization == .wholeInterval {
                    // Replay analyzes this mapping as one continuity region;
                    // unrelated regions in the full provenance plan are not input.
                    _ = try HNRIntervalLayout(
                        configuration: hnr,
                        sampleCount: Int(mapping.source.sampleCount))
                }
                if profile.inputPrecision == .float32 {
                    return try analyze(
                        Float.self, url: url, archiveID: reader.header.id,
                        completion: seal.completion,
                        planIndex: planIndex, plan: plan, series: series, profile: profile,
                        source: source, reference: reference, mapping: mapping, mask: mask,
                        limits: replayLimits, shouldContinue: shouldContinue, emit: emit)
                }
                return try analyze(
                    Double.self, url: url, archiveID: reader.header.id, completion: seal.completion,
                    planIndex: planIndex, plan: plan, series: series, profile: profile,
                    source: source, reference: reference, mapping: mapping, mask: mask,
                    limits: replayLimits, shouldContinue: shouldContinue, emit: emit)
            }
        } catch {
            throw (error as? SessionArchiveError) ?? .analysisFailure
        }
    }

    private static func discoverReference(
        _ url: URL, planIndex: UInt32, limits: SessionArchiveLimits,
        shouldContinue: () -> Bool
    ) throws -> UInt32 {
        let reader = try SessionArchiveFiles.inspect(
            at: url, limits: limits, shouldContinue: shouldContinue)
        return try reader.replayPlan(at: planIndex).mediaReferenceIndex
    }

    private static func analyze<Sample: BinaryFloatingPoint & Sendable>(
        _: Sample.Type, url: URL, archiveID: UUID, completion: SessionArchiveCompletion,
        planIndex: UInt32, plan: SessionArchiveReplayPlan, series: SessionArchiveSeries,
        profile: AnalysisScheduleProfile, source: SessionArchiveSource,
        reference: SessionArchiveMediaReference, mapping: SessionArchiveMediaMapping,
        mask: PreparedAnalysisMask?, limits: SessionArchiveReplayLimits,
        shouldContinue: () -> Bool, emit: (ScheduledMeasurementExport) throws -> Void
    ) throws -> SessionArchiveReplayResult {
        guard shouldContinue() else { throw SessionArchiveError.cancelled }
        let verifiedDecoder = try inspectDecoder(url, profile: profile, expected: reference.decoder)
        let worker: PreparedAudioFileSchedule<Sample>
        do {
            worker = try PreparedAudioFileSchedule(
                url: url, profile: profile, origin: source.origin,
                fileStartSample: mapping.fileStartSample, sampleCount: mapping.source.sampleCount,
                chunkCapacity: limits.decodedChunkCapacity,
                sourceTileCapacity: limits.sourceTileCapacity,
                mask: mask, maskRouting: .singleContinuityRegion)
        } catch { throw SessionArchiveError.incompatibleMedia }
        defer { worker.cancel() }
        let actual = try CalibrationDecoderProvenance(worker.decoding)
        guard actual == verifiedDecoder else { throw SessionArchiveError.incompatibleMedia }
        let metric = try metric(for: series, profile: profile)
        var decoded: Int64 = 0
        var peakChunk = 0
        var peakBuffers = worker.preparedBufferBytes
        var emitted: UInt64 = 0
        var failure: SessionArchiveError?
        while worker.completion == nil {
            guard shouldContinue() else { throw SessionArchiveError.cancelled }
            let progress = try worker.read(maximumChunks: 1) { output in
                guard failure == nil else { return }
                do {
                    guard shouldContinue() else { throw SessionArchiveError.cancelled }
                    guard output.frame.algorithm == metric.1 else { return }
                    let value = try output.frame.export(metric.0)
                    guard value.result.measurement == series.measurement else {
                        throw SessionArchiveError.incompatibleProfile
                    }
                    try emit(value)
                    emitted += 1
                } catch {
                    failure = (error as? SessionArchiveError) ?? .analysisFailure
                    worker.cancel()
                }
            }
            if let failure { throw failure }
            decoded += progress.decodedSampleCount
            peakChunk = max(peakChunk, Int(progress.decodedSampleCount))
            peakBuffers = max(peakBuffers, worker.preparedBufferBytes)
        }
        guard !worker.isCancelled, decoded == mapping.source.sampleCount else {
            throw SessionArchiveError.analysisFailure
        }
        guard shouldContinue() else { throw SessionArchiveError.cancelled }
        return try SessionArchiveReplayResult(
            archiveID: archiveID, sessionCompletion: completion, planIndex: planIndex,
            seriesIndex: plan.seriesIndex, profile: profile.identity(), source: mapping.source,
            originalDecoder: reference.decoder, actualDecoder: actual,
            decodedSamples: decoded, emittedMeasurements: emitted,
            maximumDecodedChunkSamples: peakChunk, maximumPreparedBufferBytes: peakBuffers)
    }

    private static func inspectDecoder(
        _ url: URL, profile: AnalysisScheduleProfile, expected: CalibrationDecoderProvenance
    ) throws -> CalibrationDecoderProvenance {
        guard expected.identifier == "apple-avaudiofile-native-pcm-v1" else {
            throw SessionArchiveError.incompatibleMedia
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: profile.inputPrecision == .float32
                    ? .pcmFormatFloat32 : .pcmFormatFloat64,
                interleaved: profile.inputFormat.layout == .interleaved)
        } catch { throw SessionArchiveError.incompatibleMedia }
        defer { file.close() }
        guard file.processingFormat.sampleRate == profile.inputFormat.sampleRate,
            Int(file.processingFormat.channelCount) == profile.inputFormat.channelCount,
            file.processingFormat.isInterleaved == (profile.inputFormat.layout == .interleaved)
        else { throw SessionArchiveError.incompatibleMedia }
        let actual = try CalibrationDecoderProvenance(
            AudioFileDecodingProvenance(
                url: url, storage: AudioFileStorageFormat(file.fileFormat),
                decodedPCM: profile.inputFormat, fileSampleCount: file.length,
                decoderIdentifier: "apple-avaudiofile-native-pcm-v1",
                platformVersion: ProcessInfo.processInfo.operatingSystemVersionString))
        guard actual.identifier == expected.identifier, actual.storage == expected.storage,
            actual.decodedPCM == expected.decodedPCM,
            actual.fileSampleCount == expected.fileSampleCount
        else { throw SessionArchiveError.incompatibleMedia }
        return actual
    }

    private static func metric(for series: SessionArchiveSeries, profile: AnalysisScheduleProfile)
        throws -> (ScheduledMetric, ScheduledAlgorithm)
    {
        switch series.measurement.kind {
        case .meanSquare: return (.meanSquare, .levels)
        case .rms: return (.rms, .levels)
        case .peakAmplitude: return (.peakAmplitude, .levels)
        case .crestFactor: return (.crestFactor, .levels)
        case .levelDBFS: return (.levelDBFS, .levels)
        case .clippingFraction: return (.clippingFraction, .levels)
        case .kWeightedEnergy: return (.kWeightedEnergy, .levels)
        case .fundamentalFrequency:
            guard let pitch = profile.pitch else { throw SessionArchiveError.incompatibleProfile }
            if try series.measurement.algorithm == pitch.estimator.identity().identifier {
                return (.fundamentalFrequency, .yin)
            }
            guard pitch.tracker != nil,
                try series.measurement.algorithm == pitch.identity().identifier
            else { throw SessionArchiveError.incompatibleProfile }
            return (.trackedFundamentalFrequency, .yin)
        case .cpp: return (.cpp, .cpps)
        case .cpps: return (.cpps, .cpps)
        case .harmonicToNoiseRatio: return (.harmonicToNoiseRatio, .hnr)
        default: throw SessionArchiveError.incompatibleProfile
        }
    }
}

extension CalibrationDecoderProvenance {
    /// Removes the private URL while retaining the actual container/PCM receipt.
    public init(_ value: AudioFileDecodingProvenance) throws {
        let storage = value.storage
        try self.init(
            identifier: value.decoderIdentifier, runtime: value.platformVersion,
            storage: [
                "sampleRate": .real(storage.sampleRate),
                "formatID": .integer(Int64(storage.formatID)),
                "formatFlags": .integer(Int64(storage.formatFlags)),
                "bytesPerPacket": .integer(Int64(storage.bytesPerPacket)),
                "framesPerPacket": .integer(Int64(storage.framesPerPacket)),
                "bytesPerFrame": .integer(Int64(storage.bytesPerFrame)),
                "channelsPerFrame": .integer(Int64(storage.channelsPerFrame)),
                "bitsPerChannel": .integer(Int64(storage.bitsPerChannel)),
            ], decodedPCM: value.decodedPCM, fileSampleCount: value.fileSampleCount)
    }
}
