import Foundation

/// Independent raw estimator for mono PCM and an explicit F0 observation.
public final class PreparedHarmonicFit<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: HarmonicFitProfile
    public let identity: ProfileIdentity
    private let rawDescriptor: MeasurementDescriptor
    private let diagnostics: WorkerDiagnostics
    private var fitSequence: UInt64 = 0
    private var correctionSequence: UInt64 = 0

    public init(
        _ configuration: HarmonicFitProfile,
        diagnosticMode: RuntimeDiagnosticMode = .disabled
    ) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw ConditioningError.precisionMismatch }
        self.configuration = configuration
        identity = try configuration.identity()
        rawDescriptor = try HarmonicFitProfile.descriptor
        diagnostics = WorkerDiagnostics(mode: diagnosticMode.facadeMode)
    }

    func measured<T>(_ stage: DiagnosticStage, source: SourceInterval, _ body: () throws -> T)
        rethrows -> T
    {
        var metadata = DiagnosticMetadata()
        if stage == .harmonicCorrection {
            metadata.frameSequence = correctionSequence
            correctionSequence = saturatingAdd(correctionSequence)
        } else {
            metadata.frameSequence = fitSequence
            fitSequence = saturatingAdd(fitSequence)
        }
        metadata.profileToken = 5201
        metadata.sampleCount = UInt32(source.sampleCount)
        return try diagnostics.withFrame(metadata, stage: stage, body)
    }

    /// Pass the PCM of the pitch observation's source window. The fit uses a centered
    /// subset of that window. A maximum of 250 ms of PCM is accepted per call.
    public func fit(
        _ pcm: UnsafeBufferPointer<Sample>, source: SourceInterval, pitch: MeasurementResult?
    ) throws
        -> RawHarmonicFrame
    {
        let recipe = configuration
        guard source.sampleRate == Double(recipe.sourceSampleRate),
            source.sampleCount == Int64(pcm.count)
        else { throw ConditioningError.unexpectedInterval }
        guard pcm.count <= recipe.sourceSampleRate / 4 else {
            throw ConditioningError.capacityExceeded
        }
        return try measured(.harmonicFit, source: source) {
            let evidence = pitch.map(HarmonicPitchObservation.init)
            var window = source
            var fit: HarmonicRegression?
            var failure: HarmonicFailure?
            var clipped = false
            do {
                guard let pitch else { throw HarmonicFailure.missingPitch }
                guard pitch.measurement.kind == .fundamentalFrequency,
                    pitch.measurement.unit == .hertz,
                    pitch.measurement.algorithm == recipe.pitchAlgorithm
                else { throw HarmonicFailure.wrongPitchMeasurement }
                guard pitch.profile == recipe.pitchProfile else {
                    throw HarmonicFailure.wrongPitchProfile
                }
                guard pitch.timing.source == source else {
                    throw HarmonicFailure.pitchSupportMismatch
                }
                guard let obs = pitch.outcome.estimate else {
                    throw HarmonicFailure.missingPitchEstimate
                }
                guard pitch.timing.includedSampleCount == source.sampleCount, obs.warnings.isEmpty
                else { throw HarmonicFailure.uncertainPitch }
                let f0 = obs.value
                guard (50...5000).contains(f0) else { throw HarmonicFailure.pitchOutOfRange }
                guard 2 * f0 < recipe.declaredBandwidthHz else {
                    throw HarmonicFailure.harmonicOutsideBandwidth
                }
                let length = Int((Double(recipe.periods) * source.sampleRate / f0).rounded())
                guard length >= 12, length <= pcm.count else { throw HarmonicFailure.shortWindow }
                let offset = (pcm.count - length) / 2
                window = try SourceInterval(
                    epoch: source.epoch, startSample: source.startSample + Int64(offset),
                    sampleCount: Int64(length), sampleRate: source.sampleRate)
                let view = UnsafeBufferPointer(rebasing: pcm[offset..<(offset + length)])
                for sample in pcm {
                    guard sample.isFinite else { throw HarmonicFailure.nonfinitePCM }
                    if abs(sample) >= 1 { clipped = true }
                }
                let result = try HarmonicRegression.fit(
                    view, rate: recipe.sourceSampleRate, frequency: f0)
                fit = result
                switch (result.first, result.second) {
                case (nil, nil): throw HarmonicFailure.bothHarmonicsUnresolved
                case (nil, _): throw HarmonicFailure.firstHarmonicUnresolved
                case (_, nil): throw HarmonicFailure.secondHarmonicUnresolved
                default: break
                }
            } catch let issue as HarmonicFailure {
                failure = issue
            }
            let matched = pitch?.timing.source == source ? pitch?.timing : nil
            let offset = Double(window.startSample - source.startSample) / source.sampleRate
            let center = offset + window.durationSeconds / 2
            let delay = max(
                source.durationSeconds - center,
                (matched?.effectiveDelaySeconds ?? 0) + source.durationSeconds / 2 - center)
            let hostStart = try matched?.hostStartNanoseconds.map { anchor in
                let (projected, overflow) = anchor.addingReportingOverflow(
                    UInt64((offset * 1e9).rounded()))
                guard !overflow else { throw ContractError.invalidTiming }
                return projected
            }
            let timing = try AnalysisTiming(
                source: window, includedSampleCount: fit == nil ? 0 : window.sampleCount,
                sourceStartSeconds: matched?.sourceStartSeconds.map { $0 + offset },
                hostStartNanoseconds: hostStart,
                effectiveDelaySeconds: delay)
            let outcome: MeasurementOutcome
            if failure == .missingPitchEstimate, let upstream = pitch?.outcome {
                outcome = upstream
            } else if let failure {
                outcome = .unavailable(failure.reason)
            } else if let first = fit?.first, let second = fit?.second {
                outcome = .available(
                    try ScalarEstimate(
                        value: first.peakDBFS - second.peakDBFS,
                        warnings: clipped ? [.clipping] : []))
            } else {
                throw ContractError.invalidValue
            }
            return try RawHarmonicFrame(
                configuration: recipe, pitch: evidence, dependencySupport: source,
                measurement: MeasurementResult(
                    measurement: rawDescriptor, profile: identity, timing: timing,
                    outcome: outcome), first: fit?.first, second: fit?.second,
                failure: failure, clipped: clipped,
                relativeResidualRMS: fit?.residual, relativeDetectionFloor: fit?.detectionFloor
            )
        }
    }

}
