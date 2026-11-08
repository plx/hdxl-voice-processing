import Foundation

/// Aggregates independently analyzed contiguous selected regions. A whole-region
/// amplitude reference cannot be shared across acquisition or selection gaps.
/// Available local-support unions count once, rather than summing overlapping windows.
public struct HNRRegionReport: Sendable, Hashable {
    public let profile: HNRStatisticProfile
    public let identity: ProfileIdentity
    public let timeline: MaskTimeline
    public let regions: [HNRCompletion]
    public let pendingRegionCount: Int
    public let completeGridFrameCount: Int
    public let emittedSlotCount: Int
    public let availableFrameCount: Int
    public let unavailableFrameCount: Int
    public let finiteDecibelFrameCount: Int
    public let reportingLimitFrameCount: Int
    public let numericalZeroNoiseFrameCount: Int
    public let lowConfidenceFrameCount: Int
    public let clippedFrameCount: Int
    public let observedSampleCount: Int64
    public let finiteUncappedMeanDB: Double?
    public let referencePresentationMeanDB: Double?
    public let isCancelled: Bool
    public let unavailability: UnavailabilityReason?

    public var observedDurationSeconds: Double {
        Double(observedSampleCount) / timeline.plan.source.sampleRate
    }
    public var observedSelectedCoverage: Double {
        timeline.coverage.selectedSampleCount == 0
            ? 0
            : Double(observedSampleCount) / Double(timeline.coverage.selectedSampleCount)
    }
    public var frameCoverage: Double {
        emittedSlotCount == 0 ? 0 : Double(availableFrameCount) / Double(emittedSlotCount)
    }
    /// A finite-only diagnostic never silently becomes an ordinary population mean
    /// when one selected observation has numerical zero noise or analysis was cancelled.
    public var meanDB: Double? {
        !isCancelled && numericalZeroNoiseFrameCount == 0 ? finiteUncappedMeanDB : nil
    }

    public init(profile: HNRStatisticProfile, timeline: MaskTimeline, regions: [HNRCompletion])
        throws
    {
        try profile.validate(timeline)
        guard profile.measurement.normalization == .wholeInterval,
            regions.count == timeline.selectedRegions.count
                || (regions.count < timeline.selectedRegions.count
                    && regions.last?.isCancelled == true)
        else { throw HNRError.invalidConfiguration }
        let measurement = try profile.measurement.identity()
        var grid = 0
        var emitted = 0
        var available = 0
        var finite = 0
        var limits = 0
        var unity = 0
        var lowConfidence = 0
        var clipped = 0
        var observed: Int64 = 0
        func adding(_ old: Int, _ next: Int) throws -> Int {
            let sum = old.addingReportingOverflow(next)
            guard !sum.overflow else { throw HNRError.capacityExceeded }
            return sum.partialValue
        }
        for (result, source) in zip(regions, timeline.selectedRegions) {
            guard result.source == source, result.profile == measurement else {
                throw HNRError.unexpectedContext
            }
            grid = try adding(grid, result.completeGridFrameCount)
            emitted = try adding(emitted, result.emittedSlotCount)
            available = try adding(available, result.availableFrameCount)
            finite = try adding(finite, result.finiteDecibelFrameCount)
            limits = try adding(limits, result.reportingLimitFrameCount)
            unity = try adding(unity, result.numericalZeroNoiseFrameCount)
            lowConfidence = try adding(lowConfidence, result.lowConfidenceFrameCount)
            clipped = try adding(clipped, result.clippedFrameCount)
            // Regions are disjoint subsets of the original representable interval.
            observed += result.observedSampleCount
        }
        var finiteSum = HNRSum()
        var presentationSum = HNRSum()
        for result in regions {
            if let mean = result.finiteUncappedMeanDB {
                finiteSum.add(mean * (Double(result.finiteDecibelFrameCount) / Double(finite)))
            }
            if let mean = result.referencePresentationMeanDB {
                presentationSum.add(mean * (Double(result.availableFrameCount) / Double(available)))
            }
        }
        self.profile = profile
        identity = try profile.identity()
        self.timeline = timeline
        self.regions = regions
        pendingRegionCount = timeline.selectedRegions.count - regions.count
        completeGridFrameCount = grid
        emittedSlotCount = emitted
        availableFrameCount = available
        unavailableFrameCount = emitted - available
        finiteDecibelFrameCount = finite
        reportingLimitFrameCount = limits
        numericalZeroNoiseFrameCount = unity
        lowConfidenceFrameCount = lowConfidence
        clippedFrameCount = clipped
        observedSampleCount = observed
        finiteUncappedMeanDB = finite == 0 ? nil : finiteSum.value
        referencePresentationMeanDB = available == 0 ? nil : presentationSum.value
        isCancelled = regions.contains { $0.isCancelled }
        if isCancelled {
            unavailability = .cancelled
        } else if unity > 0 {
            unavailability = .unsupportedRange
        } else if available > 0 {
            unavailability = nil
        } else if timeline.plan.source.sampleCount == 0 {
            unavailability = .insufficientData
        } else if timeline.coverage.eligibleSampleCount == 0 {
            unavailability = .missingAcquisition
        } else if timeline.coverage.selectedSampleCount == 0 {
            unavailability = .excluded
        } else {
            unavailability = regions.compactMap(\.unavailability).first ?? .insufficientData
        }
    }

    public func measurementResult() throws -> MeasurementResult {
        let outcome: MeasurementOutcome
        if let meanDB {
            var warnings: [MeasurementWarning] = []
            if observedSampleCount != timeline.plan.source.sampleCount {
                warnings.append(.partialCoverage)
            }
            if lowConfidenceFrameCount > 0 { warnings.append(.lowConfidence) }
            if clippedFrameCount > 0 { warnings.append(.clipping) }
            outcome = .available(try ScalarEstimate(value: meanDB, warnings: warnings))
        } else {
            outcome = .unavailable(unavailability ?? .analysisFailure)
        }
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .harmonicToNoiseRatio, unit: .decibelsRatio,
                algorithm: identity.identifier), profile: identity,
            timing: AnalysisTiming(
                source: timeline.plan.source, includedSampleCount: observedSampleCount,
                effectiveDelaySeconds: max(
                    timeline.plan.source.durationSeconds / 2,
                    timeline.plan.effectiveDelaySeconds)), outcome: outcome)
    }

    /// Maps each scheduler continuity region back to acquisition coordinates before
    /// aggregation. Stream completions are deliberately not offline region means.
    public init(
        profile: HNRStatisticProfile, timeline: MaskTimeline,
        scheduledRegions: [AnalysisScheduleCompletion]
    ) throws {
        let regions = try scheduledRegions.map { completion in
            guard let native = completion.hnrInterval, completion.hnrStream == nil else {
                throw HNRError.unexpectedContext
            }
            let source = try completion.origin.sourceInterval(for: native.source)
            guard source == completion.observedSource else { throw HNRError.unexpectedContext }
            return HNRCompletion(
                profile: native.profile, source: source,
                completeGridFrameCount: native.completeGridFrameCount,
                emittedSlotCount: native.emittedSlotCount,
                availableFrameCount: native.availableFrameCount,
                unavailableFrameCount: native.unavailableFrameCount,
                finiteDecibelFrameCount: native.finiteDecibelFrameCount,
                reportingLimitFrameCount: native.reportingLimitFrameCount,
                numericalZeroNoiseFrameCount: native.numericalZeroNoiseFrameCount,
                lowConfidenceFrameCount: native.lowConfidenceFrameCount,
                clippedFrameCount: native.clippedFrameCount,
                observedSampleCount: native.observedSampleCount,
                finiteUncappedMeanDB: native.finiteUncappedMeanDB,
                referencePresentationMeanDB: native.referencePresentationMeanDB,
                isCancelled: completion.isCancelled || native.isCancelled,
                unavailability: completion.isCancelled ? .cancelled : native.unavailability)
        }
        try self.init(profile: profile, timeline: timeline, regions: regions)
    }
}
