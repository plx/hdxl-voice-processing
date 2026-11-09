import Foundation

/// Single-owner complete-interval worker. Preparation owns all scratch/output
/// storage; analyze is synchronous and retains no caller PCM or F0 pointer.
/// Call on an analysis worker, never directly from an audio capture callback.
public final class PreparedPulseTracker<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: PulseConfiguration
    public let identity: ProfileIdentity
    public let maximumSampleCount: Int
    public let maximumF0FrameCount: Int
    public let maximumTrackingAttempts: Int
    private let samples: UnsafeMutableBufferPointer<Double>
    private let points: UnsafeMutableBufferPointer<PulseLandmark>
    private let attempts: UnsafeMutableBufferPointer<PulseTrackingAttempt>
    private let periods: UnsafeMutableBufferPointer<PulsePeriod>
    private let pairs: UnsafeMutableBufferPointer<PulsePeriodPair>
    private let amplitudes: UnsafeMutableBufferPointer<PulseCycleAmplitude>
    private let search: PulseSearchKernel
    private let diagnostics: WorkerDiagnostics
    private var busy = false
    private var pointCount = 0
    private var attemptCount = 0
    private var lagCount = 0
    private var analyzedCount: UInt64 = 0
    private var globalPeak = 0.0
    private var previousRightmost: Double?

    public var executionStatistics: PulseExecutionStatistics {
        PulseExecutionStatistics(
            preparedBufferBytes: samples.count * MemoryLayout<Double>.stride + search.workspaceBytes
                + points.count * MemoryLayout<PulseLandmark>.stride
                + attempts.count * MemoryLayout<PulseTrackingAttempt>.stride
                + periods.count * MemoryLayout<PulsePeriod>.stride
                + pairs.count * MemoryLayout<PulsePeriodPair>.stride
                + amplitudes.count * MemoryLayout<PulseCycleAmplitude>.stride,
            analyzedIntervalCount: analyzedCount, trackingAttemptCount: attemptCount,
            evaluatedLagCount: lagCount)
    }

    /// Explicit attempt capacity bounds irregular/ambiguous inputs as well as
    /// successful pulses. Capacity exhaustion throws without publishing a partial
    /// sequence. Prepare a larger worker when more history must be retained.
    public convenience init(
        configuration: PulseConfiguration, maximumSampleCount: Int,
        maximumF0FrameCount: Int, maximumTrackingAttempts: Int
    ) throws {
        try self.init(
            configuration: configuration, maximumSampleCount: maximumSampleCount,
            maximumF0FrameCount: maximumF0FrameCount,
            maximumTrackingAttempts: maximumTrackingAttempts,
            diagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: PulseConfiguration, maximumSampleCount: Int,
        maximumF0FrameCount: Int, maximumTrackingAttempts: Int, diagnostics: WorkerDiagnostics
    ) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw PulseError.precisionMismatch }
        guard (1...PulseConfiguration.maximumInputSampleCount).contains(maximumSampleCount),
            (1...PulseConfiguration.maximumContourFrameCount).contains(maximumF0FrameCount),
            (1...PulseConfiguration.maximumTrackingAttemptCount).contains(maximumTrackingAttempts),
            maximumTrackingAttempts + maximumF0FrameCount
                <= PulseConfiguration.maximumTrackingAttemptCount
        else { throw PulseError.capacityExceeded }
        let pointCapacity = maximumTrackingAttempts + maximumF0FrameCount
        let bytes =
            maximumSampleCount * MemoryLayout<Double>.stride
            + pointCapacity
            * (MemoryLayout<PulseLandmark>.stride + MemoryLayout<PulsePeriod>.stride
                + MemoryLayout<PulsePeriodPair>.stride + MemoryLayout<PulseCycleAmplitude>.stride)
            + maximumTrackingAttempts * MemoryLayout<PulseTrackingAttempt>.stride
        guard bytes <= 512 * 1024 * 1024 else { throw PulseError.capacityExceeded }
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.maximumSampleCount = maximumSampleCount
        self.maximumF0FrameCount = maximumF0FrameCount
        self.maximumTrackingAttempts = maximumTrackingAttempts
        self.diagnostics = diagnostics
        search = PulseSearchKernel(configuration, diagnostics: diagnostics)
        samples = .allocate(capacity: maximumSampleCount)
        samples.initialize(repeating: 0)
        points = .allocate(capacity: pointCapacity)
        points.initialize(repeating: PulseLandmark())
        attempts = .allocate(capacity: maximumTrackingAttempts)
        attempts.initialize(repeating: PulseTrackingAttempt())
        periods = .allocate(capacity: pointCapacity)
        periods.initialize(repeating: PulsePeriod())
        pairs = .allocate(capacity: pointCapacity)
        pairs.initialize(repeating: PulsePeriodPair())
        amplitudes = .allocate(capacity: pointCapacity)
        amplitudes.initialize(repeating: PulseCycleAmplitude())
    }

    deinit {
        samples.deinitialize()
        samples.deallocate()
        points.deinitialize()
        points.deallocate()
        attempts.deinitialize()
        attempts.deallocate()
        periods.deinitialize()
        periods.deallocate()
        pairs.deinitialize()
        pairs.deallocate()
        amplitudes.deinitialize()
        amplitudes.deallocate()
    }

    public func reset() throws {
        guard !busy else { throw PulseError.reentrantCall }
        pointCount = 0
        attemptCount = 0
        lagCount = 0
        globalPeak = 0
        previousRightmost = nil
        diagnostics.reset()
    }

    /// Exclusions are sorted, nonempty, nonoverlapping sample ranges relative to
    /// timing.source.startSample. Raw tracking retains the complete input's global
    /// amplitude dependency; eligibility rejects intersecting local support and
    /// periods. Excluded regions are never removed and their neighbors rejoined.
    public func analyze(
        _ input: UnsafeBufferPointer<Sample>, contour: PulseF0Contour, timing: AnalysisTiming,
        excludedSampleRanges: [Range<Int>] = [], emit: (BorrowedPulseOutput) throws -> Void
    ) throws {
        guard !busy else { throw PulseError.reentrantCall }
        busy = true
        defer { busy = false }
        guard input.count > 0, input.count <= maximumSampleCount,
            contour.frequenciesHz.count <= maximumF0FrameCount
        else { throw PulseError.invalidBufferSize }
        guard contour.sampleRate == configuration.sampleRate, contour.sampleCount == input.count,
            contour.ceilingHz <= configuration.pitchCeilingHz,
            contour.frequenciesHz.allSatisfy({ $0 == 0 || $0 >= configuration.pitchFloorHz }),
            timing.source.sampleRate == Double(configuration.sampleRate),
            timing.source.sampleCount == Int64(input.count)
        else { throw PulseError.unexpectedContext }
        var excludedCount = 0
        var previousEnd = 0
        for range in excludedSampleRanges {
            guard !range.isEmpty, range.lowerBound >= previousEnd, range.upperBound <= input.count
            else {
                throw PulseError.unexpectedContext
            }
            excludedCount += range.count
            previousEnd = range.upperBound
        }
        guard timing.includedSampleCount == Int64(input.count - excludedCount), analyzedCount < .max
        else {
            throw PulseError.unexpectedContext
        }
        pointCount = 0
        attemptCount = 0
        lagCount = 0
        globalPeak = 0
        previousRightmost = nil
        for i in input.indices {
            let value = Double(input[i])
            guard value.isFinite, abs(value) <= 1 else { throw PulseError.invalidInput }
            samples[i] = value
            globalPeak = max(globalPeak, abs(value))
        }
        let outputTiming = try AnalysisTiming(
            source: timing.source, includedSampleCount: timing.includedSampleCount,
            sourceStartSeconds: timing.sourceStartSeconds,
            hostStartNanoseconds: timing.hostStartNanoseconds,
            completedHostNanoseconds: timing.completedHostNanoseconds,
            effectiveDelaySeconds: max(
                timing.effectiveDelaySeconds, timing.source.durationSeconds / 2))
        let pcm = UnsafeBufferPointer(start: samples.baseAddress, count: input.count)
        var metadata = DiagnosticMetadata()
        metadata.frameSequence = analyzedCount
        metadata.sampleCount = UInt32(input.count)
        metadata.profileToken = 42
        try diagnostics.withFrame(metadata) {
            let result = try diagnostics.withInterval(.pulses) {
                let intervalCount = try contour.frequenciesHz.withUnsafeBufferPointer { f0 in
                    try locate(pcm, f0: f0, contour: contour, exclusions: excludedSampleRanges)
                }
                let counts = diagnostics.withInterval(.pulseSequences) {
                    buildSequences(
                        pcm, end: contour.domainEndSeconds, exclusions: excludedSampleRanges)
                }
                let unavailable: UnavailabilityReason? =
                    counts.periods > 0
                    ? nil
                    : timing.includedSampleCount == 0
                        ? .excluded
                        : globalPeak == 0
                            ? .silence
                            : pointCount < 2 ? .insufficientData : .lowConfidence
                return PulseAnalysisResult(
                    profile: identity, timing: outputTiming,
                    f0ContourIdentity: try contour.identity(),
                    f0SourceProfile: contour.sourceProfile,
                    f0FrameCount: contour.frequenciesHz.count,
                    f0FirstCenterSeconds: contour.firstCenterSeconds,
                    f0StepSeconds: contour.stepSeconds, voicedIntervalCount: intervalCount,
                    rawPulseCount: pointCount, trackingAttemptCount: attemptCount,
                    eligiblePulseCount: counts.points, eligiblePeriodCount: counts.periods,
                    eligiblePairCount: counts.pairs, availableAmplitudeCount: counts.amplitudes,
                    runCount: counts.runs, unavailability: unavailable)
            }
            analyzedCount += 1
            try diagnostics.withInterval(.resultPublication) {
                try emit(
                    BorrowedPulseOutput(
                        result: result,
                        landmarks: UnsafeBufferPointer(
                            start: points.baseAddress, count: pointCount),
                        attempts: UnsafeBufferPointer(
                            start: attempts.baseAddress, count: attemptCount),
                        periods: UnsafeBufferPointer(
                            start: periods.baseAddress, count: max(0, pointCount - 1)),
                        periodPairs: UnsafeBufferPointer(
                            start: pairs.baseAddress, count: max(0, pointCount - 2)),
                        amplitudes: UnsafeBufferPointer(
                            start: amplitudes.baseAddress, count: pointCount)))
            }
        }
    }

    private func locate(
        _ pcm: UnsafeBufferPointer<Double>, f0: UnsafeBufferPointer<Double>,
        contour: PulseF0Contour,
        exclusions: [Range<Int>]
    ) throws -> Int {
        var cursor = 0
        var interval = 0
        let end = contour.domainEndSeconds
        while cursor < f0.count {
            if f0[cursor] == 0 {
                cursor += 1
                continue
            }
            let firstFrame = cursor
            while cursor + 1 < f0.count && f0[cursor + 1] > 0 { cursor += 1 }
            let lastFrame = cursor
            cursor += 1
            let rawLeft =
                contour.firstCenterSeconds.addingProduct(Double(firstFrame), contour.stepSeconds)
                - 0.5 * contour.stepSeconds
            guard rawLeft < end - 0.5 * contour.stepSeconds else { break }
            let left = max(0, rawLeft)
            let right = min(
                end,
                contour.firstCenterSeconds.addingProduct(Double(lastFrame), contour.stepSeconds)
                    + 0.5 * contour.stepSeconds)
            guard left < right else { continue }
            let middle = 0.5 * (left + right)
            guard
                let frequency = PulseF0Contour.observation(
                    time: middle, end: end, first: contour.firstCenterSeconds,
                    step: contour.stepSeconds,
                    frequencies: f0
                ).frequencyHz
            else { throw PulseError.numericalFailure }
            let seed = try search.seed(pcm, midpoint: middle, frequency: frequency)
            var rejections = pointRejections(seed.timeSeconds, left: left, right: right, end: end)
            if seed.peak == 0 {
                rejections.insert(.silence)
            } else if !seed.varyingSupport {
                rejections.insert(.degenerateWaveform)
            }
            if seed.lastSampleIndex - seed.firstSampleIndex + 1 < 3 {
                rejections.insert(.insufficientSupport)
            }
            if seed.firstRequiredSampleIndex < 0 || seed.lastRequiredSampleIndex >= pcm.count {
                rejections.insert(.insufficientSupport)
            }
            if intersectsSamples(seed.firstSampleIndex, seed.lastSampleIndex + 1, exclusions) {
                rejections.insert(.excludedSupport)
            }
            try appendPoint(
                PulseLandmark(
                    timeSeconds: seed.timeSeconds, voicedIntervalID: interval, direction: .seed,
                    rejections: rejections))
            try follow(
                pcm, f0: f0, contour: contour, seed: seed.timeSeconds, direction: .backward,
                interval: interval, left: left, right: right, exclusions: exclusions)
            try follow(
                pcm, f0: f0, contour: contour, seed: seed.timeSeconds, direction: .forward,
                interval: interval, left: left, right: right, exclusions: exclusions)
            interval += 1
        }
        return interval
    }

    private func follow(
        _ pcm: UnsafeBufferPointer<Double>, f0: UnsafeBufferPointer<Double>,
        contour: PulseF0Contour,
        seed: Double, direction: PulseSearchDirection, interval: Int, left: Double, right: Double,
        exclusions: [Range<Int>]
    ) throws {
        var anchor = seed
        var ordinal = 0
        let publicDirection: PulseTrackingDirection = direction == .backward ? .backward : .forward
        while let frequency = PulseF0Contour.observation(
            time: anchor, end: contour.domainEndSeconds, first: contour.firstCenterSeconds,
            step: contour.stepSeconds, frequencies: f0
        ).frequencyHz {
            guard attemptCount < attempts.count else { throw PulseError.capacityExceeded }
            let match = try search.match(
                pcm, anchor: anchor, frequency: frequency, direction: direction)
            ordinal += 1
            lagCount += match.evaluatedLagCount
            let outside =
                direction == .backward ? match.timeSeconds < left : match.timeSeconds > right
            let coefficient = match.correlation ?? -1
            let correlationPass = coefficient > (outside ? 0.7 : 0.3)
            let amplitudePass =
                outside
                ? match.amplitudeGatePeak > 0.023333 * globalPeak
                : match.amplitudeGatePeak == 0 || match.amplitudeGatePeak > 0.01 * globalPeak
            let collision =
                direction == .backward
                && previousRightmost.map {
                    match.timeSeconds - $0 <= 0.8 / frequency
                } == true
            let accepted = correlationPass && amplitudePass && !collision
            var rejections = pointRejections(
                match.timeSeconds, left: left, right: right, end: contour.domainEndSeconds)
            if !correlationPass { rejections.insert(.lowCorrelation) }
            if !amplitudePass { rejections.insert(.lowAmplitude) }
            if collision { rejections.insert(.priorIntervalCollision) }
            if match.observedPairCount < 3 { rejections.insert(.insufficientSupport) }
            if match.support == .silent { rejections.insert(.silence) }
            if match.support == .numericalFailure { rejections.insert(.numericalFailure) }
            if match.support == .observed && !match.varyingSupport {
                rejections.insert(.degenerateWaveform)
            }
            if match.curvature < configuration.minimumReliableCurvature {
                rejections.insert(.illConditionedPeak)
            }
            if match.usedRangeFallback { rejections.insert(.rangeFallback) }
            if match.firstRequiredSampleIndex < 0 || match.lastRequiredSampleIndex >= pcm.count {
                rejections.insert(.insufficientSupport)
            }
            if intersectsSamples(
                match.firstRequiredSampleIndex, match.lastRequiredSampleIndex + 1, exclusions)
            {
                rejections.insert(.excludedSupport)
            }
            attempts[attemptCount] = PulseTrackingAttempt(
                index: attemptCount, voicedIntervalID: interval, direction: publicDirection,
                stepIndex: ordinal,
                fromSeconds: anchor, proposedSeconds: match.timeSeconds, frequencyHz: frequency,
                correlation: match.correlation, amplitudeGatePeak: match.amplitudeGatePeak,
                curvature: match.curvature, observedPairCount: match.observedPairCount,
                firstRequiredSampleIndex: match.firstRequiredSampleIndex,
                lastRequiredSampleIndex: match.lastRequiredSampleIndex,
                selectedSyntheticCandidate: match.selectedSyntheticCandidate,
                acceptedByReferenceGates: accepted, usedRangeFallback: match.usedRangeFallback,
                rejections: rejections)
            if accepted {
                try appendPoint(
                    PulseLandmark(
                        timeSeconds: match.timeSeconds, voicedIntervalID: interval,
                        direction: publicDirection,
                        stepIndex: ordinal, attemptIndex: attemptCount, rejections: rejections))
                if direction == .forward { previousRightmost = match.timeSeconds }
            }
            attemptCount += 1
            anchor = match.timeSeconds
            if outside { break }
        }
    }

    private func appendPoint(_ value: PulseLandmark) throws {
        guard pointCount < points.count else { throw PulseError.capacityExceeded }
        var point = value
        point.index = pointCount
        points[pointCount] = point
        pointCount += 1
    }

    private func pointRejections(_ time: Double, left: Double, right: Double, end: Double)
        -> PulseRejections
    {
        var reasons: PulseRejections = []
        if !(0..<end).contains(time) { reasons.insert(.outsideAcquisition) }
        if !(left..<right).contains(time) { reasons.insert(.outsideVoicedInterval) }
        return reasons
    }

    private func intersectsSamples(_ start: Int, _ end: Int, _ exclusions: [Range<Int>]) -> Bool {
        for range in exclusions {
            if range.lowerBound >= end { return false }
            if range.upperBound > start { return true }
        }
        return false
    }

    private func crossesExclusion(_ left: Double, _ right: Double, _ exclusions: [Range<Int>])
        -> Bool
    {
        let step = 1 / Double(configuration.sampleRate)
        for range in exclusions {
            if Double(range.lowerBound) * step >= right { return false }
            if Double(range.upperBound) * step > left { return true }
        }
        return false
    }

    private func adjacentTrackingSteps(_ left: PulseLandmark, _ right: PulseLandmark) -> Bool {
        guard left.voicedIntervalID == right.voicedIntervalID else { return false }
        switch (left.direction, right.direction) {
        case (.backward, .backward): return left.stepIndex == right.stepIndex + 1
        case (.backward, .seed): return left.stepIndex == 1
        case (.seed, .forward): return right.stepIndex == 1
        case (.forward, .forward): return right.stepIndex == left.stepIndex + 1
        default: return false
        }
    }

    private func buildSequences(
        _ pcm: UnsafeBufferPointer<Double>, end: Double, exclusions: [Range<Int>]
    ) -> (points: Int, periods: Int, pairs: Int, amplitudes: Int, runs: Int) {
        sortPoints()
        var unique = 0
        for i in 0..<pointCount {
            if unique > 0 && points[i].timeSeconds == points[unique - 1].timeSeconds {
                points[unique - 1].rejections.insert(.differentRun)
            } else {
                points[unique] = points[i]
                points[unique].index = unique
                unique += 1
            }
        }
        pointCount = unique
        var eligiblePoints = 0
        var eligiblePeriods = 0
        var eligiblePairs = 0
        var availableAmplitudes = 0
        var runs = 0
        for i in 0..<pointCount {
            if points[i].rejections.isEmpty {
                let duration = i > 0 ? points[i].timeSeconds - points[i - 1].timeSeconds : 0
                let connects =
                    i > 0 && points[i - 1].isEligible
                    && adjacentTrackingSteps(points[i - 1], points[i])
                    && !crossesExclusion(
                        points[i - 1].timeSeconds, points[i].timeSeconds, exclusions)
                    && (configuration.minimumPeriodSeconds...configuration.maximumPeriodSeconds)
                        .contains(duration)
                if connects {
                    points[i].runID = points[i - 1].runID
                } else {
                    points[i].runID = runs
                    runs += 1
                }
                eligiblePoints += 1
            } else {
                points[i].runID = nil
            }
            if i == 0 { continue }
            let left = points[i - 1]
            let right = points[i]
            let duration = right.timeSeconds - left.timeSeconds
            var reasons = left.rejections.union(right.rejections)
            if !adjacentTrackingSteps(left, right) { reasons.insert(.trackingFailure) }
            if left.runID == nil || left.runID != right.runID { reasons.insert(.differentRun) }
            if crossesExclusion(left.timeSeconds, right.timeSeconds, exclusions) {
                reasons.insert(.excludedSupport)
            }
            if duration < configuration.minimumPeriodSeconds { reasons.insert(.periodBelowMinimum) }
            if duration > configuration.maximumPeriodSeconds { reasons.insert(.periodAboveMaximum) }
            periods[i - 1] = PulsePeriod(
                index: i - 1, leftPulseIndex: i - 1, rightPulseIndex: i, durationSeconds: duration,
                runID: reasons.isEmpty ? left.runID : nil, rejections: reasons)
            if reasons.isEmpty { eligiblePeriods += 1 }
        }
        for i in 0..<max(0, pointCount - 2) {
            let left = periods[i]
            let right = periods[i + 1]
            let ratio =
                max(left.durationSeconds, right.durationSeconds)
                / min(left.durationSeconds, right.durationSeconds)
            var reasons = left.rejections.union(right.rejections)
            if ratio > configuration.maximumAdjacentPeriodFactor {
                reasons.insert(.adjacentPeriodFactor)
            }
            pairs[i] = PulsePeriodPair(
                index: i, leftPeriodIndex: i, rightPeriodIndex: i + 1, ratio: ratio,
                rejections: reasons)
            if reasons.isEmpty { eligiblePairs += 1 }
        }
        for i in 0..<pointCount {
            amplitudes[i] = amplitude(pcm, at: i, end: end)
            if amplitudes[i].isEligible { availableAmplitudes += 1 }
        }
        return (eligiblePoints, eligiblePeriods, eligiblePairs, availableAmplitudes, runs)
    }

    // In-place max-heap sorting avoids the standard stable sort's temporary
    // allocation. Creation index is the explicit tie break, independent of sort
    // stability. The complete point capacity was allocated during preparation.
    private func sortPoints() {
        guard pointCount > 1 else { return }
        for root in stride(from: pointCount / 2 - 1, through: 0, by: -1) {
            siftPoint(root, end: pointCount)
        }
        for end in stride(from: pointCount - 1, through: 1, by: -1) {
            points.swapAt(0, end)
            siftPoint(0, end: end)
        }
    }

    private func pointPrecedes(_ a: Int, _ b: Int) -> Bool {
        points[a].timeSeconds == points[b].timeSeconds
            ? points[a].index < points[b].index : points[a].timeSeconds < points[b].timeSeconds
    }

    private func siftPoint(_ start: Int, end: Int) {
        var root = start
        while root < end / 2 {
            var child = 2 * root + 1
            if child + 1 < end, pointPrecedes(child, child + 1) { child += 1 }
            guard pointPrecedes(root, child) else { return }
            points.swapAt(root, child)
            root = child
        }
    }

    private func amplitude(_ pcm: UnsafeBufferPointer<Double>, at i: Int, end: Double)
        -> PulseCycleAmplitude
    {
        guard i > 0 && i + 1 < pointCount else {
            return PulseCycleAmplitude(pulseIndex: i, rejections: .insufficientCycles)
        }
        let eligibility = pairs[i - 1]
        guard eligibility.isEligible else {
            return PulseCycleAmplitude(pulseIndex: i, rejections: eligibility.rejections)
        }
        let time = points[i].timeSeconds
        let left = 0.2 * periods[i - 1].durationSeconds
        let right = 0.2 * periods[i].durationSeconds
        let start = time - left
        let finish = time + right
        var result = PulseCycleAmplitude(
            pulseIndex: i, supportStartSeconds: start, supportEndSeconds: finish)
        guard start >= 0, finish <= end else {
            result.rejections = .insufficientSupport
            return result
        }
        let rate = Double(configuration.sampleRate)
        let step = 1 / rate
        let first = max(0, Int(ceil(start * rate - 0.5)))
        let last = min(pcm.count - 1, Int(floor(finish * rate - 0.5)))
        result.observedSampleCount = max(0, last - first + 1)
        guard result.observedSampleCount >= 3 else {
            result.rejections = .insufficientSupport
            return result
        }
        var peak = 0.0
        for j in first...last { peak = max(peak, abs(pcm[j])) }
        guard peak > 0 else {
            result.rejections = .silence
            return result
        }
        var energy = 0.0
        var weights = 0.0
        for j in first...last {
            let offset = (0.5 / rate).addingProduct(Double(j), step) - time
            let width = offset < 0 ? left : right
            let taper = 0.5 + 0.5 * cos(.pi * offset / width)
            let weight = taper * taper
            let value = pcm[j] / peak
            energy += value * value * weight
            weights += weight
        }
        let rms = peak * sqrt(energy / weights)
        guard rms.isFinite, rms > 0 else {
            result.rejections = .numericalFailure
            return result
        }
        result.rmsAmplitude = rms
        return result
    }
}
