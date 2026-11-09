/// Single-owner synchronous statistics worker. Setup allocates bounded storage;
/// analysis borrows the caller's records and returns a fixed-size report.
/// Invoke on an analysis worker, never in a hardware capture callback.
public final class PreparedShimmer {
    public let configuration: ShimmerConfiguration
    public let identity: ProfileIdentity
    public let maximumAmplitudeCount: Int
    private let records: UnsafeMutableBufferPointer<ShimmerKernelAmplitude>
    private let diagnostics: WorkerDiagnostics
    private var busy = false
    private var analyzedCount: UInt64 = 0
    private var lastInputCount = 0

    public var executionStatistics: ShimmerExecutionStatistics {
        ShimmerExecutionStatistics(
            preparedBufferBytes: records.count * MemoryLayout<ShimmerKernelAmplitude>.stride,
            analyzedQueryCount: analyzedCount, lastInputAmplitudeCount: lastInputCount)
    }

    public convenience init(configuration: ShimmerConfiguration, maximumAmplitudeCount: Int) throws
    {
        try self.init(
            configuration: configuration, maximumAmplitudeCount: maximumAmplitudeCount,
            diagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: ShimmerConfiguration, maximumAmplitudeCount: Int,
        diagnostics: WorkerDiagnostics
    ) throws {
        guard (1...ShimmerConfiguration.maximumAmplitudeCount).contains(maximumAmplitudeCount)
        else {
            throw ShimmerError.capacityExceeded
        }
        self.configuration = configuration
        identity = try configuration.identity()
        self.maximumAmplitudeCount = maximumAmplitudeCount
        self.diagnostics = diagnostics
        records = .allocate(capacity: maximumAmplitudeCount)
        records.initialize(
            repeating: ShimmerKernelAmplitude(
                timeSeconds: 0, amplitude: 0,
                selected: false, reliable: false, connectsToPrevious: false))
    }

    deinit {
        records.deinitialize()
        records.deallocate()
    }

    public func reset() throws {
        guard !busy else { throw ShimmerError.reentrantCall }
        busy = true
        defer { busy = false }
        analyzedCount = 0
        lastInputCount = 0
        diagnostics.reset()
    }

    /// Only selected amplitude centers participate in the normalization. Source
    /// rejections remain hard boundaries; numerical edge rejections do not filter
    /// the normalization population. A nil query selects the whole dependency.
    public func analyze(
        _ amplitudes: UnsafeBufferPointer<ShimmerAmplitudeInput>, dependencyTiming: AnalysisTiming,
        query: ShimmerQueryRange? = nil, provenance: ShimmerInputProvenance = .init(),
        sourceUnavailability: UnavailabilityReason? = nil
    ) throws -> ShimmerAnalysisResult {
        try evaluate(
            amplitudes, timing: dependencyTiming, query: query, provenance: provenance,
            sourceUnavailability: sourceUnavailability, requested: .all)
    }

    /// Preserves all coverage counts while computing only the requested numerator.
    public func analyze(
        _ variant: ShimmerVariant, amplitudes: UnsafeBufferPointer<ShimmerAmplitudeInput>,
        dependencyTiming: AnalysisTiming, query: ShimmerQueryRange? = nil,
        provenance: ShimmerInputProvenance = .init(),
        sourceUnavailability: UnavailabilityReason? = nil
    ) throws -> ShimmerAnalysisResult {
        try evaluate(
            amplitudes, timing: dependencyTiming, query: query, provenance: provenance,
            sourceUnavailability: sourceUnavailability, requested: .init(variant))
    }

    private func evaluate(
        _ amplitudes: UnsafeBufferPointer<ShimmerAmplitudeInput>, timing: AnalysisTiming,
        query requestedQuery: ShimmerQueryRange?, provenance: ShimmerInputProvenance,
        sourceUnavailability: UnavailabilityReason?, requested: ShimmerRequestedVariants
    ) throws -> ShimmerAnalysisResult {
        guard !busy else { throw ShimmerError.reentrantCall }
        busy = true
        defer { busy = false }
        guard amplitudes.count <= maximumAmplitudeCount else { throw ShimmerError.capacityExceeded }
        guard timing.source.sampleRate == Double(configuration.sampleRate), analyzedCount < .max
        else {
            throw ShimmerError.unexpectedContext
        }
        let query =
            try requestedQuery
            ?? ShimmerQueryRange(startSeconds: 0, endSeconds: timing.source.durationSeconds)
        guard query.endSeconds <= timing.source.durationSeconds else {
            throw ShimmerError.unexpectedContext
        }
        if let window = configuration.rollingWindowDurationSeconds {
            let minimum = max(0, query.endSeconds - window)
            let allowance = min(
                0.5 / Double(configuration.sampleRate), 2 * (query.endSeconds.ulp + window.ulp))
            guard query.startSeconds >= minimum || minimum - query.startSeconds <= allowance else {
                throw ShimmerError.unexpectedContext
            }
        }
        for i in amplitudes.indices {
            let a = amplitudes[i]
            guard
                i == 0
                    || (amplitudes[i - 1].timeSeconds < a.timeSeconds
                        && (a.timeSeconds - amplitudes[i - 1].timeSeconds).isFinite)
            else {
                throw ShimmerError.invalidInput
            }
            if a.timeSeconds < 0 || a.timeSeconds > timing.source.durationSeconds {
                guard a.rejections.contains(.missingAcquisition) else {
                    throw ShimmerError.unexpectedContext
                }
            }
        }
        var sourceRejections = ShimmerRejectionCounts()
        for i in amplitudes.indices {
            let a = amplitudes[i]
            let selected = a.timeSeconds >= query.startSeconds && a.timeSeconds <= query.endSeconds
            var reasons = a.rejections
            if timing.includedSampleCount == 0 { reasons.insert(.excluded) }
            let connected =
                i > 0 && a.runID == amplitudes[i - 1].runID
                && amplitudes[i - 1].sequenceIndex < .max
                && a.sequenceIndex == amplitudes[i - 1].sequenceIndex + 1
            records[i] = ShimmerKernelAmplitude(
                timeSeconds: a.timeSeconds, amplitude: a.amplitude ?? 0,
                selected: selected, reliable: a.amplitude != nil && reasons.isEmpty,
                connectsToPrevious: connected)
            if selected { sourceRejections.add(reasons) }
        }
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 51
        metadata.frameSequence = analyzedCount
        metadata.sampleCount = UInt32(clamping: timing.source.sampleCount)
        metadata.elapsedProcessingCount = analyzedCount
        let result = diagnostics.withFrame(metadata, stage: .perturbation) {
            let raw = ShimmerKernel.evaluate(
                UnsafeBufferPointer(start: records.baseAddress, count: amplitudes.count),
                configuration: configuration, requested: requested)
            return ShimmerAnalysisResult(
                raw: raw, configuration: configuration, identity: identity,
                timing: timing, query: query, provenance: provenance, inputCount: amplitudes.count,
                sourceRejections: sourceRejections, sourceUnavailability: sourceUnavailability,
                requested: requested)
        }
        analyzedCount += 1
        lastInputCount = amplitudes.count
        return result
    }
}
