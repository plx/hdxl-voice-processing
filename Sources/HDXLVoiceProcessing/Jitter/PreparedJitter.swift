/// Single-owner synchronous statistics worker. Setup allocates bounded record
/// storage; analyze neither retains caller input nor allocates an output array.
/// Invoke on an analysis worker, never in a hardware capture callback.
public final class PreparedJitter {
    public let configuration: JitterConfiguration
    public let identity: ProfileIdentity
    public let maximumPeriodCount: Int
    private let records: UnsafeMutableBufferPointer<JitterKernelPeriod>
    private let diagnostics: WorkerDiagnostics
    private var busy = false
    private var analyzedCount: UInt64 = 0
    private var lastInputCount = 0

    public var executionStatistics: JitterExecutionStatistics {
        JitterExecutionStatistics(
            preparedBufferBytes: records.count * MemoryLayout<JitterKernelPeriod>.stride,
            analyzedQueryCount: analyzedCount, lastInputPeriodCount: lastInputCount)
    }

    public convenience init(configuration: JitterConfiguration, maximumPeriodCount: Int) throws {
        try self.init(
            configuration: configuration, maximumPeriodCount: maximumPeriodCount,
            diagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: JitterConfiguration, maximumPeriodCount: Int, diagnostics: WorkerDiagnostics
    ) throws {
        guard (1...JitterConfiguration.maximumPeriodCount).contains(maximumPeriodCount) else {
            throw JitterError.capacityExceeded
        }
        self.configuration = configuration
        identity = try configuration.identity()
        self.maximumPeriodCount = maximumPeriodCount
        self.diagnostics = diagnostics
        records = .allocate(capacity: maximumPeriodCount)
        records.initialize(
            repeating: JitterKernelPeriod(
                durationSeconds: 0, selected: false, reliable: false, connectsToPrevious: false))
    }

    deinit {
        records.deinitialize()
        records.deallocate()
    }

    public func reset() throws {
        guard !busy else { throw JitterError.reentrantCall }
        analyzedCount = 0
        lastInputCount = 0
        diagnostics.reset()
    }

    /// Complete context is supplied even for a cropped query. Immediate outside
    /// neighbors can affect denominator membership; other runs cannot.
    public func analyze(
        _ periods: UnsafeBufferPointer<JitterPeriodInput>, dependencyTiming: AnalysisTiming,
        query: JitterQueryRange? = nil, provenance: JitterInputProvenance = .init(),
        sourceUnavailability: UnavailabilityReason? = nil
    ) throws -> JitterAnalysisResult {
        try evaluate(
            periods, timing: dependencyTiming, query: query, provenance: provenance,
            sourceUnavailability: sourceUnavailability, requested: .all)
    }

    /// Computes only the requested numerator while preserving all coverage counts.
    /// Other estimates explicitly have status `notRequested`.
    public func analyze(
        _ variant: JitterVariant, periods: UnsafeBufferPointer<JitterPeriodInput>,
        dependencyTiming: AnalysisTiming, query: JitterQueryRange? = nil,
        provenance: JitterInputProvenance = .init(),
        sourceUnavailability: UnavailabilityReason? = nil
    ) throws -> JitterAnalysisResult {
        try evaluate(
            periods, timing: dependencyTiming, query: query, provenance: provenance,
            sourceUnavailability: sourceUnavailability, requested: .init(variant))
    }

    private func evaluate(
        _ periods: UnsafeBufferPointer<JitterPeriodInput>, timing: AnalysisTiming,
        query requestedQuery: JitterQueryRange?, provenance: JitterInputProvenance,
        sourceUnavailability: UnavailabilityReason?, requested: JitterRequestedVariants
    ) throws -> JitterAnalysisResult {
        guard !busy else { throw JitterError.reentrantCall }
        busy = true
        defer { busy = false }
        guard periods.count <= maximumPeriodCount else { throw JitterError.capacityExceeded }
        guard timing.source.sampleRate == Double(configuration.sampleRate), analyzedCount < .max
        else {
            throw JitterError.unexpectedContext
        }
        let query =
            try requestedQuery
            ?? JitterQueryRange(startSeconds: 0, endSeconds: timing.source.durationSeconds)
        guard query.endSeconds <= timing.source.durationSeconds,
            configuration.rollingWindowDurationSeconds.map({
                query.startSeconds >= max(0, query.endSeconds - $0)
            }) ?? true
        else { throw JitterError.unexpectedContext }
        // Validate the whole call before changing execution state. Rejected source
        // intervals may extend outside acquisition only when explicitly identified.
        for i in periods.indices {
            let p = periods[i]
            guard i == 0 || periods[i - 1].endSeconds <= p.startSeconds else {
                throw JitterError.invalidInput
            }
            if p.startSeconds < 0 || p.endSeconds > timing.source.durationSeconds {
                guard p.rejections.contains(.missingAcquisition) else {
                    throw JitterError.unexpectedContext
                }
            }
        }
        var sourceRejections = JitterRejectionCounts()
        for i in periods.indices {
            let p = periods[i]
            let selected = p.startSeconds >= query.startSeconds && p.endSeconds <= query.endSeconds
            var reasons = p.rejections
            if timing.includedSampleCount == 0 { reasons.insert(.excluded) }
            records[i] = JitterKernelPeriod(
                durationSeconds: p.durationSeconds, selected: selected,
                reliable: reasons.isEmpty,
                connectsToPrevious: i > 0 && p.runID == periods[i - 1].runID
                    && p.startSeconds == periods[i - 1].endSeconds)
            if selected { sourceRejections.add(reasons) }
        }
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 50
        metadata.frameSequence = analyzedCount
        metadata.sampleCount = UInt32(clamping: timing.source.sampleCount)
        metadata.elapsedProcessingCount = analyzedCount
        let result = diagnostics.withFrame(metadata, stage: .perturbation) {
            let raw = JitterKernel.evaluate(
                UnsafeBufferPointer(start: records.baseAddress, count: periods.count),
                configuration: configuration, requested: requested)
            return JitterAnalysisResult(
                raw: raw, configuration: configuration, identity: identity,
                timing: timing, query: query, provenance: provenance, inputCount: periods.count,
                sourceRejections: sourceRejections, sourceUnavailability: sourceUnavailability,
                requested: requested)
        }
        analyzedCount += 1
        lastInputCount = periods.count
        return result
    }
}
