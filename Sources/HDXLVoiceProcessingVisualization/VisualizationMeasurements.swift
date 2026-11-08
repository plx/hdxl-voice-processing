import Foundation
import HDXLVoiceProcessing

/// Separate algorithms, units, profiles, acquisition clocks and continuity regions
/// are separate series. Hosts may compare them explicitly; adapters never blend them.
public struct VisualizationSeriesKey: Sendable, Hashable {
    public let measurement: MeasurementDescriptor
    public let profile: ProfileIdentity
    public let source: VisualizationSource
    public let scheduledOrigin: AnalysisScheduleOrigin?

    public init(
        measurement: MeasurementDescriptor, profile: ProfileIdentity,
        source: VisualizationSource, scheduledOrigin: AnalysisScheduleOrigin? = nil
    ) throws {
        if let scheduledOrigin, !source.contains(scheduledOrigin.source) {
            throw VisualizationError.incompatibleSource
        }
        self.measurement = measurement
        self.profile = profile
        self.source = source
        self.scheduledOrigin = scheduledOrigin
    }
}

/// Stable inspection identity includes scientific provenance, not a mutable array index.
public struct VisualizationMeasurementID: Sendable, Hashable {
    public let series: VisualizationSeriesKey
    public let support: SourceInterval
}

/// Owns the original Core result. Scheduled exports additionally retain mask,
/// dependency coverage/support, origin clocks and bounded worker batching metadata.
/// No result, uncertainty, warning or optional intermediate is discarded by adaptation.
public struct VisualizationMeasurement: Sendable, Hashable, Identifiable {
    public let result: MeasurementResult
    public let scheduled: ScheduledMeasurementExport?
    public let id: VisualizationMeasurementID

    public init(_ result: MeasurementResult) {
        self.result = result
        scheduled = nil
        // A key derived from one already-validated result cannot have an incompatible origin.
        let key = VisualizationSeriesKey(validatedResult: result, scheduledOrigin: nil)
        id = VisualizationMeasurementID(series: key, support: result.timing.source)
    }

    public init(_ export: ScheduledMeasurementExport) {
        result = export.result
        scheduled = export
        let key = VisualizationSeriesKey(
            validatedResult: export.result, scheduledOrigin: export.origin)
        id = VisualizationMeasurementID(series: key, support: result.timing.source)
    }

    public init(_ frame: ScheduledFrame, metric: ScheduledMetric) throws {
        self.init(try frame.export(metric))
    }

    public var numericValue: Double? { result.outcome.estimate?.value }
}

extension VisualizationSeriesKey {
    fileprivate init(
        validatedResult result: MeasurementResult, scheduledOrigin: AnalysisScheduleOrigin?
    ) {
        measurement = result.measurement
        profile = result.profile
        source = VisualizationSource(result.timing.source)
        self.scheduledOrigin = scheduledOrigin
    }
}

/// A finite, immutable history for one scientific series and continuity region.
/// Construction validates ordering instead of silently sorting or dropping results.
/// Compose separate snapshots for profile/epoch changes; never join their curves.
public struct VisualizationMetricSnapshot: Sendable, Hashable {
    public let series: VisualizationSeriesKey
    public let measurements: [VisualizationMeasurement]
    public let boundaries: [SourceDiscontinuity]
    public let limits: VisualizationLimits
    public let retainedIntermediateScalars: Int

    public init(
        series: VisualizationSeriesKey, measurements: [VisualizationMeasurement],
        boundaries: [SourceDiscontinuity] = [], limits: VisualizationLimits = .standard
    ) throws {
        guard measurements.count <= limits.maximumMeasurements,
            boundaries.count <= limits.maximumSegments
        else { throw VisualizationError.capacityExceeded }
        var remaining = limits.maximumFrameScalars
        var metadata = VisualizationMetadataBudget(limits)
        try metadata.charge(series.profile)
        try metadata.charge(series.measurement.algorithm)
        var previous: Int64?
        for item in measurements {
            guard item.id.series == series else { throw VisualizationError.incompatibleSeries }
            try metadata.charge(item.result)
            if let mask = item.scheduled?.mask { try metadata.charge(mask) }
            let start = item.result.timing.source.startSample
            if let previous {
                guard start != previous else { throw VisualizationError.duplicateMeasurement }
                guard start > previous else { throw VisualizationError.unorderedMeasurements }
            }
            previous = start
            for frame in item.result.intermediates {
                guard frame.values.count <= remaining else {
                    throw VisualizationError.capacityExceeded
                }
                remaining -= frame.values.count
            }
        }
        for boundary in boundaries {
            guard
                boundary.previousEpoch == series.source.epoch
                    || boundary.nextEpoch == series.source.epoch
            else { throw VisualizationError.incompatibleSource }
            if let missing = boundary.missingSource,
                missing.epoch == series.source.epoch,
                missing.sampleRate != series.source.sampleRate
            {
                throw VisualizationError.incompatibleSource
            }
        }
        self.series = series
        self.measurements = measurements
        self.boundaries = boundaries
        self.limits = limits
        retainedIntermediateScalars = limits.maximumFrameScalars - remaining
    }

    /// Exact lookup refuses an ID from a different profile/epoch, even if its time matches.
    public func inspect(_ id: VisualizationMeasurementID) -> VisualizationMeasurement? {
        guard id.series == series else { return nil }
        var low = 0
        var high = measurements.count
        while low < high {
            let middle = low + (high - low) / 2
            if measurements[middle].id.support.startSample < id.support.startSample {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < measurements.count, measurements[low].id == id else { return nil }
        return measurements[low]
    }

    /// Overlapping windows may all match. No implicit aggregate or independent-sample count.
    public func selected(by selection: VisualizationSelection) -> [VisualizationMeasurement] {
        measurements.filter { selection.intersects($0.result.timing.source) }
    }
}
