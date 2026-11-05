import Foundation

/// Owned control-plane aggregation of separately conditioned selected regions.
/// This never concatenates PCM or computes across a missing/selection boundary.
/// Coverage retains the original timeline; observed duration counts only regions
/// with a complete numerical result, once each regardless of overlapping frames.
public struct CPPSRegionReport: Sendable, Hashable {
    public let profile: CPPSStatisticProfile
    public let identity: ProfileIdentity
    public let timeline: MaskTimeline
    public let regions: [CPPSCompletion]
    public let observedSampleCount: Int64
    public let observedDurationSeconds: Double
    public let observedSelectedCoverage: Double
    public let availableFrameCount: Int
    public let meanDB: Double?
    public let unavailability: UnavailabilityReason?

    public init(profile: CPPSStatisticProfile, timeline: MaskTimeline, regions: [CPPSCompletion])
        throws
    {
        try profile.validate(timeline)
        guard profile.aggregation != .rollingFrameMean,
            regions.count == timeline.selectedRegions.count
        else {
            throw CPPSError.invalidConfiguration
        }
        let measurementIdentity = try profile.measurement.identity()
        var observed: Int64 = 0
        var frames = 0
        for (result, source) in zip(regions, timeline.selectedRegions) {
            guard result.source == source, result.profile == measurementIdentity else {
                throw CPPSError.profileMismatch
            }
            if result.meanDB != nil {
                observed += source.sampleCount
                let next = frames.addingReportingOverflow(result.availableFrameCount)
                guard !next.overflow else { throw CPPSError.capacityExceeded }
                frames = next.partialValue
            }
        }
        let denominator = profile.aggregation == .equalFrameMean ? Double(frames) : Double(observed)
        var sum = 0.0
        var correction = 0.0
        for result in regions {
            guard let mean = result.meanDB else { continue }
            let weight =
                profile.aggregation == .equalFrameMean
                ? Double(result.availableFrameCount) : Double(result.source.sampleCount)
            let adjusted = mean * (weight / denominator) - correction
            let next = sum + adjusted
            correction = (next - sum) - adjusted
            sum = next
        }
        self.profile = profile
        identity = try profile.identity()
        self.timeline = timeline
        self.regions = regions
        observedSampleCount = observed
        observedDurationSeconds = Double(observed) / timeline.plan.source.sampleRate
        observedSelectedCoverage =
            timeline.coverage.selectedSampleCount == 0
            ? 0 : Double(observed) / Double(timeline.coverage.selectedSampleCount)
        availableFrameCount = frames
        if denominator > 0, sum.isFinite {
            meanDB = sum
            unavailability = nil
        } else {
            meanDB = nil
            if timeline.plan.source.sampleCount == 0 {
                unavailability = .insufficientData
            } else if timeline.coverage.eligibleSampleCount == 0 {
                unavailability = .missingAcquisition
            } else if timeline.coverage.selectedSampleCount == 0 {
                unavailability = .excluded
            } else {
                unavailability = regions.compactMap(\.unavailability).first ?? .insufficientData
            }
        }
    }

    public func measurementResult() throws -> MeasurementResult {
        let outcome: MeasurementOutcome
        if let meanDB {
            let partial = observedSampleCount != timeline.plan.source.sampleCount
            outcome = .available(
                try ScalarEstimate(
                    value: meanDB,
                    warnings: partial ? [.partialCoverage] : []))
        } else {
            outcome = .unavailable(unavailability ?? .analysisFailure)
        }
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .cpps, unit: .decibelsRatio, algorithm: identity.identifier),
            profile: identity,
            timing: AnalysisTiming(
                source: timeline.plan.source, includedSampleCount: observedSampleCount,
                effectiveDelaySeconds: max(
                    timeline.plan.source.durationSeconds / 2, timeline.plan.effectiveDelaySeconds)),
            outcome: outcome)
    }
}
