import HDXLVoiceProcessing

/// Original perturbation eligibility and exact relative query. Rolling analysis can also
/// supply a half-open, sample-aligned interval on the acquisition clock.
public enum AcousticPerturbationContext: Sendable, Hashable {
    case jitter(JitterQueryRange, JitterCoverage, JitterApplicability, JitterInputProvenance)
    case shimmer(ShimmerQueryRange, ShimmerCoverage, ShimmerApplicability, ShimmerInputProvenance)

    var bounds: ClosedRange<Double> {
        switch self {
        case .jitter(let query, _, _, _): query.startSeconds...query.endSeconds
        case .shimmer(let query, _, _, _): query.startSeconds...query.endSeconds
        }
    }

    var upstreamProfiles: [(String, ProfileIdentity)] {
        let items: [(String, ProfileIdentity?)]
        switch self {
        case .jitter(_, _, _, let input):
            items = [
                ("Period source", input.periodSourceProfile),
                ("F0 contour", input.f0ContourIdentity),
                ("F0 source", input.f0SourceProfile),
            ]
        case .shimmer(_, _, _, let input):
            items = [
                ("Amplitude source", input.amplitudeSourceProfile),
                ("F0 contour", input.f0ContourIdentity),
                ("F0 source", input.f0SourceProfile),
            ]
        }
        return items.compactMap { label, identity in identity.map { (label, $0) } }
    }

    var provenanceText: [String] {
        let kind: String
        switch self {
        case .jitter(_, _, _, let input):
            kind = input.kind == .acousticPulses ? "Acoustic pulse track" : "Supplied periods"
        case .shimmer(_, _, _, let input):
            kind = input.kind == .acousticPulses ? "Acoustic pulse track" : "Supplied amplitudes"
        }
        return ["Input · " + kind]
            + upstreamProfiles.map { label, profile in
                "\(label) · \(profile.identifier.name) v\(profile.identifier.version) · \(profile.sha256)"
            }
    }

}

/// A scalar's nominal plot position may differ from the source that contributed to it.
/// Offsets are relative to an integer sample anchor, including for fractional query centers.
public struct AcousticMetricObservation: Sendable, Hashable {
    public let measurement: VisualizationMeasurement
    public let observationWindow: SourceInterval
    public let dependency: SourceInterval
    let midpointSupport: SourceInterval?
    public let anchorSample: Int64
    public let secondsFromAnchor: Double
    public let context: [String]
    public let perturbation: AcousticPerturbationContext?
    public let sampleAlignedQuery: SourceInterval?

    public init(_ measurement: VisualizationMeasurement) {
        let support = measurement.result.timing.source
        self.measurement = measurement
        observationWindow = measurement.scheduled?.observationWindow ?? support
        perturbation = nil
        sampleAlignedQuery = nil
        dependency =
            measurement.result.measurement.kind == .kWeightedEnergy
            ? measurement.scheduled?.dependencyTiming.source ?? support : support
        if let export = measurement.scheduled {
            midpointSupport = export.centerIsWindowMidpoint ? export.observationWindow : nil
            anchorSample = export.origin.source.startSample
            secondsFromAnchor = export.frameCenterSecondsFromOrigin
        } else {
            midpointSupport = support
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
        _ result: MeasurementResult, anchor: SourceInterval, offset: Double? = nil,
        observationWindow: SourceInterval? = nil, dependency: SourceInterval? = nil,
        perturbation: AcousticPerturbationContext? = nil,
        sampleAlignedQuery: SourceInterval? = nil, context: [String] = []
    ) {
        measurement = VisualizationMeasurement(result)
        self.observationWindow = observationWindow ?? result.timing.source
        self.dependency = dependency ?? result.timing.source
        anchorSample = anchor.startSample
        midpointSupport = offset == nil ? anchor : nil
        secondsFromAnchor = offset ?? anchor.durationSeconds / 2
        self.perturbation = perturbation
        self.sampleAlignedQuery = sampleAlignedQuery
        self.context = context
    }

    public init(_ frame: YINFrameResult) throws {
        self.init(
            try frame.measurementResult(), anchor: frame.timing.source,
            context: ["Pitch status · \(frame.status.rawValue)"])
    }

    public init(_ frame: LevelWindowResult, kind: MeasurementKind, unit: MeasurementUnit) throws {
        self.init(
            try frame.measurementResult(kind: kind, unit: unit), anchor: frame.source,
            dependency: kind == .kWeightedEnergy ? frame.filterHistorySource : nil,
            context: [
                "Window \(frame.configuration.windowLength) samples · hop \(frame.configuration.hopLength) samples"
            ])
    }

    public init(_ frame: CPPFrameResult) throws {
        self.init(
            try frame.measurementResult(), anchor: frame.context.origin,
            offset: frame.context.centerSecondsFromOrigin,
            observationWindow: try frame.observationWindow)
    }

    public init(_ frame: CPPSFrameResult) throws {
        self.init(
            try frame.measurementResult(), anchor: frame.context.origin,
            offset: frame.context.centerSecondsFromOrigin,
            observationWindow: try frame.rawCPP.observationWindow,
            context: [
                "Estimator smoothing · \(frame.temporalSupportFrameCount) contributing frames"
            ])
    }

    public init(_ frame: HNRFrameResult) throws {
        self.init(
            try frame.measurementResult(), anchor: frame.dependencyTiming.source,
            offset: frame.centerSecondsFromNormalizationOrigin,
            observationWindow: frame.frameTiming.source,
            context: [
                "Analysis window · samples \(frame.frameTiming.source.startSample)..<\(frame.frameTiming.source.endSample)"
            ])
    }

    public init(_ result: JitterAnalysisResult, variant: JitterVariant) throws {
        let coverage = result.coverage
        let query = result.query
        let aligned = result.sampleAlignedQuery
        let provenance = AcousticPerturbationContext.jitter(
            query, coverage, result.applicability, result.inputProvenance)
        self.init(
            try result.measurementResult(variant),
            anchor: aligned ?? result.dependencyTiming.source,
            offset: aligned == nil ? query.centerSeconds : nil,
            perturbation: provenance,
            sampleAlignedQuery: aligned,
            context: [
                result.applicability == .sustainedPhonation
                    ? "Sustained phonation" : "Exploratory rolling estimate",
                "Query \(query.startSeconds)…\(query.endSeconds) s from dependency start",
                "Accepted periods \(coverage.acceptedPeriodCount) / \(coverage.selectedPeriodCount) selected",
                "Eligible period pairs \(coverage.acceptedPairCount) / \(coverage.candidatePairCount)",
                "RAP neighborhoods \(coverage.acceptedRAPNeighborhoodCount) / \(coverage.candidateRAPNeighborhoodCount) · PPQ5 \(coverage.acceptedPPQ5NeighborhoodCount) / \(coverage.candidatePPQ5NeighborhoodCount)",
            ] + provenance.provenanceText)
    }

    public init(_ result: ShimmerAnalysisResult, variant: ShimmerVariant) throws {
        let coverage = result.coverage
        let query = result.query
        let aligned = result.sampleAlignedQuery
        let provenance = AcousticPerturbationContext.shimmer(
            query, coverage, result.applicability, result.inputProvenance)
        self.init(
            try result.measurementResult(variant),
            anchor: aligned ?? result.dependencyTiming.source,
            offset: aligned == nil ? query.centerSeconds : nil,
            perturbation: provenance,
            sampleAlignedQuery: aligned,
            context: [
                result.applicability == .sustainedPhonation
                    ? "Sustained phonation" : "Exploratory rolling estimate",
                "Query \(query.startSeconds)…\(query.endSeconds) s from dependency start",
                "Accepted amplitudes \(coverage.acceptedAmplitudeCount) / \(coverage.selectedAmplitudeCount) selected",
                "Eligible amplitude pairs \(coverage.acceptedPairCount) / \(coverage.candidatePairCount)",
                "APQ3 neighborhoods \(coverage.acceptedAPQ3NeighborhoodCount) / \(coverage.candidateAPQ3NeighborhoodCount) · APQ5 \(coverage.acceptedAPQ5NeighborhoodCount) / \(coverage.candidateAPQ5NeighborhoodCount) · APQ11 \(coverage.acceptedAPQ11NeighborhoodCount) / \(coverage.candidateAPQ11NeighborhoodCount)",
            ] + provenance.provenanceText)
    }

    public init?(_ result: SpectralShapeResult, descriptor: SpectralShapeDescriptor) throws {
        guard let scalar = try result.measurement(descriptor) else { return nil }
        let config = result.configuration
        func band(_ band: SpectralFrequencyBand) -> String { "\(band.lowerHz)–\(band.upperHz) Hz" }
        var fields = [
            "Source · " + (config.source == .frame ? "Spectrum frame" : "Long-term spectrum"),
            "Analysis band · " + band(config.analysisBand)
                + (config.includeDC ? " · DC included" : " · DC excluded"),
            "Shape weighting · " + (config.weighting == .power ? "Power" : "Bin RMS magnitude"),
        ]
        switch descriptor {
        case .rollOff: fields.append("Cumulative weight fraction · \(config.rollOffFraction)")
        case .bandEnergyRatio:
            let ratio = config.bandRatio
            fields += [
                "Band ratio · \(ratio.name.name) v\(ratio.name.version)",
                "Numerator · " + band(ratio.numerator), "Denominator · " + band(ratio.denominator),
            ]
        case .slope:
            fields += [
                "Fit band · " + band(config.fitBand),
                "Fit coordinate · " + (config.fitCoordinate == .hertz ? "Hz" : "Octaves from 1 Hz"),
                "Regression weights · "
                    + (config.regressionWeighting == .uniform ? "Uniform" : "Shape weights"),
                "Minimum fit bins · \(config.minimumFitBins)",
            ]
        default: break
        }
        if descriptor == .slope || descriptor == .flatness {
            fields.append(
                "Relative log floor · " + (config.relativeLogFloorDB.map { "\($0) dB" } ?? "None"))
        }
        self.init(scalar, anchor: scalar.timing.source, context: fields)
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
            frame.measurement, anchor: window,
            dependency: frame.dependencySupport, context: frame.failure.map { [$0.rawValue] } ?? [])
    }

    public init(_ frame: CorrectedHarmonicFrame) {
        let window = frame.raw.measurement.timing.source
        self.init(
            frame.measurement, anchor: window,
            dependency: frame.dependencySupport, context: frame.failure.map { [$0.rawValue] } ?? [])
    }

    func intersects(_ selection: VisualizationSelection) -> Bool {
        guard let perturbation else {
            return selection.intersects(observationWindow)
        }
        if let sampleAlignedQuery { return selection.intersects(sampleAlignedQuery) }
        let source = selection.source
        guard VisualizationSource(dependency).contains(source) else { return false }
        let bounds = perturbation.bounds
        let start = Double(source.startSample - dependency.startSample) / source.sampleRate
        if source.sampleCount == 0 { return bounds.contains(start) }
        let end = Double(source.endSample - dependency.startSample) / source.sampleRate
        return start <= bounds.upperBound && end > bounds.lowerBound
    }

    func seconds(on axis: VisualizationTimeAxis) throws -> Double {
        guard axis.source.contains(dependency),
            axis.source.contains(measurement.result.timing.source)
        else {
            throw VisualizationError.incompatibleSource
        }
        if measurement.scheduled == nil, let midpointSupport {
            return try axis.placement(of: midpointSupport).centerSeconds
        }
        let seconds =
            Double(anchorSample - axis.originSample) / axis.source.sampleRate + secondsFromAnchor
        guard seconds.isFinite else { throw VisualizationError.nonfiniteDisplayValue }
        return seconds
    }
}
