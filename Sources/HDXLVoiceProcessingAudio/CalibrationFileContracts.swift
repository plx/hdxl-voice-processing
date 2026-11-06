import Foundation
import HDXLVoiceProcessing

/// Public failures deliberately omit private paths and decoder error strings.
public enum CalibrationFileFailure: Error, Sendable, Hashable {
    case missingMedia, unreadableMedia, notRegularFile, snapshotFailed
    case mediaTooLarge, audioLengthMismatch, audioDigestMismatch
    case invalidMedia, incompatibleFormat, invalidRange
    case analysisCapacityExceeded, analysisFailed, cancelled
}

/// Offline import bounds. Callers may lower these ceilings. The selected source
/// is capped independently of file bytes, since a compressed file can expand.
/// Numerical profile scratch has its own validated native bounds; system decoder
/// buffers and Foundation overhead are not a promised hard resident-memory cap.
public struct CalibrationFileLimits: Sendable, Hashable {
    public let maximumMediaBytes: Int64
    public let maximumSourceSamples: Int64
    public let maximumSourceSeconds: Double
    public let maximumObservationsPerMetric: Int
    public let decodedChunkCapacity: Int
    public static let snapshotChunkCapacity = 64 * 1024

    public init(
        maximumMediaBytes: Int64 = 256 * 1024 * 1024,
        maximumSourceSamples: Int64 = 2_880_000,
        maximumSourceSeconds: Double = 120,
        maximumObservationsPerMetric: Int = 30_000,
        decodedChunkCapacity: Int = 2048
    ) throws {
        guard (1...256 * 1024 * 1024).contains(maximumMediaBytes),
            (1...2_880_000).contains(maximumSourceSamples),
            maximumSourceSeconds.isFinite, maximumSourceSeconds > 0, maximumSourceSeconds <= 120,
            (1...CalibrationMetricSummary.maximumObservationCount).contains(
                maximumObservationsPerMetric),
            (1...65536).contains(decodedChunkCapacity)
        else { throw CalibrationFileFailure.analysisCapacityExceeded }
        self.maximumMediaBytes = maximumMediaBytes
        self.maximumSourceSamples = maximumSourceSamples
        self.maximumSourceSeconds = maximumSourceSeconds
        self.maximumObservationsPerMetric = maximumObservationsPerMetric
        self.decodedChunkCapacity = decodedChunkCapacity
    }
}

public enum CalibrationFileStage: String, Sendable, Hashable {
    case snapshot, preparation, analysis, summary
}

public struct CalibrationFileCheckpoint: Sendable, Hashable {
    public let takeID: UUID
    public let stage: CalibrationFileStage
    public let copiedBytes: Int64
    public let nextSourceSample: Int64
}

/// Per-invocation accounting, not historical cached execution statistics. A cache
/// hit still snapshots/hashes and opens the actual decoder, but decodes no PCM.
public struct CalibrationFileExecution: Sendable, Hashable {
    public internal(set) var snapshotBytes: Int64 = 0
    public internal(set) var maximumSnapshotChunkBytes = 0
    public internal(set) var decodedSamples: Int64 = 0
    public internal(set) var decoderReadCount = 0
    public internal(set) var maximumDecodedChunkSamples = 0
    /// Owned PCM/core buffers sampled after preparation and each read/region.
    /// Excludes opaque decoder/FFT objects, mask arrays and runtime overhead.
    public internal(set) var maximumPreparedBufferBytes = 0
    public internal(set) var retainedScalarCount = 0
    /// Reserved Double element storage; quantile sorting needs at most one more
    /// metric-sized copy. Dictionary/object/allocator overhead is additional.
    public internal(set) var reservedScalarBytes = 0
}

public struct CalibrationFileAnalysisResult: Sendable, Hashable {
    public let record: CalibrationAnalysisRecord
    public let reusedCache: Bool
    public let execution: CalibrationFileExecution
}

public enum CalibrationFileInputResult: Sendable, Hashable {
    case completed(CalibrationFileAnalysisResult)
    case failed(CalibrationFileFailure)
    case excluded
    case cancelled
}

public struct CalibrationFileBatchReport: Sendable, Hashable {
    public let analyzed: Int
    public let reused: Int
    public let failed: Int
    public let excluded: Int
    public let cancelled: Int
}
