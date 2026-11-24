import Foundation
import HDXLVoiceProcessing

extension AlgorithmInspection {
    public static func harmonicity(
        _ output: BorrowedHNROutput, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        let r = output.result
        let recipe = r.layout.configuration
        guard output.candidates.count <= limits.maximumSegments
        else { throw VisualizationError.capacityExceeded }
        let isAC = recipe.method == .autocorrelation
        var curves: [InspectionCurve] = []
        var i = 0
        var undefined = 0
        var remainingScalars = limits.maximumFrameScalars
        while i < output.correlation.count {
            guard output.correlationValidity[i] else {
                undefined += 1
                i += 1
                continue
            }
            let start = i
            let padding = !isAC && start > r.layout.computedMaximumLag
            repeat {
                i += 1
            } while i < output.correlation.count && output.correlationValidity[i]
                && (isAC || padding == (i > r.layout.computedMaximumLag))
            guard curves.count < limits.maximumSegments, i - start <= remainingScalars else {
                throw VisualizationError.capacityExceeded
            }
            remainingScalars -= i - start
            let curve = try IntermediateSnapshot(
                stage: .init(
                    name: padding ? "hnr-interpolation-padding" : "hnr-valid-correlation",
                    version: 1),
                source: r.frameTiming.source, xUnit: .samples, yUnit: .dimensionless,
                xOrigin: Double(start), xStep: 1, values: Array(output.correlation[start..<i]))
            curves.append(
                .init(
                    curve,
                    explanation:
                        padding
                        ? "Zero extension used by the interpolator beyond the last computed lag."
                        : "Normalized correlation for consecutive measured lags. Peaks indicate repeating periods."
                ))
        }
        var fields: [InspectionField] = [
            .init("Undefined correlation lags", String(undefined)),
            .init("Relative frame intensity", String(r.relativeIntensity)),
        ]
        for (i, candidate) in output.candidates.enumerated() {
            var details = [candidate.disposition.rawValue]
            if let hz = candidate.frequencyHz { details.append("\(hz) Hz") }
            if let period = candidate.periodSamples { details.append("\(period) samples") }
            if i == r.strongestCandidateIndex { details.append("strongest") }
            if i == r.selectedCandidateIndex { details.append("selected") }
            fields.append(
                .init(
                    "Candidate at lag \(candidate.integerLag) samples",
                    details.joined(separator: " · ")))
        }
        if let observation = r.selectedObservation {
            fields.append(
                .init("Periodicity", "\(observation.periodicity) · \(observation.status.rawValue)"))
        }
        let measurement = try r.measurementResult()
        return try Self(
            title: isAC ? "Autocorrelation and harmonicity" : "Cross-correlation and harmonicity",
            explanation:
                "Compare the waveform with delayed copies and use the selected periodicity to estimate the ratio of periodic to remaining energy.",
            reference: URL(
                string: isAC
                    ? "https://praat.org/manual/Sound__To_Harmonicity__ac____.html"
                    : "https://praat.org/manual/Sound__To_Harmonicity__cc____.html")!,
            context: context, window: r.frameTiming.source, dependency: r.dependencyTiming.source,
            profile: r.profile, parameters: parameters(recipe),
            status: availability(measurement.outcome),
            measurements: [measurement], fields: fields, curves: curves, limits: limits)
    }

    public static func harmonicity(
        _ output: BorrowedHNRAnalysisOutput, recipe: HNRConfiguration, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        switch output {
        case .frame(let frame):
            guard frame.result.layout.configuration == recipe else {
                throw VisualizationError.incompatibleSeries
            }
            return try harmonicity(frame, context: context, limits: limits)
        case .unavailable(let frame):
            try requireProfile(recipe.identity(), frame.profile)
            let ac = recipe.method == .autocorrelation
            return try Self(
                title: ac ? "Autocorrelation and harmonicity" : "Cross-correlation and harmonicity",
                explanation: "This source interval could not supply an eligible harmonicity frame.",
                reference: URL(
                    string: ac
                        ? "https://praat.org/manual/Sound__To_Harmonicity__ac____.html"
                        : "https://praat.org/manual/Sound__To_Harmonicity__cc____.html")!,
                context: context, window: frame.timing.source, dependency: frame.timing.source,
                profile: frame.profile,
                parameters: parameters(recipe), status: status(frame.reason),
                measurements: [frame.measurementResult()], limits: limits)
        }
    }

    public static func pulses(
        _ snapshot: PulseSnapshot, recipe: PulseConfiguration, context: InspectionContext,
        limits: VisualizationLimits = .standard
    ) throws -> Self {
        let r = snapshot.result
        try requireProfile(recipe.identity(), r.profile)
        var remaining = limits.maximumSegments
        for count in [
            snapshot.landmarks.count, snapshot.attempts.count, snapshot.periods.count,
            snapshot.periodPairs.count, snapshot.amplitudes.count,
        ] {
            guard count <= remaining else { throw VisualizationError.capacityExceeded }
            remaining -= count
        }
        var fields: [InspectionField] = [
            .init("F0 contour", r.f0ContourIdentity.sha256),
            .init("Eligible pulses", "\(r.eligiblePulseCount) of \(r.rawPulseCount)"),
            .init(
                "Eligible periods and adjacent pairs",
                "\(r.eligiblePeriodCount) periods · \(r.eligiblePairCount) pairs"),
        ]
        if let f0 = r.f0SourceProfile { fields.append(.init("F0 source profile", f0.sha256)) }
        for item in snapshot.landmarks {
            fields.append(
                .init(
                    "Pulse \(item.index)",
                    "\(item.timeSeconds) s · " + pulseStatus(item.isEligible, item.rejections)))
        }
        for item in snapshot.attempts {
            fields.append(
                .init(
                    "Tracking attempt \(item.index)",
                    "\(item.proposedSeconds) s · \(item.direction.rawValue) · "
                        + pulseStatus(item.acceptedByReferenceGates, item.rejections)))
        }
        for item in snapshot.periods {
            fields.append(
                .init(
                    "Period \(item.index) · pulses \(item.leftPulseIndex)–\(item.rightPulseIndex)",
                    "\(item.durationSeconds) s · " + pulseStatus(item.isEligible, item.rejections)))
        }
        for item in snapshot.periodPairs {
            fields.append(
                .init(
                    "Adjacent periods \(item.leftPeriodIndex)–\(item.rightPeriodIndex)",
                    "Ratio \(item.ratio) · " + pulseStatus(item.isEligible, item.rejections)))
        }
        for item in snapshot.amplitudes {
            let level = item.rmsAmplitude.map { "\($0) FS RMS" } ?? "No RMS amplitude"
            fields.append(
                .init(
                    "Cycle amplitude at pulse \(item.pulseIndex)",
                    level + " · " + pulseStatus(item.isEligible, item.rejections)))
        }
        return try Self(
            title: "Pulses and eligible cycles",
            explanation:
                "Track matching waveform landmarks within voiced intervals. The time between neighbors gives a period. Rejection flags preserve the reason a cycle or pair was excluded.",
            reference: URL(
                string: "https://praat.org/manual/Sound___Pitch__To_PointProcess__cc_.html")!,
            context: context, window: r.timing.source, dependency: r.timing.source,
            profile: r.profile,
            parameters: parameters(recipe), status: status(r.unavailability), fields: fields,
            unavailability: r.unavailability, limits: limits)
    }

    private static func pulseStatus(_ eligible: Bool, _ flags: PulseRejections) -> String {
        let reasons: [(PulseRejections, String)] = [
            (.outsideAcquisition, "outside acquisition"),
            (.outsideVoicedInterval, "outside voiced interval"),
            (.insufficientSupport, "insufficient support"), (.silence, "silence"),
            (.degenerateWaveform, "degenerate waveform"),
            (.illConditionedPeak, "ill-conditioned peak"), (.numericalFailure, "numerical failure"),
            (.excludedSupport, "excluded support"), (.trackingFailure, "tracking failure"),
            (.differentRun, "different run"),
            (.periodBelowMinimum, "period below minimum"),
            (.periodAboveMaximum, "period above maximum"),
            (.adjacentPeriodFactor, "adjacent period ratio"),
            (.insufficientCycles, "insufficient cycles"),
            (.lowCorrelation, "low correlation"), (.lowAmplitude, "low amplitude"),
            (.priorIntervalCollision, "prior interval collision"),
            (.rangeFallback, "range fallback"),
        ]
        return
            ([eligible ? "accepted" : "rejected"]
            + reasons.compactMap { flags.contains($0.0) ? $0.1 : nil }).joined(separator: " · ")
    }
}
