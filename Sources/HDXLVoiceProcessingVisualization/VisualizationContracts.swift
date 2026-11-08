import Foundation
import HDXLVoiceProcessing

public enum VisualizationError: Error, Sendable, Equatable {
    case invalidConfiguration, capacityExceeded, incompatibleSource, incompatibleSeries
    case unorderedMeasurements, duplicateMeasurement, incompatibleAxis, invalidSelection
    case unsupportedDisplayConversion, nonfiniteDisplayValue
}

/// Presentation budgets, independent of algorithm configuration. These count retained
/// records/scalars and metadata UTF-8 payloads, not allocator overhead or process RSS.
/// Repeated metadata is charged conservatively even when Swift shares its storage.
public struct VisualizationLimits: Sendable, Hashable {
    public let maximumMeasurements: Int
    public let maximumFrameScalars: Int
    public let maximumSegments: Int
    public let maximumMetadataBytes: Int

    public static let standard = Self()

    private init() {
        maximumMeasurements = 4096
        maximumFrameScalars = 262_144
        maximumSegments = 8192
        maximumMetadataBytes = 1_048_576
    }

    public init(
        maximumMeasurements: Int, maximumFrameScalars: Int,
        maximumSegments: Int, maximumMetadataBytes: Int
    ) throws {
        guard (1...1_048_576).contains(maximumMeasurements),
            (1...16_777_216).contains(maximumFrameScalars),
            (1...1_048_576).contains(maximumSegments),
            (1...67_108_864).contains(maximumMetadataBytes)
        else { throw VisualizationError.invalidConfiguration }
        self.maximumMeasurements = maximumMeasurements
        self.maximumFrameScalars = maximumFrameScalars
        self.maximumSegments = maximumSegments
        self.maximumMetadataBytes = maximumMetadataBytes
    }
}

/// A source clock cannot be identified by sample rate or elapsed time alone.
public struct VisualizationSource: Sendable, Hashable {
    public let epoch: StreamEpoch
    public let sampleRate: Double

    public init(_ interval: SourceInterval) {
        epoch = interval.epoch
        sampleRate = interval.sampleRate
    }

    public func contains(_ interval: SourceInterval) -> Bool {
        epoch == interval.epoch && sampleRate == interval.sampleRate
    }
}

/// Approximate display coordinates retain the exact interval separately.
public struct VisualizationTimeSpan: Sendable, Hashable {
    public let source: SourceInterval
    public let lowerSeconds: Double
    public let centerSeconds: Double
    public let upperSeconds: Double
}

/// Relative sample arithmetic happens before floating-point conversion. Choose an
/// origin near the visible history; large absolute source/host clocks remain metadata.
public struct VisualizationTimeAxis: Sendable, Hashable {
    public let source: VisualizationSource
    public let originSample: Int64

    public init(origin: SourceInterval) throws {
        guard origin.sampleCount == 0 else { throw VisualizationError.invalidConfiguration }
        source = VisualizationSource(origin)
        originSample = origin.startSample
    }

    public func placement(of interval: SourceInterval) throws -> VisualizationTimeSpan {
        guard source.contains(interval) else { throw VisualizationError.incompatibleSource }
        let lower = Double(interval.startSample - originSample) / source.sampleRate
        let upper = Double(interval.endSample - originSample) / source.sampleRate
        // Dividing the integer count first preserves half-sample centers near Int64.max.
        let centerSample = interval.startSample + interval.sampleCount / 2
        let center =
            (Double(centerSample - originSample) + Double(interval.sampleCount % 2) / 2)
            / source.sampleRate
        guard lower.isFinite, center.isFinite, upper.isFinite else {
            throw VisualizationError.nonfiniteDisplayValue
        }
        return VisualizationTimeSpan(
            source: interval, lowerSeconds: lower, centerSeconds: center, upperSeconds: upper)
    }
}

/// Shared source selection for scalar, array and segmentation views. A zero-length
/// interval is a cursor; other intervals use half-open overlap. This does not combine
/// epochs, align different takes, or claim overlapping estimates are independent.
public struct VisualizationSelection: Sendable, Hashable {
    public let source: SourceInterval

    public init(source: SourceInterval) { self.source = source }

    public func intersects(_ support: SourceInterval) -> Bool {
        guard VisualizationSource(source).contains(support) else { return false }
        if source.sampleCount == 0 {
            return support.sampleCount == 0
                ? source.startSample == support.startSample
                : support.startSample <= source.startSample
                    && source.startSample < support.endSample
        }
        if support.sampleCount == 0 {
            return source.startSample <= support.startSample
                && support.startSample < source.endSample
        }
        return source.startSample < support.endSample && support.startSample < source.endSample
    }
}

/// Presentation state is supplied by the host. None of these states starts a task,
/// requests permission, changes an analysis profile, or creates a numeric estimate.
public enum VisualizationState: Sendable, Hashable {
    case loading, running, paused
    case interrupted(ResetReason)
    case insufficientData
    case unsupportedMetric(MeasurementKind)
    case failure(VersionedIdentifier)

    public var title: String {
        switch self {
        case .loading: "Loading"
        case .running: "Running"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        case .insufficientData: "Insufficient data"
        case .unsupportedMetric: "Unsupported measurement"
        case .failure: "Analysis unavailable"
        }
    }
}
