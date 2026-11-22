import Foundation

/// Bounded reference-style analysis of a complete mono interval. Emit callbacks receive owned,
/// independent frames. Reuse the plan for other intervals with the same length and sample rate.
public final class PreparedBurgFormants<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: BurgFormantProfile
    public let identity: ProfileIdentity
    public let layout: IntervalConditioningLayout
    public let frameCount: Int
    public let firstCenterSeconds: Double?
    private let conditioner: PreparedIntervalConditioner<Double>
    private let conversion: CepstralInputConversion
    private let burg: FormantBurgWorkspace
    private let diagnostics: WorkerDiagnostics
    private var busy = false
    private var diagnosticSequence: UInt64 = 0
    private var lastBinding: (pitch: ProfileIdentity, matched: Bool, result: ProfileIdentity)?

    public convenience init(
        configuration: BurgFormantProfile, source: SourceInterval,
        diagnosticMode: RuntimeDiagnosticMode = .disabled
    ) throws {
        try self.init(
            configuration: configuration, source: source,
            diagnostics: WorkerDiagnostics(mode: diagnosticMode.facadeMode))
    }
    package init(
        configuration: BurgFormantProfile, source: SourceInterval, diagnostics: WorkerDiagnostics
    ) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw ConditioningError.precisionMismatch }
        conditioner = try PreparedIntervalConditioner(
            configuration: configuration.conditioning, source: source, diagnostics: diagnostics)
        layout = conditioner.layout
        self.configuration = configuration
        self.diagnostics = diagnostics
        identity = try configuration.identity()
        conversion = CepstralInputConversion(precision: configuration.inputPrecision)
        let rate = Double(configuration.analysisSampleRate)
        let step = 1 / rate
        // Praat compares the caller’s duration in seconds before quantizing its support.
        let width = BurgFormantProfile.physicalWindowSeconds
        let duration = Double(layout.outputSampleCount) * step
        let count =
            layout.outputSampleCount < configuration.windowSamples
            ? 0 : max(1, Int(floor((duration - width) / configuration.hopSeconds)) + 1)
        frameCount = count
        // Center the sequence on the analysis sample centers. A fused subtraction preserves
        // the side of a half-sample boundary on the pinned Praat frame grid.
        let span = Double(layout.outputSampleCount - 1) * step
        firstCenterSeconds =
            count == 0
            ? nil
            : layout.firstOutputCenterSeconds
                + 0.5 * span.addingProduct(-Double(count - 1), configuration.hopSeconds)
        let window = try PreparedWindow<Double>(
            WindowSpecification(
                definition: configuration.window,
                sampleCount: configuration.windowSamples, sampleRate: rate))
        burg = FormantBurgWorkspace(
            weights: window.coefficientSnapshot(), order: configuration.order)
    }

    /// The pitch callback receives the frame's original sample support. An unmatched observation is flagged.
    /// A too-short interval emits one explicitly unavailable frame. Callback or input errors permit reuse.
    public func analyze(
        _ samples: UnsafeBufferPointer<Sample>, source: SourceInterval,
        pitch: (SourceInterval) -> FormantPitchEvidence? = { _ in nil },
        emit: (BurgFormantFrame) throws -> Void
    ) throws {
        guard !busy else { throw ConditioningError.reentrantCall }
        guard source.sampleRate == Double(configuration.sourceSampleRate),
            samples.count == layout.inputSampleCount,
            source.sampleCount == Int64(samples.count)
        else { throw ConditioningError.unexpectedInterval }
        guard samples.allSatisfy(\.isFinite) else { throw ConditioningError.nonfiniteInput }
        busy = true
        defer { busy = false }
        try conditioner.reset(source: source)
        _ = try conversion.consume(samples, interval: source) { x, interval in
            try conditioner.append(x, interval: interval)
            return x.count
        }
        var reported: (any Error)?
        try conditioner.finish { conditioned, _ in
            do {
                for i in 0..<max(1, frameCount) {
                    var metadata = DiagnosticMetadata()
                    metadata.frameSequence = diagnosticSequence
                    diagnosticSequence &+= 1
                    metadata.profileToken = 4601
                    metadata.sampleCount = UInt32(
                        min(configuration.windowSamples, conditioned.count))
                    let frame = try diagnostics.withFrame(metadata, stage: .burgFormants) {
                        try makeFrame(
                            index: i, input: conditioned, source: source,
                            original: samples, pitch: pitch)
                    }
                    try emit(frame)
                }
            } catch { reported = error }
        }
        if let reported { throw reported }
    }

    private func makeFrame(
        index: Int, input: UnsafeBufferPointer<Double>, source: SourceInterval,
        original: UnsafeBufferPointer<Sample>, pitch: (SourceInterval) -> FormantPitchEvidence?
    ) throws -> BurgFormantFrame {
        let rate = Double(configuration.analysisSampleRate)
        let step = 1 / rate
        let center =
            firstCenterSeconds?.addingProduct(Double(index), configuration.hopSeconds) ?? source
            .durationSeconds / 2
        let length = configuration.windowSamples
        let left = Int(floor((center - layout.firstOutputCenterSeconds) / step)) + 1 - length / 2
        let start = max(0, min(left, input.count))
        let end = max(start, min(left + length, input.count))
        let support =
            frameCount == 0 ? source : try sourceWindow(start..<end, in: source)
        let timing = try AnalysisTiming(
            source: support, includedSampleCount: support.sampleCount,
            effectiveDelaySeconds: max(0, source.durationSeconds - center))
        let observation = pitch(support)
        var failure: FormantFitFailure? =
            frameCount == 0 || end - start != length ? .shortWindow : nil
        if failure == nil {
            let lo = Int(support.startSample - source.startSample)
            let hi = Int(support.endSample - source.startSample)
            let observed = original[lo..<hi]
            if let first = observed.first, observed.allSatisfy({ $0 == first }) {
                failure = first == 0 ? .silent : .constant
            }
        }
        var fit: FormantBurgFit?
        var solution: FormantRootSolution?
        if failure == nil {
            switch diagnostics.withInterval(
                .burgLPC, { burg.fit(UnsafeBufferPointer(rebasing: input[start..<end])) })
            {
            case .success(let value): fit = value
            case .failure(let reason): failure = reason
            }
        }
        if let fit {
            solution = diagnostics.withInterval(.formantRoots) {
                FormantPolynomial(coefficients: fit.coefficients).solve()
            }
            if solution?.converged != true { failure = .rootNonconvergence }
        }
        let selection = diagnostics.withInterval(.formantSelection) {
            FormantSelection(
                roots: solution?.roots ?? [], profile: configuration, gainDB: fit?.predictionGainDB,
                source: support, pitch: observation)
        }
        let bound = try frameIdentity(observation, support: support)
        return BurgFormantFrame(
            configuration: configuration, profile: bound, timing: timing,
            conditioningSupport: source,
            centerSecondsFromOrigin: center, index: index, pitch: observation,
            diagnostics: .init(fit: fit, solution: solution),
            failure: failure, cautions: selection.cautions, candidates: selection.candidates)
    }

    private func sourceWindow(_ samples: Range<Int>, in source: SourceInterval) throws
        -> SourceInterval
    {
        let analysisRate = Int64(configuration.analysisSampleRate)
        let inputRate = Int64(configuration.sourceSampleRate)
        let denominator = 2 * analysisRate
        // Center M analysis cells on N source cells. Edge j in source samples is
        // [N * analysisRate + (2j - M) * inputRate] / (2 * analysisRate).
        // Clamp before division so an exact cell boundary never acquires a neighbor by rounding.
        func edgeNumerator(_ index: Int) -> Int64 {
            let offset = (2 * Int64(index) - Int64(layout.outputSampleCount)) * inputRate
            let numerator = source.sampleCount * analysisRate + offset
            return min(source.sampleCount * denominator, max(0, numerator))
        }
        let first = edgeNumerator(samples.lowerBound) / denominator
        let end = (edgeNumerator(samples.upperBound) + denominator - 1) / denominator
        return try SourceInterval(
            epoch: source.epoch, startSample: source.startSample + first,
            sampleCount: end - first, sampleRate: source.sampleRate)
    }

    private func frameIdentity(_ observation: FormantPitchEvidence?, support: SourceInterval) throws
        -> ProfileIdentity
    {
        guard let observation else { return identity }
        let matched = observation.source == support
        if let lastBinding, lastBinding.pitch == observation.profile, lastBinding.matched == matched
        {
            return lastBinding.result
        }
        let result = try BurgFormantProfile.bind(
            identity, to: observation.profile, matched: matched)
        lastBinding = (observation.profile, matched, result)
        return result
    }
}
