import HDXLVoiceProcessing

/// A scalar's nominal plot position may differ from the source that contributed to it.
/// Offsets are relative to an integer sample anchor, including for fractional query centers.
public struct AcousticMetricObservation: Sendable, Hashable {
    public let measurement: VisualizationMeasurement
    public let dependency: SourceInterval
    public let anchorSample: Int64
    public let secondsFromAnchor: Double
    public let context: [String]

    public init(_ measurement: VisualizationMeasurement) {
        let support = measurement.result.timing.source
        self.measurement = measurement
        dependency = measurement.scheduled?.dependencyTiming.source ?? support
        if let export = measurement.scheduled {
            anchorSample = export.origin.source.startSample
            secondsFromAnchor = export.frameCenterSecondsFromOrigin
        } else {
            anchorSample = support.startSample
            secondsFromAnchor = support.durationSeconds / 2
        }
        if let export = measurement.scheduled, let mask = export.mask {
            let coverage = export.dependencyCoverage
            context = [
                "Mask \(mask.planIdentity.identifier.name) · \(mask.scope.rawValue)",
                "Eligible \(coverage.eligible) · selected \(coverage.selected) · missing \(coverage.missing) samples",
                "Speech-tagged \(coverage.samples(tag: .speechDetected)) · non-speech \(coverage.samples(tag: .nonSpeechDetected)) samples",
            ]
        } else {
            context = []
        }
    }

    public init(_ result: MeasurementResult) { self.init(VisualizationMeasurement(result)) }

    private init(
        _ result: MeasurementResult, anchor: SourceInterval, offset: Double,
        dependency: SourceInterval? = nil, context: [String] = []
    ) {
        measurement = VisualizationMeasurement(result)
        self.dependency = dependency ?? result.timing.source
        anchorSample = anchor.startSample
        secondsFromAnchor = offset
        self.context = context
    }

    public init(_ frame: YINFrameResult) throws {
        self.init(
            try frame.measurementResult(), anchor: frame.timing.source,
            offset: frame.timing.source.durationSeconds / 2,
            context: ["Pitch status · \(frame.status.rawValue)"])
    }

    public init(_ frame: LevelWindowResult, kind: MeasurementKind, unit: MeasurementUnit) throws {
        self.init(
            try frame.measurementResult(kind: kind, unit: unit), anchor: frame.source,
            offset: frame.source.durationSeconds / 2,
            context: [
                "Window \(frame.configuration.windowLength) samples · hop \(frame.configuration.hopLength) samples"
            ])
    }

    public init(_ frame: CPPFrameResult) throws {
        self.init(
            try frame.measurementResult(), anchor: frame.context.origin,
            offset: frame.context.centerSecondsFromOrigin)
    }

    public init(_ frame: CPPSFrameResult) throws {
        self.init(
            try frame.measurementResult(), anchor: frame.context.origin,
            offset: frame.context.centerSecondsFromOrigin,
            context: [
                "Estimator smoothing · \(frame.temporalSupportFrameCount) contributing frames"
            ])
    }

    public init(_ frame: HNRFrameResult) throws {
        self.init(
            try frame.measurementResult(), anchor: frame.dependencyTiming.source,
            offset: frame.centerSecondsFromNormalizationOrigin,
            context: [
                "Analysis window · samples \(frame.frameTiming.source.startSample)..<\(frame.frameTiming.source.endSample)"
            ])
    }

    public init(_ result: JitterAnalysisResult, variant: JitterVariant) throws {
        let coverage = result.coverage
        let query = result.query
        let aligned = result.sampleAlignedQuery
        self.init(
            try result.measurementResult(variant),
            anchor: aligned ?? result.dependencyTiming.source,
            offset: aligned.map { $0.durationSeconds / 2 } ?? query.centerSeconds,
            context: [
                result.applicability == .sustainedPhonation
                    ? "Sustained phonation" : "Exploratory rolling estimate",
                "Query \(query.startSeconds)…\(query.endSeconds) s from dependency start",
                "Accepted periods \(coverage.acceptedPeriodCount) / \(coverage.selectedPeriodCount) selected",
                "Eligible period pairs \(coverage.acceptedPairCount) / \(coverage.candidatePairCount)",
                "RAP neighborhoods \(coverage.acceptedRAPNeighborhoodCount) / \(coverage.candidateRAPNeighborhoodCount) · PPQ5 \(coverage.acceptedPPQ5NeighborhoodCount) / \(coverage.candidatePPQ5NeighborhoodCount)",
            ])
    }

    public init(_ result: ShimmerAnalysisResult, variant: ShimmerVariant) throws {
        let coverage = result.coverage
        let query = result.query
        let aligned = result.sampleAlignedQuery
        self.init(
            try result.measurementResult(variant),
            anchor: aligned ?? result.dependencyTiming.source,
            offset: aligned.map { $0.durationSeconds / 2 } ?? query.centerSeconds,
            context: [
                result.applicability == .sustainedPhonation
                    ? "Sustained phonation" : "Exploratory rolling estimate",
                "Query \(query.startSeconds)…\(query.endSeconds) s from dependency start",
                "Accepted amplitudes \(coverage.acceptedAmplitudeCount) / \(coverage.selectedAmplitudeCount) selected",
                "Eligible amplitude pairs \(coverage.acceptedPairCount) / \(coverage.candidatePairCount)",
                "APQ3 neighborhoods \(coverage.acceptedAPQ3NeighborhoodCount) / \(coverage.candidateAPQ3NeighborhoodCount) · APQ5 \(coverage.acceptedAPQ5NeighborhoodCount) / \(coverage.candidateAPQ5NeighborhoodCount) · APQ11 \(coverage.acceptedAPQ11NeighborhoodCount) / \(coverage.candidateAPQ11NeighborhoodCount)",
            ])
    }

    public init?(_ result: SpectralShapeResult, descriptor: SpectralShapeDescriptor) throws {
        guard let scalar = try result.measurement(descriptor) else { return nil }
        self.init(scalar)
    }

    public init(_ frame: BurgFormantFrame, number: Int, kind: MeasurementKind) throws {
        let scalar = try frame.measurement(number: number, kind: kind)
        self.init(
            scalar.result, anchor: frame.conditioningSupport, offset: frame.centerSecondsFromOrigin,
            dependency: scalar.conditioningSupport,
            context: ["F\(number) · Burg LPC"] + frame.cautions.map(\.rawValue))
    }

    public init(_ frame: RawHarmonicFrame) {
        let window = frame.measurement.timing.source
        self.init(
            frame.measurement, anchor: window, offset: window.durationSeconds / 2,
            dependency: frame.dependencySupport, context: frame.failure.map { [$0.rawValue] } ?? [])
    }

    public init(_ frame: CorrectedHarmonicFrame) {
        let window = frame.raw.measurement.timing.source
        self.init(
            frame.measurement, anchor: window, offset: window.durationSeconds / 2,
            dependency: frame.dependencySupport, context: frame.failure.map { [$0.rawValue] } ?? [])
    }

    func seconds(on axis: VisualizationTimeAxis) throws -> Double {
        guard axis.source.contains(dependency),
            axis.source.contains(measurement.result.timing.source)
        else {
            throw VisualizationError.incompatibleSource
        }
        let seconds =
            Double(anchorSample - axis.originSample) / axis.source.sampleRate + secondsFromAnchor
        guard seconds.isFinite else { throw VisualizationError.nonfiniteDisplayValue }
        return seconds
    }
}
