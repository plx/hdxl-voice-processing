import Foundation

/// Owned control-plane selection of a raw observation. The original numerical
/// result remains inspectable even if its normalization dependency is excluded.
/// This does not rerun HNR or substitute a center-only membership check.
public struct HNRFrameSelection: Sendable, Hashable {
    public let profile: HNRStatisticProfile
    public let identity: ProfileIdentity
    public let raw: HNRFrameResult
    public let eligibleRegionIndex: Int?
    public let selectedRegionIndex: Int?
    public let selectionUnavailability: UnavailabilityReason?
    public let selectedObservation: HNRPeriodicityEstimate?

    public init(raw: HNRFrameResult, profile: HNRStatisticProfile, timeline: MaskTimeline) throws {
        try profile.validate(timeline)
        guard raw.profile == (try profile.measurement.identity()) else {
            throw HNRError.unexpectedContext
        }
        let support = raw.dependencyTiming.source
        eligibleRegionIndex = try timeline.eligibleRegion(containing: support)
        selectedRegionIndex = try timeline.selectedRegion(containing: support)
        selectionUnavailability =
            eligibleRegionIndex == nil
            ? .missingAcquisition
            : (selectedRegionIndex == nil ? .excluded : nil)
        selectedObservation = selectionUnavailability == nil ? raw.selectedObservation : nil
        self.raw = raw
        self.profile = profile
        identity = try profile.identity()
    }

    public func measurementResult() throws -> MeasurementResult {
        let original = try raw.measurementResult()
        let timing = original.timing
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .harmonicToNoiseRatio, unit: .decibelsRatio,
                algorithm: identity.identifier), profile: identity,
            timing: AnalysisTiming(
                source: timing.source,
                includedSampleCount: selectionUnavailability == nil
                    ? timing.includedSampleCount : 0,
                sourceStartSeconds: timing.sourceStartSeconds,
                hostStartNanoseconds: timing.hostStartNanoseconds,
                completedHostNanoseconds: timing.completedHostNanoseconds,
                effectiveDelaySeconds: timing.effectiveDelaySeconds),
            outcome: selectionUnavailability.map { .unavailable($0) } ?? original.outcome)
    }
}
