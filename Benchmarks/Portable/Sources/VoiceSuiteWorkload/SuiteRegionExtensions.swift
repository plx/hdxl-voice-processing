import HDXLVoiceProcessing

final class SuiteRegionExtensions<S: BinaryFloatingPoint & Sendable> {
    let diagnostics: RuntimeDiagnosticMode
    let recipe: SuiteRecipe.Extensions
    let spectrum: PreparedSpectrogram<S>
    let secondSpectrum: PreparedSpectrogram<S>?
    let accumulator: LongTermSpectrumAccumulator
    let shape, aggregateShape: PreparedSpectralShape
    let mask: PreparedLTSFDetector<S>

    init(
        _ recipe: SuiteRecipe.Extensions, source: SourceInterval, separateSpectra: Bool,
        diagnostics: RuntimeDiagnosticMode
    ) throws {
        self.recipe = recipe
        self.diagnostics = diagnostics
        spectrum = try .init(
            layout: recipe.layout, epoch: source.epoch, diagnosticMode: diagnostics)
        secondSpectrum =
            separateSpectra
            ? try .init(layout: recipe.layout, epoch: source.epoch, diagnosticMode: diagnostics)
            : nil
        accumulator = try .init(
            layout: recipe.layout, epoch: source.epoch, diagnosticMode: diagnostics)
        shape = try .init(
            layout: recipe.layout, configuration: recipe.frameShape, diagnosticMode: diagnostics)
        aggregateShape = try .init(
            layout: recipe.layout, configuration: recipe.aggregateShape, diagnosticMode: diagnostics
        )
        mask = try .init(configuration: recipe.mask, source: source, diagnosticMode: diagnostics)
    }

    private func spectralRows(
        base: Int64, result: inout SuiteResult,
        _ emit: (PreparedSpectrogram<S>, (BorrowedSpectrogramFrame<S>) -> Void) throws -> Void
    ) throws {
        var failure: (any Error)?
        try emit(spectrum) { row in
            guard failure == nil else { return }
            do {
                result.spectralRows += 1
                let at = base + row.info.source.startSample
                result.conformance?.spectra["spectrogram", default: .init()].append(
                    row.binPower, at: at, status: row.info.status)
                result.spectralVerification?.spectrogram.append(
                    row.binPower, at: at, status: row.info.status)
                result.record(
                    "spectrogram", power: row.binPower.first.map(Double.init),
                    status: row.info.status, at: at)
                try recordShape(shape.evaluate(row), prefix: "frame", at: at, result: &result)
                if secondSpectrum == nil {
                    result.spectralVerification?.accumulationInput.append(
                        row.binPower, at: at, status: row.info.status)
                    try accumulator.append(row)
                }
            } catch { failure = error }
        }
        if let secondSpectrum {
            try emit(secondSpectrum) { row in
                guard failure == nil else { return }
                do {
                    result.spectralRows += 1
                    result.spectralVerification?.accumulationInput.append(
                        row.binPower, at: base + row.info.source.startSample,
                        status: row.info.status)
                    try accumulator.append(row)
                } catch { failure = error }
            }
        }
        if let failure { throw failure }
    }

    private func recordShape(
        _ shape: SpectralShapeResult, prefix: String, at: Int64,
        result: inout SuiteResult
    ) throws {
        for descriptor in SpectralShapeDescriptor.allCases {
            if let entry = shape[descriptor] {
                let key = prefix + "." + descriptor.rawValue
                try result.conformance?.register(entry.measurement.unit, for: key)
                result.record(key, outcome: entry.outcome, at: at)
            }
        }
    }

    func process(
        _ pcm: UnsafeBufferPointer<S>, interval: SourceInterval, base: Int64,
        result: inout SuiteResult
    ) throws {
        _ = try mask.append(pcm, interval: interval)
        try spectralRows(base: base, result: &result) { worker, emit in
            _ = try worker.process(pcm, interval: interval, emit: emit)
        }
    }

    func finish(
        _ pcm: UnsafeBufferPointer<S>, source: SourceInterval, pitches: [YINFrameResult],
        base: Int64, result: inout SuiteResult
    ) throws {
        try spectralRows(base: base, result: &result) { worker, emit in
            _ = try worker.finish(emit: emit)
        }
        let mean = try accumulator.snapshot(observedSource: source)
        result.conformance?.spectra["ltas", default: .init()].append(
            mean.meanBinPower, at: base, status: mean.status)
        result.spectralVerification?.longTermSpectrum.append(
            mean.meanBinPower, at: base, status: mean.status)
        result.record("ltas", power: mean.meanBinPower.first, status: mean.status, at: base)
        try recordShape(aggregateShape.evaluate(mean), prefix: "ltas", at: base, result: &result)
        _ = try mask.finish { output in
            if output.flatness.isEmpty {
                result.record("ltsf", nil, at: base, reason: output.unavailability)
            }
            for (index, value) in output.flatness.enumerated() {
                let center =
                    output.layout.firstCenterSeconds! + Double(index) * recipe.mask.hopSeconds
                result.record(
                    "ltsf", value, at: base + Int64((center * source.sampleRate).rounded()))
            }
            if output.speechIntervals.isEmpty {
                result.record("speechInterval", nil, at: base, reason: output.unavailability)
            }
            for region in output.speechIntervals {
                let at = base + Int64((region.startSeconds * source.sampleRate).rounded())
                result.record("speechInterval", region.isSpeech ? 1 : 0, at: at)
            }
        }
        try measurePitchDependents(
            pcm, pitches: pitches, source: source, base: base, result: &result)
    }

    private func measurePitchDependents(
        _ pcm: UnsafeBufferPointer<S>, pitches: [YINFrameResult],
        source: SourceInterval, base: Int64, result: inout SuiteResult
    ) throws {
        let full = pitches.filter { $0.timing.source.sampleCount == $0.requiredSampleCount }
        let harmonic = try PreparedHarmonicDifference<S>(
            recipe.harmonics, diagnosticMode: diagnostics)
        var burg: PreparedBurgFormants<S>?
        for pitch in pitches {
            let span = pitch.timing.source
            let at = base + span.startSample
            guard span.sampleCount == pitch.requiredSampleCount else {
                for number in 1...recipe.harmonics.formants.maximumFormants {
                    result.record(
                        "formant" + String(number), nil, at: at, reason: .insufficientData)
                    result.record(
                        "bandwidth" + String(number), nil, at: at, reason: .insufficientData)
                }
                result.record("h1h2", nil, at: at, reason: .insufficientData)
                result.record("correctedH1H2", nil, at: at, reason: .insufficientData)
                continue
            }
            if burg == nil {
                burg = try .init(
                    configuration: recipe.harmonics.formants, source: span,
                    diagnosticMode: diagnostics)
            }
            let samples = UnsafeBufferPointer(
                rebasing: pcm[Int(span.startSample)..<Int(span.endSample)])
            let f0 = try pitch.measurementResult()
            let evidence =
                try f0.outcome.estimate?.warnings.isEmpty == true
                ? FormantPitchEvidence(measurement: f0) : nil
            try burg!.analyze(
                samples, source: span, pitch: { _ in evidence },
                emit: { formants in
                    result.maximumRootSweeps = max(
                        result.maximumRootSweeps, formants.diagnostics.rootSweeps)
                    if formants.diagnostics.triedSecondStart { result.secondRootStarts += 1 }
                    for number in 1...recipe.harmonics.formants.maximumFormants {
                        let frequency = try formants.measurement(
                            number: number, kind: .formantFrequency
                        ).result
                        let bandwidth = try formants.measurement(
                            number: number, kind: .formantBandwidth
                        ).result
                        try result.conformance?.register(
                            frequency.measurement.unit, for: "formant" + String(number))
                        try result.conformance?.register(
                            bandwidth.measurement.unit, for: "bandwidth" + String(number))
                        result.record(
                            "formant" + String(number), outcome: frequency.outcome,
                            at: base + frequency.timing.source.startSample)
                        result.record(
                            "bandwidth" + String(number), outcome: bandwidth.outcome,
                            at: base + bandwidth.timing.source.startSample)
                    }
                    let output = try harmonic.analyze(
                        samples, source: span, pitch: f0, formants: formants)
                    let raw = output.raw.measurement
                    try result.conformance?.register(raw.measurement.unit, for: "h1h2")
                    try result.conformance?.register(
                        output.measurement.measurement.unit, for: "correctedH1H2")
                    result.record(
                        "h1h2", outcome: raw.outcome, at: base + raw.timing.source.startSample)
                    result.record(
                        "correctedH1H2", outcome: output.measurement.outcome,
                        at: base + output.measurement.timing.source.startSample)
                })
        }
        guard let first = full.first else {
            result.omittedPulseRegions += 1
            for lane in Self.pulseLanes {
                result.record(lane, nil, at: base, reason: .insufficientData)
            }
            return
        }
        let rate = source.sampleRate
        let hop = Int(rate) / 100
        let frequencies = full.map { frame in
            guard frame.status == .voiced, let hz = frame.observation?.frequencyHz,
                hz < recipe.pulses.pitchCeilingHz
            else { return 0.0 }
            return hz
        }
        let contour = try PulseF0Contour(
            sampleRate: Int(rate), sampleCount: pcm.count,
            firstCenterSeconds: Double(first.requiredSampleCount) / (2 * rate),
            stepSeconds: Double(hop) / rate, ceilingHz: recipe.pulses.pitchCeilingHz,
            frequenciesHz: frequencies, sourceProfile: first.profile)
        let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        let jitter = try PreparedPCMJitter<S>(
            configuration: recipe.jitter, pulseConfiguration: recipe.pulses,
            maximumSampleCount: pcm.count, maximumF0FrameCount: full.count,
            maximumTrackingAttempts: recipe.maximumTrackingAttempts, diagnosticMode: diagnostics)
        var jitterCoverage: JitterCoverage?
        try jitter.analyze(pcm, contour: contour, timing: timing) { output in
            result.pulseTrackingAttempts += output.pulses.result.trackingAttemptCount
            result.record(
                "pulses",
                output.pulses.result.unavailability == nil
                    ? Double(output.pulses.landmarks.count) : nil, at: base,
                reason: output.pulses.result.unavailability)
            if result.conformance != nil {
                for point in output.pulses.landmarks {
                    guard
                        !point.isEligible
                            || (point.timeSeconds >= 0
                                && point.timeSeconds <= source.durationSeconds)
                    else { throw SuiteError.mismatch("Eligible pulse outside its observed epoch") }
                    result.conformance?.landmarks.append(
                        SuitePulsePoint(
                            epoch: source.epoch.sequence, sourceStart: base, index: point.index,
                            voicedInterval: point.voicedIntervalID, timeSeconds: point.timeSeconds,
                            run: point.runID, eligible: point.isEligible))
                }
            }
            let value = output.result
            jitterCoverage = value.coverage
            for estimate in [value.local, value.absolute, value.rap, value.ppq5, value.ddp] {
                try result.conformance?.register(
                    estimate.unit, for: "jitter." + estimate.variant.rawValue)
                result.record(
                    "jitter." + estimate.variant.rawValue, estimate.value, at: base,
                    status: estimate.status.rawValue, reason: estimate.unavailability)
            }
        }
        guard let jitterCoverage else { throw SuiteError.mismatch("Missing jitter coverage") }
        let shimmer = try PreparedPCMShimmer<S>(
            configuration: recipe.shimmer, pulseConfiguration: recipe.pulses,
            maximumSampleCount: pcm.count, maximumF0FrameCount: full.count,
            maximumTrackingAttempts: recipe.maximumTrackingAttempts, diagnosticMode: diagnostics)
        try shimmer.analyze(pcm, contour: contour, timing: timing) { output in
            if result.conformance != nil {
                for amplitude in output.pulses.amplitudes {
                    result.conformance?.cycleAmplitudes.append(
                        SuiteCycleAmplitude(
                            epoch: source.epoch.sequence, sourceStart: base,
                            pulse: amplitude.pulseIndex,
                            rms: amplitude.rmsAmplitude,
                            supportStartSeconds: amplitude.supportStartSeconds,
                            supportEndSeconds: amplitude.supportEndSeconds,
                            observedSamples: amplitude.observedSampleCount,
                            rejections: amplitude.rejections, eligible: amplitude.isEligible))
                }
            }
            result.pulseTrackingAttempts += output.pulses.result.trackingAttemptCount
            let value = output.result
            result.perturbationCoverage.append(
                .init(startSample: base, jitter: jitterCoverage, shimmer: value.coverage))
            for estimate in [value.local, value.db, value.apq3, value.apq5, value.apq11, value.dda]
            {
                try result.conformance?.register(
                    estimate.unit, for: "shimmer." + estimate.variant.rawValue)
                result.record(
                    "shimmer." + estimate.variant.rawValue, estimate.value, at: base,
                    status: estimate.status.rawValue, reason: estimate.unavailability)
            }
        }
    }

    static var pulseLanes: [String] {
        ["pulses"] + JitterVariant.allCases.map { "jitter." + $0.rawValue }
            + ShimmerVariant.allCases.map { "shimmer." + $0.rawValue }
    }
}
