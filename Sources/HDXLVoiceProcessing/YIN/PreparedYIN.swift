import Foundation

/// Single-owner, synchronous frame estimator. Prepare on a worker, never inside
/// the capture callback. Valid calls reuse bounded buffers and do not retain PCM.
/// Every frame is independent; temporal candidate tracking belongs to another layer.
public final class PreparedYIN<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: YINConfiguration
    public let identity: ProfileIdentity
    private let samples: UnsafeMutableBufferPointer<Double>
    private let difference: UnsafeMutableBufferPointer<Double>
    private let cmnd: UnsafeMutableBufferPointer<Double>
    private let candidates: UnsafeMutableBufferPointer<YINCandidate>
    private var candidateCount = 0
    private let reversed: UnsafeMutableBufferPointer<Double>
    private let prefixEnergy: UnsafeMutableBufferPointer<Double>
    private let correlation: UnsafeMutableBufferPointer<Double>
    private let firstSpectrum: UnsafeMutableBufferPointer<FourierBin<Double>>
    private let secondSpectrum: UnsafeMutableBufferPointer<FourierBin<Double>>
    private let transform: PreparedFourierTransform<Double>?
    private let diagnostics: WorkerDiagnostics
    private var busy = false
    private var analyzedFrames: UInt64 = 0
    private var recomputedLags: UInt64 = 0
    private var fallbackFrames: UInt64 = 0

    public var executionStatistics: YINExecutionStatistics {
        YINExecutionStatistics(
            preparedBufferBytes: (samples.count + difference.count + cmnd.count + reversed.count
                + prefixEnergy.count + correlation.count) * MemoryLayout<Double>.stride
                + (firstSpectrum.count + secondSpectrum.count)
                * MemoryLayout<FourierBin<Double>>.stride
                + candidates.count * MemoryLayout<YINCandidate>.stride
                + (transform?.scalarWorkspaceBytes ?? 0),
            fftLength: transform?.configuration.length ?? 0, analyzedFrameCount: analyzedFrames,
            directlyRecomputedLagCount: recomputedLags, scalarFallbackFrameCount: fallbackFrames)
    }

    public convenience init(_ configuration: YINConfiguration) throws {
        try self.init(configuration, diagnostics: WorkerDiagnostics())
    }
    package init(_ configuration: YINConfiguration, diagnostics: WorkerDiagnostics) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw YINError.precisionMismatch }
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.diagnostics = diagnostics
        if configuration.differenceBackend == .fft {
            let n = try FourierConfiguration.lengthPadding(
                configuration.requiredSampleCount + configuration.integrationLength - 1)
            self.transform = try PreparedFourierTransform(
                FourierConfiguration(length: n, sampleRate: Double(configuration.sampleRate)),
                diagnostics: diagnostics)
        } else {
            self.transform = nil
        }
        func allocate(_ count: Int) -> UnsafeMutableBufferPointer<Double> {
            let buffer = UnsafeMutableBufferPointer<Double>.allocate(capacity: count)
            buffer.initialize(repeating: 0)
            return buffer
        }
        samples = allocate(configuration.requiredSampleCount)
        difference = allocate(configuration.maximumEvaluatedLag + 1)
        cmnd = allocate(configuration.maximumEvaluatedLag + 1)
        // Initialize candidates on demand; only candidateCount elements are live.
        candidates = .allocate(capacity: configuration.maximumCandidateCount)
        reversed = allocate(transform == nil ? 0 : configuration.integrationLength)
        prefixEnergy = allocate(transform == nil ? 0 : configuration.requiredSampleCount + 1)
        correlation = allocate(transform?.configuration.length ?? 0)
        let bins = transform?.configuration.realBinCount ?? 0
        firstSpectrum = .allocate(capacity: bins)
        secondSpectrum = .allocate(capacity: bins)
        firstSpectrum.initialize(repeating: FourierBin(real: 0))
        secondSpectrum.initialize(repeating: FourierBin(real: 0))
    }
    deinit {
        for buffer in [samples, difference, cmnd, reversed, prefixEnergy, correlation] {
            buffer.deinitialize()
            buffer.deallocate()
        }
        candidates.baseAddress?.deinitialize(count: candidateCount)
        candidates.deallocate()
        firstSpectrum.deinitialize()
        secondSpectrum.deinitialize()
        firstSpectrum.deallocate()
        secondSpectrum.deallocate()
    }

    /// Context must describe exactly these acquired mono samples. Arbitrary source
    /// and host anchors are preserved. No window padding is accepted as observation.
    public func analyze(
        _ input: UnsafeBufferPointer<Sample>, timing: AnalysisTiming, frameIndex: UInt64 = 0,
        emit: (BorrowedYINOutput) -> Void
    ) throws {
        guard !busy else { throw YINError.reentrantCall }
        guard input.count <= configuration.requiredSampleCount else {
            throw YINError.invalidBufferSize
        }
        guard timing.source.sampleCount == Int64(input.count),
            timing.source.sampleRate == Double(configuration.sampleRate),
            timing.includedSampleCount == timing.source.sampleCount
        else { throw YINError.unexpectedContext }
        for value in input where !value.isFinite { throw YINError.invalidInput }
        let resolvedTiming = try AnalysisTiming(
            source: timing.source, includedSampleCount: timing.includedSampleCount,
            sourceStartSeconds: timing.sourceStartSeconds,
            hostStartNanoseconds: timing.hostStartNanoseconds,
            completedHostNanoseconds: timing.completedHostNanoseconds,
            effectiveDelaySeconds: max(
                timing.effectiveDelaySeconds, configuration.algorithmicDelaySeconds))
        busy = true
        defer { busy = false }
        candidates.baseAddress?.deinitialize(count: candidateCount)
        candidateCount = 0
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 38
        metadata.frameSequence = frameIndex
        metadata.sampleCount = UInt32(input.count)
        metadata.validity = input.count == configuration.requiredSampleCount ? .available : .warmup
        let summary = try diagnostics.withFrame(metadata) {
            try diagnostics.withInterval(.pitch) { try compute(input) }
        }
        let result = YINFrameResult(
            profile: identity, frameIndex: frameIndex, timing: resolvedTiming,
            requiredSampleCount: configuration.requiredSampleCount, status: summary.status,
            observation: summary.selected.map { candidates[$0] },
            selectedCandidateIndex: summary.selected,
            unavailability: summary.reason, normalizationPeak: summary.peak, rms: summary.rms)
        let count = input.count == configuration.requiredSampleCount ? difference.count : 0
        emit(
            BorrowedYINOutput(
                result: result,
                candidates: UnsafeBufferPointer(
                    start: candidates.baseAddress, count: candidateCount),
                difference: UnsafeBufferPointer(start: difference.baseAddress, count: count),
                cmnd: UnsafeBufferPointer(start: cmnd.baseAddress, count: count)))
    }

    private struct Summary {
        var status: YINVoicingStatus
        var selected: Int?
        var reason: UnavailabilityReason?
        var peak: Double?
        var rms: Double?
    }

    private func compute(_ input: UnsafeBufferPointer<Sample>) throws -> Summary {
        guard input.count == samples.count else {
            return Summary(status: .unavailable, reason: .insufficientData)
        }
        var peak = 0.0
        var constant = true
        for value in input {
            peak = max(peak, abs(Double(value)))
            if value != input[0] { constant = false }
        }
        var energy = YINSum()
        for i in input.indices {
            samples[i] = peak == 0 ? 0 : Double(input[i]) / peak
            energy.add(samples[i] * samples[i])
        }
        let rms = peak * sqrt(energy.value / Double(samples.count))
        guard rms.isFinite else { throw YINError.numericalFailure }
        if constant {
            for i in difference.indices { difference[i] = 0 }
        } else if let transform {
            try computeFFT(transform)
        } else {
            computeDirect()
        }
        normalize()
        if !constant, transform != nil, hasAmbiguousLocalDecision() {
            // Close comparisons should not create backend-dependent plateau or
            // threshold classifications. This bounded fallback is separately counted.
            computeDirect()
            normalize()
            fallbackFrames &+= 1
        }
        let selected = selectCandidates()
        analyzedFrames &+= 1
        if rms <= configuration.silenceRMSThreshold {
            return Summary(status: .unvoiced, reason: .silence, peak: peak, rms: rms)
        }
        if constant {
            return Summary(status: .unvoiced, reason: .lowConfidence, peak: peak, rms: rms)
        }
        guard let selected else {
            return Summary(status: .unavailable, reason: .unsupportedRange, peak: peak, rms: rms)
        }
        return Summary(
            status: candidates[selected].isThresholdQualified ? .voiced : .uncertain,
            selected: selected, peak: peak, rms: rms)
    }

    private func directDifference(_ lag: Int) -> Double {
        var sum = YINSum()
        for j in 0..<configuration.integrationLength {
            let delta = samples[j] - samples[j + lag]
            sum.add(delta * delta)
        }
        return sum.value
    }
    private func computeDirect() {
        difference[0] = 0
        for lag in 1..<difference.count { difference[lag] = directDifference(lag) }
    }
    private func computeFFT(_ transform: PreparedFourierTransform<Double>) throws {
        let w = configuration.integrationLength
        // Translate both convolution operands by the reference window's mean.
        // Translation cancels algebraically in (x-c) - (y-c), preserving the
        // YIN definition rather than adding a PCM conditioning step.
        // It avoids subtracting large DC energy terms to recover tiny differences
        // whose errors would otherwise be amplified by CMND normalization.
        // Keep original normalized samples for direct recomputation/refinement.
        var referenceSum = YINSum()
        for i in 0..<w { referenceSum.add(samples[i]) }
        let center = referenceSum.value / Double(w)
        var centeredPeak = 0.0
        var sum = YINSum()
        prefixEnergy[0] = 0
        for i in samples.indices {
            let centered = samples[i] - center
            // Reuse inverse-output scratch until the forward transform consumes it.
            correlation[i] = centered
            centeredPeak = max(centeredPeak, abs(centered))
            sum.add(centered * centered)
            prefixEnergy[i + 1] = sum.value
        }
        for i in 0..<w { reversed[i] = correlation[w - 1 - i] }
        try transform.forwardReal(
            UnsafeBufferPointer(start: correlation.baseAddress, count: samples.count),
            into: firstSpectrum)
        try transform.forwardReal(UnsafeBufferPointer(reversed), into: secondSpectrum)
        for i in firstSpectrum.indices {
            let a = firstSpectrum[i]
            let b = secondSpectrum[i]
            firstSpectrum[i] = FourierBin(
                real: a.real * b.real - a.imaginary * b.imaginary,
                imaginary: a.real * b.imaginary + a.imaginary * b.real)
        }
        try transform.inverseReal(UnsafeBufferPointer(firstSpectrum), into: correlation)
        let cancellationBound =
            128 * Double.ulpOfOne * Double(transform.configuration.length) * Double(w)
            * centeredPeak * centeredPeak
        difference[0] = 0
        for lag in 1..<difference.count {
            let computed =
                prefixEnergy[w] + (prefixEnergy[lag + w] - prefixEnergy[lag])
                - 2 * correlation[w - 1 + lag]
            // Recompute the complete neighbors of either search boundary as well:
            // they determine the raw parabolic vertex and its exact membership.
            let nearLower = abs(lag - configuration.firstCandidateLag) <= 2
            let nearUpper = abs(lag - configuration.lastCandidateLag) <= 2
            if computed <= cancellationBound || nearLower || nearUpper {
                difference[lag] = directDifference(lag)
                recomputedLags &+= 1
            } else {
                guard computed.isFinite else { throw YINError.numericalFailure }
                difference[lag] = computed
            }
        }
    }
    private func normalize() {
        cmnd[0] = 1
        var sum = YINSum()
        for lag in 1..<difference.count {
            sum.add(difference[lag])
            cmnd[lag] = sum.value == 0 ? 1 : Double(lag) * difference[lag] / sum.value
        }
    }
    private func hasAmbiguousLocalDecision() -> Bool {
        for k in configuration.firstCandidateLag...configuration.lastCandidateLag {
            if abs(cmnd[k] - cmnd[k - 1]) < 1e-8 || abs(cmnd[k] - cmnd[k + 1]) < 1e-8 {
                return true
            }
            if isLocalMinimum(k) {
                let error = max(0, vertex(cmnd, k).ordinate)
                if abs(error - configuration.threshold) < 1e-8 { return true }
            }
        }
        return false
    }
    private func isLocalMinimum(_ k: Int) -> Bool {
        cmnd[k] < cmnd[k - 1] && cmnd[k] <= cmnd[k + 1]
    }
    private func vertex(_ values: UnsafeMutableBufferPointer<Double>, _ k: Int)
        -> (offset: Double, ordinate: Double)
    {
        let left = values[k - 1]
        let center = values[k]
        let right = values[k + 1]
        let curvature = left - 2 * center + right
        if curvature > 0 {
            let offset = 0.5 * (left - right) / curvature
            if offset.isFinite, abs(offset) <= 1 {
                return (offset, center - 0.25 * (left - right) * offset)
            }
        }
        return (0, center)
    }
    private func selectCandidates() -> Int? {
        let lower = configuration.minimumPeriodSamples
        let upper = configuration.maximumPeriodSamples
        let firstGlobal = Int(ceil(lower))
        let lastGlobal = Int(floor(upper))
        var global = firstGlobal
        for k in firstGlobal...lastGlobal where cmnd[k] < cmnd[global] { global = k }
        var qualified: Int?
        var fallback: Int?
        for k in configuration.firstCandidateLag...configuration.lastCandidateLag {
            let local = isLocalMinimum(k)
            guard local || k == global else { continue }
            let unbounded = Double(k) + vertex(difference, k).offset
            var period = unbounded
            let nearLower = abs(unbounded - lower) <= configuration.rangeBoundaryToleranceSamples
            let nearUpper = abs(unbounded - upper) <= configuration.rangeBoundaryToleranceSamples
            if nearLower { period = lower } else if nearUpper { period = upper }
            let error = max(0, vertex(cmnd, k).ordinate)
            let inRange = (lower...upper).contains(period)
            let eligible = local && inRange && error < configuration.threshold
            let candidate = YINCandidate(
                integerLag: k, unboundedPeriodSamples: unbounded, periodSamples: period,
                frequencyHz: Double(configuration.sampleRate) / period,
                normalizedError: error, periodicity: max(0, 1 - error),
                isLocalMinimum: local, isGlobalMinimum: k == global, isInRange: inRange,
                isThresholdQualified: eligible, isBoundaryCanonicalized: nearLower || nearUpper)
            candidates.baseAddress!.advanced(by: candidateCount).initialize(to: candidate)
            if qualified == nil, eligible { qualified = candidateCount }
            if inRange, fallback == nil || error < candidates[fallback!].normalizedError {
                fallback = candidateCount
            }
            candidateCount += 1
        }
        return qualified ?? fallback
    }
}

/// Neumaier summation: separate from the oracle's correctly rounded math.fsum.
private struct YINSum {
    private var sum = 0.0
    private var compensation = 0.0
    var value: Double { sum + compensation }
    mutating func add(_ value: Double) {
        let next = sum + value
        compensation += abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
        sum = next
    }
}
