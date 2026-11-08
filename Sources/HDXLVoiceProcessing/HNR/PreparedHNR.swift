import Foundation

/// Single-owner synchronous frame analyzer. Prepare on a worker, never in the
/// capture callback. Valid calls reuse fixed buffers; no input pointer is retained.
public final class PreparedHNR<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: HNRConfiguration
    public let identity: ProfileIdentity
    private let correlation: PreparedHNRCorrelation
    private let windowed: UnsafeMutableBufferPointer<Double>
    private let forward: UnsafeMutableBufferPointer<Double>
    private let candidates: UnsafeMutableBufferPointer<HNRPeakCandidate>
    private let retained: UnsafeMutableBufferPointer<Int>
    private var candidateCount = 0
    private var retainedCount = 0
    private var busy = false
    private var analyzedFrames: UInt64 = 0
    private let diagnostics: WorkerDiagnostics

    public var executionStatistics: HNRExecutionStatistics {
        HNRExecutionStatistics(
            preparedBufferBytes: correlation.scalarWorkspaceBytes
                + (windowed.count + forward.count) * MemoryLayout<Double>.stride
                + candidates.count * MemoryLayout<HNRPeakCandidate>.stride
                + retained.count * MemoryLayout<Int>.stride,
            transformLength: correlation.transformLength, analyzedFrameCount: analyzedFrames,
            directlyRecomputedEnergyLagCount: correlation.directEnergyLagCount)
    }
    public convenience init(_ configuration: HNRConfiguration) throws {
        try self.init(configuration, diagnostics: WorkerDiagnostics())
    }
    package init(_ configuration: HNRConfiguration, diagnostics: WorkerDiagnostics) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw HNRError.precisionMismatch }
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.diagnostics = diagnostics
        self.correlation = try PreparedHNRCorrelation(configuration, diagnostics: diagnostics)
        windowed = .allocate(capacity: configuration.windowSampleCount)
        windowed.initialize(repeating: 0)
        forward = .allocate(
            capacity: configuration.method == .forwardCrossCorrelation
                ? configuration.windowSampleCount + configuration.maximumCandidateLag : 0)
        forward.initialize(repeating: 0)
        candidates = .allocate(
            capacity: min(configuration.maximumCandidateLag, configuration.maximumCorrelationLag))
        retained = .allocate(capacity: configuration.retainedCandidateCapacity)
        retained.initialize(repeating: 0)
    }
    deinit {
        windowed.deinitialize()
        windowed.deallocate()
        forward.deinitialize()
        forward.deallocate()
        candidates.baseAddress?.deinitialize(count: candidateCount)
        candidates.deallocate()
        retained.deinitialize()
        retained.deallocate()
    }

    /// Input contains exactly layout.support, with offsets relative to the entire
    /// normalization interval. The reference must describe that complete interval.
    /// Layout and profile identity are validated before touching scratch state.
    public func analyze(
        _ input: UnsafeBufferPointer<Sample>, layout: HNRFrameLayout,
        normalization: HNRNormalization, emit: (BorrowedHNROutput) -> Void
    ) throws {
        guard !busy else { throw HNRError.reentrantCall }
        guard layout.configuration == configuration,
            normalization.definition == configuration.normalization,
            normalization.inputPrecision == configuration.inputPrecision,
            normalization.timing.source.sampleCount == Int64(layout.intervalSampleCount),
            normalization.timing.source.sampleRate == Double(configuration.sampleRate)
        else { throw HNRError.unexpectedContext }
        guard input.count == layout.support.count else { throw HNRError.invalidBufferSize }
        for value in input where !value.isFinite { throw HNRError.invalidInput }
        let timing = try frameTiming(layout: layout, reference: normalization.timing)
        let dependency = try AnalysisTiming(
            source: normalization.timing.source,
            includedSampleCount: normalization.timing.includedSampleCount,
            sourceStartSeconds: normalization.timing.sourceStartSeconds,
            hostStartNanoseconds: normalization.timing.hostStartNanoseconds,
            completedHostNanoseconds: normalization.timing.completedHostNanoseconds,
            effectiveDelaySeconds: max(
                normalization.timing.effectiveDelaySeconds,
                normalization.timing.source.durationSeconds / 2))
        let center =
            (normalization.timing.sourceStartSeconds
                ?? Double(normalization.timing.source.startSample)
                / Double(configuration.sampleRate))
            + layout.centerSecondsFromOrigin
        guard center.isFinite else { throw HNRError.unexpectedContext }
        busy = true
        defer { busy = false }
        candidates.baseAddress?.deinitialize(count: candidateCount)
        candidateCount = 0
        retainedCount = 0
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 39
        metadata.frameSequence = UInt64(layout.frameIndex)
        metadata.sampleCount = UInt32(input.count)
        metadata.validity = .available
        let summary = try diagnostics.withFrame(metadata) {
            try diagnostics.withInterval(.hnr) {
                try compute(input, layout: layout, reference: normalization)
            }
        }
        analyzedFrames = saturatingAdd(analyzedFrames)
        let result = HNRFrameResult(
            profile: identity, frameIndex: UInt64(layout.frameIndex), frameTiming: timing,
            dependencyTiming: dependency, centerSecondsFromOrigin: layout.centerSecondsFromOrigin,
            centerSourceSeconds: center, strongestCandidateIndex: summary.strongest,
            selectedCandidateIndex: summary.selected,
            strongestObservation: summary.strongest.flatMap { candidates[$0].estimate },
            selectedObservation: summary.selected.flatMap { candidates[$0].estimate },
            unavailability: summary.reason, frameAmplitudeScale: summary.scale,
            scaledLocalMean: summary.mean, scaledLocalPeak: summary.peak,
            relativeIntensity: summary.intensity, unvoicedStrength: summary.unvoiced,
            hasClipping: summary.clipping, layout: layout)
        emit(
            BorrowedHNROutput(
                result: result,
                candidates: UnsafeBufferPointer(
                    start: candidates.baseAddress, count: candidateCount),
                scaledWindowedSamples: UnsafeBufferPointer(windowed),
                correlation: UnsafeBufferPointer(
                    start: correlation.curve.baseAddress,
                    count: summary.hasCurve ? correlation.curve.count : 0),
                correlationValidity: UnsafeBufferPointer(
                    start: correlation.valid.baseAddress,
                    count: summary.hasCurve ? correlation.valid.count : 0),
                windowCorrelation: UnsafeBufferPointer(correlation.windowCorrelation),
                signalCorrelation: UnsafeBufferPointer(
                    start: correlation.signalCorrelation.baseAddress,
                    count: summary.hasCurve ? correlation.signalCorrelation.count : 0)))
    }

    private struct Summary {
        var scale = 0.0
        var mean = 0.0
        var peak = 0.0
        var intensity = 0.0
        var unvoiced = 0.0
        var clipping = false
        var hasCurve = false
        var strongest: Int?
        var selected: Int?
        var reason: UnavailabilityReason?
    }
    private func compute(
        _ input: UnsafeBufferPointer<Sample>, layout: HNRFrameLayout,
        reference: HNRNormalization
    ) throws -> Summary {
        let c = configuration
        var summary = Summary()
        for value in input {
            summary.scale = max(summary.scale, abs(Double(value)))
            if abs(value) >= 1 { summary.clipping = true }
        }
        guard summary.scale <= reference.amplitudeScale else { throw HNRError.unexpectedContext }
        func centered(_ index: Int) -> Double {
            (summary.scale == 0
                ? 0 : Double(input[index - layout.support.lowerBound]) / summary.scale)
                - summary.mean
        }
        var sum = HNRSum()
        if summary.scale > 0 {
            for i in layout.localMeanStartSample..<layout.localMeanStartSample
                + c.localMeanSampleCount
            {
                sum.add(Double(input[i - layout.support.lowerBound]) / summary.scale)
            }
        }
        summary.mean = sum.value / Double(c.localMeanSampleCount)
        for i in windowed.indices {
            windowed[i] = centered(layout.centeredWindowStartSample + i) * correlation.window[i]
        }
        let half = c.windowSampleCount / 2
        let halfPeriod = c.localMeanSampleCount / 4 + 1
        for i in max(0, half - halfPeriod)..<min(c.windowSampleCount, half + halfPeriod) {
            summary.peak = max(summary.peak, abs(windowed[i]))
        }
        if reference.amplitudeScale > 0, reference.scaledMeanRemovedPeak > 0 {
            let relativeScale = summary.scale / reference.amplitudeScale
            summary.intensity = min(
                1, summary.peak * relativeScale / reference.scaledMeanRemovedPeak)
        }
        guard summary.intensity.isFinite else { throw HNRError.numericalFailure }
        summary.unvoiced =
            c.silenceThreshold == 0 ? 0 : max(0, 2 - summary.intensity / c.silenceThreshold)
        guard reference.scaledMeanRemovedPeak > 0, summary.peak > 0 else {
            summary.reason = .silence
            return summary
        }
        if c.method == .autocorrelation {
            try correlation.compute(
                UnsafeBufferPointer(windowed), maximumLag: c.maximumCorrelationLag)
        } else {
            let count = c.windowSampleCount + layout.computedMaximumLag
            for i in 0..<count { forward[i] = centered(layout.correlationStartSample + i) }
            try correlation.compute(
                UnsafeBufferPointer(start: forward.baseAddress, count: count),
                maximumLag: layout.computedMaximumLag)
        }
        summary.hasCurve = true
        try searchCandidates()
        var bestStrength = 0.0
        for i in 0..<candidateCount {
            if let estimate = candidates[i].estimate, let hz = candidates[i].frequencyHz,
                hz > 0, hz < Double(c.sampleRate) / 2, estimate.periodicity > bestStrength
            {
                summary.strongest = i
                bestStrength = estimate.periodicity
            }
        }
        if bestStrength > summary.unvoiced { summary.selected = summary.strongest }
        if summary.selected == nil {
            summary.reason = summary.strongest == nil ? .lowConfidence : .silence
        }
        return summary
    }

    private func searchCandidates() throws {
        let curve = UnsafeBufferPointer(correlation.curve)
        let valid = UnsafeBufferPointer(correlation.valid)
        let end = min(configuration.maximumCandidateLag, configuration.maximumCorrelationLag)
        if end > 2 {
            for lag in 2..<end {
                guard valid[lag - 1], valid[lag], valid[lag + 1] else { continue }
                let left = curve[lag - 1]
                let middle = curve[lag]
                let right = curve[lag + 1]
                let kind = HNRNumerics.peakKind(left: left, middle: middle, right: right)
                guard kind != .notLocalMaximum else { continue }
                let curvature = (middle - left) + (middle - right)
                var candidate = HNRPeakCandidate(
                    integerLag: lag, curvature: curvature,
                    disposition: kind == .numericallyFlat ? .numericallyFlat : .invalidInterpolation
                )
                if kind == .resolved {
                    let initial = Double(lag) + (right - left) / 2 / curvature
                    candidate.initialPeriodSamples = initial
                    if let strength = HNRNumerics.sinc(
                        curve, valid: valid, position: initial, depth: 30)
                    {
                        candidate.initialPeriodicity = strength > 1 ? 1 / strength : strength
                        candidate.disposition = .discardedByCapacity
                    }
                }
                candidates.baseAddress!.advanced(by: candidateCount).initialize(to: candidate)
                if let strength = candidate.initialPeriodicity {
                    if retainedCount < retained.count {
                        retained[retainedCount] = candidateCount
                        retainedCount += 1
                        candidates[candidateCount].disposition = .retained
                    } else {
                        var weakest = 0
                        for slot in 1..<retainedCount {
                            let a = candidates[retained[slot]]
                            let b = candidates[retained[weakest]]
                            if a.initialPeriodicity! < b.initialPeriodicity!
                                || (a.initialPeriodicity == b.initialPeriodicity
                                    && a.integerLag > b.integerLag)
                            {
                                weakest = slot
                            }
                        }
                        if strength > candidates[retained[weakest]].initialPeriodicity! {
                            candidates[retained[weakest]].disposition = .discardedByCapacity
                            retained[weakest] = candidateCount
                            candidates[candidateCount].disposition = .retained
                        }
                    }
                }
                candidateCount += 1
            }
        }
        for i in 0..<candidateCount where candidates[i].disposition == .retained {
            guard
                let maximum = HNRNumerics.maximum(
                    curve, valid: valid, integerLag: candidates[i].integerLag)
            else {
                candidates[i].disposition = .invalidInterpolation
                continue
            }
            guard maximum.correlation > 0 else {
                candidates[i].disposition = .nonpositiveRefinement
                continue
            }
            candidates[i].periodSamples = maximum.lag
            candidates[i].frequencyHz = Double(configuration.sampleRate) / maximum.lag
            candidates[i].estimate = try HNRPeriodicityEstimate(
                unreflectedCorrelation: maximum.correlation)
        }
    }

    private func frameTiming(layout: HNRFrameLayout, reference: AnalysisTiming) throws
        -> AnalysisTiming
    {
        let rate = Double(configuration.sampleRate)
        let start = Int64(layout.support.lowerBound)
        let source = try SourceInterval(
            epoch: reference.source.epoch,
            startSample: reference.source.startSample + start,
            sampleCount: Int64(layout.support.count), sampleRate: rate)
        let seconds = Double(start) / rate
        let host: UInt64?
        if let anchor = reference.hostStartNanoseconds {
            let offset = seconds * 1e9
            guard offset.isFinite, offset >= 0, offset < Double(UInt64.max) else {
                throw HNRError.unexpectedContext
            }
            let addition = anchor.addingReportingOverflow(UInt64(offset.rounded()))
            guard !addition.overflow else { throw HNRError.unexpectedContext }
            host = addition.partialValue
        } else {
            host = nil
        }
        let delay = reference.source.durationSeconds - (seconds + source.durationSeconds / 2)
        return try AnalysisTiming(
            source: source, includedSampleCount: source.sampleCount,
            sourceStartSeconds: reference.sourceStartSeconds.map { $0 + seconds },
            hostStartNanoseconds: host,
            completedHostNanoseconds: reference.completedHostNanoseconds,
            effectiveDelaySeconds: max(reference.effectiveDelaySeconds, max(0, delay)))
    }
}
