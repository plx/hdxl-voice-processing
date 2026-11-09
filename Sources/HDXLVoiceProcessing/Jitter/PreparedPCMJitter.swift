/// Synchronous borrowed diagnostics expire with the callback. Persisting periods
/// or the pulse trace is an explicit allocation boundary.
public struct BorrowedPCMJitterOutput {
    public let result: JitterAnalysisResult
    public let periods: UnsafeBufferPointer<JitterPeriodInput>
    public let pulses: BorrowedPulseOutput

    public func snapshotPeriods(maximumCount: Int) throws -> [JitterPeriodInput] {
        guard periods.count <= maximumCount else { throw JitterError.capacityExceeded }
        return Array(periods)
    }
}

/// Complete declared PCM/F0 input, acoustic pulse tracking, then jitter statistics.
/// No acquisition framework, microphone, UI or network is involved. Exploratory
/// profiles default to the trailing configured query inside this input; a true
/// incremental period history is supplied by PreparedRollingJitter.
public final class PreparedPCMJitter<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: JitterConfiguration
    public let pulseConfiguration: PulseConfiguration
    public let maximumSampleCount: Int
    private let pulseWorker: PreparedPulseTracker<Sample>
    private let statistics: PreparedJitter
    private let periods: UnsafeMutableBufferPointer<JitterPeriodInput>
    private var busy = false

    public var preparedBufferBytes: Int {
        pulseWorker.executionStatistics.preparedBufferBytes
            + statistics.executionStatistics.preparedBufferBytes
            + periods.count * MemoryLayout<JitterPeriodInput>.stride
    }

    public convenience init(
        configuration: JitterConfiguration, pulseConfiguration: PulseConfiguration,
        maximumSampleCount: Int, maximumF0FrameCount: Int, maximumTrackingAttempts: Int
    ) throws {
        try self.init(
            configuration: configuration, pulseConfiguration: pulseConfiguration,
            maximumSampleCount: maximumSampleCount, maximumF0FrameCount: maximumF0FrameCount,
            maximumTrackingAttempts: maximumTrackingAttempts,
            pulseDiagnostics: WorkerDiagnostics(), statisticsDiagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: JitterConfiguration, pulseConfiguration: PulseConfiguration,
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
        else { throw JitterError.invalidConfiguration }
        let pulse = try PreparedPulseTracker<Sample>(
            configuration: pulseConfiguration,
            maximumSampleCount: maximumSampleCount, maximumF0FrameCount: maximumF0FrameCount,
            maximumTrackingAttempts: maximumTrackingAttempts, diagnostics: pulseDiagnostics)
        let capacity = maximumF0FrameCount + maximumTrackingAttempts
        let totalBytes =
            pulse.executionStatistics.preparedBufferBytes
            + capacity
            * (MemoryLayout<JitterPeriodInput>.stride + MemoryLayout<JitterKernelPeriod>.stride)
        guard totalBytes <= 512 * 1024 * 1024 else { throw JitterError.capacityExceeded }
        self.configuration = configuration
        self.pulseConfiguration = pulseConfiguration
        self.maximumSampleCount = maximumSampleCount
        pulseWorker = pulse
        statistics = try PreparedJitter(
            configuration: configuration, maximumPeriodCount: capacity,
            diagnostics: statisticsDiagnostics)
        periods = .allocate(capacity: capacity)
        periods.initialize(repeating: try JitterPeriodInput(startSeconds: 0, endSeconds: 1))
    }

    deinit {
        periods.deinitialize()
        periods.deallocate()
    }

    public func reset() throws {
        guard !busy else { throw JitterError.reentrantCall }
        try pulseWorker.reset()
        try statistics.reset()
    }

    public func analyze(
        _ input: UnsafeBufferPointer<Sample>, contour: PulseF0Contour, timing: AnalysisTiming,
        query: JitterQueryRange? = nil, excludedSampleRanges: [Range<Int>] = [],
        emit: (BorrowedPCMJitterOutput) throws -> Void
    ) throws {
        guard !busy else { throw JitterError.reentrantCall }
        busy = true
        defer { busy = false }
        let selected: JitterQueryRange
        if let query {
            selected = query
        } else {
            let end = timing.source.durationSeconds
            selected = try JitterQueryRange(
                startSeconds: configuration.rollingWindowDurationSeconds.map { max(0, end - $0) }
                    ?? 0,
                endSeconds: end)
        }
        try pulseWorker.analyze(
            input, contour: contour, timing: timing, excludedSampleRanges: excludedSampleRanges
        ) { output in
            for i in output.periods.indices {
                let period = output.periods[i]
                let sourceFlags = period.rejections
                var reasons: JitterPeriodRejections = []
                if sourceFlags.contains(.excludedSupport) { reasons.insert(.excluded) }
                if sourceFlags.contains(.outsideAcquisition) { reasons.insert(.missingAcquisition) }
                if sourceFlags.contains(.silence) { reasons.insert(.silence) }
                if !sourceFlags.intersection([
                    .differentRun, .trackingFailure, .priorIntervalCollision,
                ]).isEmpty {
                    reasons.insert(.discontinuity)
                }
                if !period.isEligible { reasons.insert(.unreliable) }
                let left = output.landmarks[period.leftPulseIndex].timeSeconds
                let right = output.landmarks[period.rightPulseIndex].timeSeconds
                // The pulse interchange uses count * (1 / rate); source timing
                // uses count / rate. Preserve the raw times and explicitly mark
                // any endpoint outside the declared acquisition timing.
                if left < 0 || right > timing.source.durationSeconds {
                    reasons.insert(.missingAcquisition)
                }
                periods[i] = try JitterPeriodInput(
                    startSeconds: left, endSeconds: right,
                    runID: UInt64(period.runID ?? 0), rejections: reasons)
            }
            let view = UnsafeBufferPointer(start: periods.baseAddress, count: output.periods.count)
            let result = try statistics.analyze(
                view, dependencyTiming: output.result.timing,
                query: selected, provenance: JitterInputProvenance(pulseResult: output.result),
                sourceUnavailability: output.result.unavailability)
            try emit(BorrowedPCMJitterOutput(result: result, periods: view, pulses: output))
        }
    }

    public func analyze(
        _ input: UnsafeBufferPointer<Sample>, contour: PulseF0Contour, timing: AnalysisTiming,
        query: JitterQueryRange? = nil, excludedSampleRanges: [Range<Int>] = []
    ) throws -> JitterAnalysisResult {
        var result: JitterAnalysisResult?
        try analyze(
            input, contour: contour, timing: timing, query: query,
            excludedSampleRanges: excludedSampleRanges
        ) {
            result = $0.result
        }
        guard let result else { throw JitterError.invalidState }
        return result
    }
}
