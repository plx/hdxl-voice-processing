/// Synchronous borrowed diagnostics expire with the callback. Persisting amplitudes
/// or the pulse trace is an explicit allocation boundary.
public struct BorrowedPCMShimmerOutput {
    public let result: ShimmerAnalysisResult
    public let amplitudes: UnsafeBufferPointer<ShimmerAmplitudeInput>
    public let pulses: BorrowedPulseOutput

    public func snapshotAmplitudes(maximumCount: Int) throws -> [ShimmerAmplitudeInput] {
        guard amplitudes.count <= maximumCount else { throw ShimmerError.capacityExceeded }
        return Array(amplitudes)
    }
}

/// Complete declared PCM/F0 input, acoustic pulse tracking, then shimmer statistics.
/// No acquisition framework, microphone, UI or network is involved. Exploratory
/// profiles default to the trailing configured query inside this input; a true
/// incremental amplitude history is supplied by PreparedRollingShimmer.
public final class PreparedPCMShimmer<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: ShimmerConfiguration
    public let pulseConfiguration: PulseConfiguration
    public let maximumSampleCount: Int
    private let pulseWorker: PreparedPulseTracker<Sample>
    private let statistics: PreparedShimmer
    private let amplitudes: UnsafeMutableBufferPointer<ShimmerAmplitudeInput>
    private var busy = false

    public var preparedBufferBytes: Int {
        pulseWorker.executionStatistics.preparedBufferBytes
            + statistics.executionStatistics.preparedBufferBytes
            + amplitudes.count * MemoryLayout<ShimmerAmplitudeInput>.stride
    }

    public convenience init(
        configuration: ShimmerConfiguration, pulseConfiguration: PulseConfiguration,
        maximumSampleCount: Int, maximumF0FrameCount: Int, maximumTrackingAttempts: Int
    ) throws {
        try self.init(
            configuration: configuration, pulseConfiguration: pulseConfiguration,
            maximumSampleCount: maximumSampleCount, maximumF0FrameCount: maximumF0FrameCount,
            maximumTrackingAttempts: maximumTrackingAttempts,
            pulseDiagnostics: WorkerDiagnostics(), statisticsDiagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: ShimmerConfiguration, pulseConfiguration: PulseConfiguration,
        maximumSampleCount: Int, maximumF0FrameCount: Int, maximumTrackingAttempts: Int,
        pulseDiagnostics: WorkerDiagnostics, statisticsDiagnostics: WorkerDiagnostics
    ) throws {
        guard configuration.sampleRate == pulseConfiguration.sampleRate,
            configuration.inputPrecision == pulseConfiguration.inputPrecision,
            configuration.minimumPeriodSeconds == pulseConfiguration.minimumPeriodSeconds,
            configuration.maximumPeriodSeconds == pulseConfiguration.maximumPeriodSeconds,
            configuration.maximumAdjacentPeriodFactor
                == pulseConfiguration.maximumAdjacentPeriodFactor,
            configuration.applicability != .sustainedPhonation
                || pulseConfiguration.support == .completeInterval
        else { throw ShimmerError.invalidConfiguration }
        let pulse = try PreparedPulseTracker<Sample>(
            configuration: pulseConfiguration,
            maximumSampleCount: maximumSampleCount, maximumF0FrameCount: maximumF0FrameCount,
            maximumTrackingAttempts: maximumTrackingAttempts, diagnostics: pulseDiagnostics)
        let capacity = maximumF0FrameCount + maximumTrackingAttempts
        let totalBytes =
            pulse.executionStatistics.preparedBufferBytes
            + capacity
            * (MemoryLayout<ShimmerAmplitudeInput>.stride
                + MemoryLayout<ShimmerKernelAmplitude>.stride)
        guard totalBytes <= 512 * 1024 * 1024 else { throw ShimmerError.capacityExceeded }
        self.configuration = configuration
        self.pulseConfiguration = pulseConfiguration
        self.maximumSampleCount = maximumSampleCount
        pulseWorker = pulse
        statistics = try PreparedShimmer(
            configuration: configuration, maximumAmplitudeCount: capacity,
            diagnostics: statisticsDiagnostics)
        amplitudes = .allocate(capacity: capacity)
        amplitudes.initialize(
            repeating: try ShimmerAmplitudeInput(timeSeconds: 0, amplitude: 0, sequenceIndex: 0))
    }

    deinit {
        amplitudes.deinitialize()
        amplitudes.deallocate()
    }

    public func reset() throws {
        guard !busy else { throw ShimmerError.reentrantCall }
        busy = true
        defer { busy = false }
        try pulseWorker.reset()
        try statistics.reset()
    }

    public func analyze(
        _ input: UnsafeBufferPointer<Sample>, contour: PulseF0Contour, timing: AnalysisTiming,
        query: ShimmerQueryRange? = nil, excludedSampleRanges: [Range<Int>] = [],
        emit: (BorrowedPCMShimmerOutput) throws -> Void
    ) throws {
        guard !busy else { throw ShimmerError.reentrantCall }
        busy = true
        defer { busy = false }
        let selected: ShimmerQueryRange
        if let query {
            selected = query
        } else {
            let end = timing.source.durationSeconds
            selected = try ShimmerQueryRange(
                startSeconds: configuration.rollingWindowDurationSeconds.map { max(0, end - $0) }
                    ?? 0,
                endSeconds: end)
        }
        try pulseWorker.analyze(
            input, contour: contour, timing: timing, excludedSampleRanges: excludedSampleRanges
        ) { output in
            for i in output.amplitudes.indices {
                let observed = output.amplitudes[i]
                let point = output.landmarks[i]
                let flags = observed.rejections
                var reasons: ShimmerAmplitudeRejections = []
                if flags.contains(.excludedSupport) { reasons.insert(.excluded) }
                if flags.contains(.outsideAcquisition) { reasons.insert(.missingAcquisition) }
                if flags.contains(.silence) { reasons.insert(.silence) }
                if !flags.intersection([.insufficientSupport, .insufficientCycles]).isEmpty {
                    reasons.insert(.insufficientSupport)
                }
                if !flags.intersection([
                    .periodBelowMinimum, .periodAboveMaximum, .adjacentPeriodFactor,
                ]).isEmpty {
                    reasons.insert(.periodExclusion)
                }
                if !flags.intersection([.differentRun, .trackingFailure, .priorIntervalCollision])
                    .isEmpty
                {
                    reasons.insert(.discontinuity)
                }
                if !observed.isEligible { reasons.insert(.unreliable) }
                if point.timeSeconds < 0 || point.timeSeconds > timing.source.durationSeconds {
                    reasons.insert(.missingAcquisition)
                }
                // A cropped waveform query must have both neighboring pulses
                // inside the query before a cycle amplitude can contribute.
                // Reuse the independently extracted RMS; never recalculate it
                // from a shortened support window.
                if i == 0 || i + 1 == output.landmarks.count
                    || output.landmarks[i - 1].timeSeconds < selected.startSeconds
                    || output.landmarks[i + 1].timeSeconds > selected.endSeconds
                {
                    reasons.insert(.insufficientSupport)
                }
                amplitudes[i] = try ShimmerAmplitudeInput(
                    timeSeconds: point.timeSeconds,
                    amplitude: observed.rmsAmplitude, sequenceIndex: UInt64(i),
                    runID: UInt64(point.runID ?? 0), rejections: reasons)
            }
            let view = UnsafeBufferPointer(
                start: amplitudes.baseAddress, count: output.amplitudes.count)
            let result = try statistics.analyze(
                view, dependencyTiming: output.result.timing,
                query: selected, provenance: ShimmerInputProvenance(pulseResult: output.result),
                sourceUnavailability: output.result.unavailability)
            try emit(BorrowedPCMShimmerOutput(result: result, amplitudes: view, pulses: output))
        }
    }

    public func analyze(
        _ input: UnsafeBufferPointer<Sample>, contour: PulseF0Contour, timing: AnalysisTiming,
        query: ShimmerQueryRange? = nil, excludedSampleRanges: [Range<Int>] = []
    ) throws -> ShimmerAnalysisResult {
        var result: ShimmerAnalysisResult?
        try analyze(
            input, contour: contour, timing: timing, query: query,
            excludedSampleRanges: excludedSampleRanges
        ) {
            result = $0.result
        }
        guard let result else { throw ShimmerError.invalidState }
        return result
    }
}
