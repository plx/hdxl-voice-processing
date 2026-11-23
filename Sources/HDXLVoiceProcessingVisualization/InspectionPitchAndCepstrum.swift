import Foundation
import HDXLVoiceProcessing

extension AlgorithmInspection {
    /// Export raw candidates in estimator order, including the accepted index, the
    /// global fallback and local dips outside the configured frequency range.
    public static func pitch(
        _ output: BorrowedYINOutput, recipe: YINConfiguration, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        let result = output.result
        try requireProfile(recipe.identity(), result.profile)
        guard output.candidates.count <= limits.maximumSegments else {
            throw VisualizationError.capacityExceeded
        }
        let snapshots = try output.export(
            stages: Set(YINIntermediate.allCases),
            policy: .init(maximumScalarCount: limits.maximumFrameScalars))
        let curves = snapshots.map {
            InspectionCurve(
                $0,
                explanation: $0.stage.name == "yin-scaledSquaredDifference"
                    ? "Compare the waveform with a delayed copy. Smaller squared differences indicate a closer match."
                    : "Divide each difference by the mean through that lag. Dips mark possible periods."
            )
        }
        var fields = [InspectionField("Observation", result.status.rawValue)]
        for (index, candidate) in output.candidates.enumerated() {
            var flags: [String] = []
            if index == result.selectedCandidateIndex { flags.append("selected") }
            if candidate.isLocalMinimum { flags.append("local minimum") }
            if candidate.isGlobalMinimum { flags.append("global minimum") }
            flags.append(candidate.isInRange ? "in range" : "outside range")
            flags.append(candidate.isThresholdQualified ? "meets threshold" : "above threshold")
            fields.append(
                .init(
                    "Candidate \(index) · lag \(candidate.integerLag) samples",
                    "\(candidate.frequencyHz) Hz · \(candidate.periodSamples) samples · normalized error \(candidate.normalizedError) · "
                        + flags.joined(separator: ", ")))
        }
        return try Self(
            title: "Pitch candidates",
            explanation:
                "YIN compares repetition at different lags. The estimator refines the period of a candidate and converts it to frequency.",
            reference: URL(string: "https://doi.org/10.1121/1.1458024")!, context: context,
            window: result.timing.source, dependency: result.timing.source, profile: result.profile,
            parameters: parameters(recipe), status: status(result.unavailability),
            measurements: [result.measurementResult()], fields: fields, curves: curves,
            limits: limits)
    }

    /// Pass the upstream view from the same nested callback to inspect the exact
    /// conditioned/windowed PCM, spectrum and cepstrum consumed by this fit.
    public static func cpp(
        _ output: BorrowedCPPOutput, recipe: CPPProfile,
        upstream: BorrowedPowerCepstrum<Double>? = nil,
        context: InspectionContext, limits: VisualizationLimits = .standard
    ) throws -> Self {
        let result = output.result
        try requireProfile(recipe.identity(), result.profile)
        var remaining = limits.maximumFrameScalars
        var curves: [InspectionCurve] = []
        var fields = fitFields(result.observation, layout: result.layout)
        if let upstream {
            try requireProfile(upstream.profile, result.sourceProfile)
            guard upstream.context == result.context else {
                throw VisualizationError.incompatibleSource
            }
            let stages = try upstream.export(
                stages: [.windowed, .powerSpectrum, .logPowerSpectrum, .powerCepstrum],
                policy: .init(maximumScalarCount: remaining))
            for stage in stages {
                if let samples = stage.snapshot {
                    curves.append(.init(samples, explanation: stage.stage.scaling))
                    remaining -= samples.values.count
                }
                if let reason = stage.unavailability {
                    fields.append(
                        .init(
                            stage.stage.rawValue,
                            "\(stage.snapshot?.values.count ?? 0) of \(stage.expectedCount) bins · \(status(reason))"
                        ))
                }
            }
        }
        let fit = try output.export(
            stages: Set(CPPIntermediate.allCases), policy: .init(maximumScalarCount: remaining))
        curves += fit.map { .init($0, explanation: fitExplanation($0.stage.name)) }
        return try Self(
            title: "Cepstral peak prominence",
            explanation:
                "A peak in the power cepstrum marks a repeating pattern in the spectrum. CPP measures the peak height above the fitted background at that quefrency.",
            reference: URL(
                string: "https://praat.org/manual/PowerCepstrum__Get_peak_prominence___.html")!,
            context: context, window: result.observationWindow,
            dependency: result.context.timing.source,
            profile: result.profile, parameters: parameters(recipe),
            status: status(result.unavailability),
            measurements: [result.measurementResult()], fields: fields, curves: curves,
            limits: limits)
    }

    public static func cpps(
        _ output: BorrowedCPPSOutput, recipe: CPPSProfile, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        let result = output.result
        try requireProfile(recipe.identity(), result.profile)
        let snapshots = try output.export(
            stages: Set(CPPSIntermediate.allCases),
            policy: .init(maximumScalarCount: limits.maximumFrameScalars))
        let curves = snapshots.map { frame in
            let explanation: String
            switch frame.stage.name {
            case "cpps-rawPower": explanation = "Original unsmoothed power at this frame center."
            case "cpps-preparedPower":
                explanation = "Input to smoothing after the configured trend preparation."
            case "cpps-timeSmoothedPower":
                explanation = "Power averaged across the contributing time frames."
            case "cpps-smoothedPower":
                explanation = "Power after the configured quefrency and time smoothing."
            default: explanation = fitExplanation(frame.stage.name)
            }
            return InspectionCurve(frame, explanation: explanation)
        }
        let fields =
            fitFields(result.observation, layout: result.rawCPP.layout) + [
                .init("Contributing frames", String(result.temporalSupportFrameCount)),
                .init("Smoothing edge", result.usesSmoothingEdge ? "Yes" : "No"),
                .init("Lookahead", "\(result.lookaheadSeconds) s"),
            ]
        return try Self(
            title: "Smoothed cepstral peak prominence",
            explanation:
                "Average neighboring cepstral values on the configured grids. Fit the background and measure prominence again on the smoothed slice.",
            reference: URL(string: "https://praat.org/manual/PowerCepstrogram__Get_CPPS___.html")!,
            context: context, window: result.rawCPP.observationWindow,
            dependency: result.context.timing.source,
            profile: result.profile, parameters: parameters(recipe),
            status: status(result.unavailability),
            measurements: [result.rawCPP.measurementResult(), result.measurementResult()],
            fields: fields, curves: curves, limits: limits)
    }

    private static func fitExplanation(_ name: String) -> String {
        if name.hasSuffix("backgroundDB") {
            return "Fitted linear background evaluated at each quefrency."
        }
        if name.hasSuffix("residualDB") {
            return "Difference between observed level and fitted background at each bin."
        }
        return "Power on the logarithmic scale used by the peak search and background fit."
    }

    private static func fitFields(_ observation: CPPObservation?, layout: CPPLayout)
        -> [InspectionField]
    {
        var fields: [InspectionField] = [
            .init("Peak search", "\(layout.searchStartSeconds)…\(layout.searchEndSeconds) s"),
            .init(
                "Background fit",
                "\(layout.fitStartSeconds)…\(layout.fitEndSeconds) s · \(layout.fitPointCount) bins"
            ),
        ]
        if let o = observation {
            fields += [
                .init("Selected quefrency", "\(o.peakQuefrencySeconds) s"),
                .init(
                    "Peak and background at selection", "\(o.peakDB) dB and \(o.backgroundDB) dB"),
                .init("Fitted slope", "\(o.slopeDBPerSecond) dB/s"),
                .init("Fitted intercept", "\(o.interceptDB) dB"),
                .init("RMS fit residual", "\(o.residualRMSDB) dB"),
                .init("Search boundary", o.peakIsAtSearchBoundary ? "Yes" : "No"),
                .init("Bidirectional tie rule", o.usedBidirectionalTieRule ? "Used" : "Unused"),
            ]
        }
        return fields
    }
}
