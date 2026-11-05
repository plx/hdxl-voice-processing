/// Borrowed instantaneous spectrum for development or explicitly budgeted export.
/// It is not a final speech decision. The pointer is valid only during inspectSpectrum.
public struct BorrowedLTSFSpectrum {
    public let frameIndex: Int
    public let centerSeconds: Double
    public let source: SourceInterval
    public let firstFrequencyHz: Double
    public let frequencyStepHz: Double
    public let powers: UnsafeBufferPointer<Double>
}

public struct LTSFAppendReport: Sendable, Hashable {
    public let consumedSampleCount: Int
    public let analyzedFrameCount: Int
    public let isCancelled: Bool
}

public struct LTSFCompletion: Sendable, Hashable {
    public let source: SourceInterval
    public let frameCount: Int
    public let unavailability: UnavailabilityReason?
    public let isCancelled: Bool
}

/// Final whole-interval view. Every array is borrowed only for the finish callback.
/// Flatness is the sum of temporal log10(GM/AM) ratios, not a calibrated dB level.
/// Reference intensity uses a 4e-10 numerical power reference and is not SPL.
public struct BorrowedLTSFOutput {
    public let layout: LTSFIntervalLayout
    public let profile: ProfileIdentity
    public let provenance: MaskProvenance
    public let unavailability: UnavailabilityReason?
    public let flatness: UnsafeBufferPointer<Double>
    /// Empty when disabled or unavailable.
    public let referenceIntensityDB: UnsafeBufferPointer<Double>
    public let referenceIntensityThresholdDB: Double?
    public let spectralIntervals: UnsafeBufferPointer<SpeechActivityInterval>
    public let intensityIntervals: UnsafeBufferPointer<SpeechActivityInterval>
    public let speechIntervals: UnsafeBufferPointer<SpeechActivityInterval>

    /// Owned allocation-bearing control-plane export. The original sample timeline
    /// is retained; no selected regions are joined. Too-short input exports an
    /// unspecified selection with algorithmInsufficiency, never an all-speech label.
    public func exportMaskPlan() throws -> MaskPlan {
        var observations: [MaskObservation] = []
        if unavailability != nil {
            if layout.source.sampleCount > 0 {
                observations.append(
                    try MaskObservation(
                        source: layout.source, provenanceIndex: 0,
                        tags: [.algorithmInsufficiency]))
            }
        } else {
            observations.reserveCapacity(speechIntervals.count + intensityIntervals.count)
            for region in speechIntervals {
                if let source = try quantized(region) {
                    observations.append(
                        try MaskObservation(
                            source: source, provenanceIndex: 0,
                            selection: region.isSpeech ? .selected : .rejected,
                            tags: [region.isSpeech ? .speechDetected : .nonSpeechDetected]))
                }
            }
            for region in intensityIntervals {
                if let source = try quantized(region) {
                    observations.append(
                        try MaskObservation(
                            source: source, provenanceIndex: 0,
                            tags: region.isSpeech
                                ? [.energyEligible] : [.silence, .energyIneligible]))
                }
            }
        }
        return try MaskPlan(
            source: layout.source, provenances: [provenance],
            policy: MaskSelectionPolicy(selectionSources: [0]), observations: observations,
            effectiveDelaySeconds: layout.maximumEffectiveDelaySeconds)
    }

    /// xOrigin is relative to source.startSample. This budget applies to the sum
    /// of exported scalar counts; it does not grant unbounded retained history.
    public func exportFeatures(policy: IntermediateOutputPolicy) throws -> [IntermediateSnapshot] {
        guard flatness.count <= policy.maximumScalarCount,
            referenceIntensityDB.count <= policy.maximumScalarCount - flatness.count
        else {
            throw ContractError.intermediateBudgetExceeded
        }
        guard !flatness.isEmpty, let first = layout.firstCenterSeconds else { return [] }
        var output = [
            try IntermediateSnapshot(
                stage: VersionedIdentifier(name: "ltsf-temporal-log10-ratio-sum", version: 1),
                source: layout.source,
                xUnit: .seconds, yUnit: .dimensionless, xOrigin: first,
                xStep: layout.configuration.hopSeconds,
                values: Array(flatness))
        ]
        if !referenceIntensityDB.isEmpty {
            output.append(
                try IntermediateSnapshot(
                    stage: VersionedIdentifier(name: "ltsf-reference-intensity-4e-10", version: 1),
                    source: layout.source,
                    xUnit: .seconds, yUnit: .decibelsRatio, xOrigin: first,
                    xStep: layout.configuration.hopSeconds,
                    values: Array(referenceIntensityDB)))
        }
        return output
    }

    private func quantized(_ region: SpeechActivityInterval) throws -> SourceInterval? {
        let start = try layout.sourceBoundary(relativeSeconds: region.startSeconds)
        let end = try layout.sourceBoundary(relativeSeconds: region.endSeconds)
        guard end > start else { return nil }
        return try SourceInterval(
            epoch: layout.source.epoch, startSample: start,
            sampleCount: end - start, sampleRate: layout.source.sampleRate)
    }
}

/// Single-owner synchronous worker. The complete source length fixes the centered
/// grid; append processes chunks without retaining full PCM. Final speech decisions
/// require finish. This is a worker API, never a real-time capture-callback API.
/// A new discontinuous region requires reset with new source metadata or a new worker.
public final class PreparedLTSFDetector<Sample: BinaryFloatingPoint & Sendable> {
    public private(set) var layout: LTSFIntervalLayout
    public let identity: ProfileIdentity
    public let provenance: MaskProvenance
    public var scalarWorkspaceBytes: Int { storage?.scalarWorkspaceBytes ?? 0 }
    public var receivedSampleCount: Int { storage?.received ?? receivedAtCancellation }
    public var isCancelled: Bool { state == .cancelled }
    private enum State { case prepared, finished, failed, cancelled }
    private var state = State.prepared
    private var storage: LTSFStorage?
    private var completion: LTSFCompletion?
    private var busy = false
    private var receivedAtCancellation = 0
    private let diagnostics: WorkerDiagnostics

    public convenience init(configuration: LTSFConfiguration, source: SourceInterval) throws {
        try self.init(
            configuration: configuration, source: source, diagnostics: WorkerDiagnostics())
    }

    package init(
        configuration: LTSFConfiguration, source: SourceInterval, diagnostics: WorkerDiagnostics
    ) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw MaskError.invalidConfiguration }
        let layout = try LTSFIntervalLayout(configuration: configuration, source: source)
        self.layout = layout
        self.diagnostics = diagnostics
        identity = try configuration.identity()
        provenance = try configuration.provenance()
        storage = try LTSFStorage(layout: layout, diagnostics: diagnostics)
    }

    /// Metadata and finite samples are validated before any mutation. The optional
    /// inspection callback borrows a raw spectrum only; it can cancel this worker.
    @discardableResult
    public func append(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        inspectSpectrum: ((BorrowedLTSFSpectrum) -> Void)? = nil
    ) throws -> LTSFAppendReport {
        guard !busy else { throw MaskError.reentrantCall }
        guard state == .prepared, let storage else { throw MaskError.invalidState }
        guard interval.epoch == layout.source.epoch,
            interval.sampleRate == layout.source.sampleRate,
            interval.startSample == layout.source.startSample + Int64(storage.received),
            interval.sampleCount == Int64(samples.count),
            interval.endSample <= layout.source.endSample
        else { throw MaskError.unexpectedInterval }
        for sample in samples where !sample.isFinite { throw MaskError.nonfiniteInput }
        busy = true
        defer { busy = false }
        if layout.unavailability != nil {
            storage.received += samples.count
            return LTSFAppendReport(
                consumedSampleCount: samples.count, analyzedFrameCount: 0, isCancelled: false)
        }
        let before = storage.spectraCount
        var consumed = 0
        do {
            while consumed < samples.count && state == .prepared {
                guard storage.spectraCount < layout.frameCount else {
                    storage.received += samples.count - consumed
                    consumed = samples.count
                    break
                }
                let frameIndex = storage.spectraCount
                let start = try layout.firstSampleOffset(frameIndex: frameIndex)
                let end = start + layout.spectral.frameLength
                guard start >= 0, Int64(end) <= layout.source.sampleCount else {
                    throw MaskError.invalidState
                }
                let count = min(samples.count - consumed, end - storage.received)
                guard count > 0 else { throw MaskError.invalidState }
                storage.appendPCM(
                    UnsafeBufferPointer(rebasing: samples[consumed..<(consumed + count)]))
                consumed += count
                if storage.received == end {
                    var metadata = DiagnosticMetadata()
                    metadata.profileToken = 34
                    metadata.frameSequence = UInt64(frameIndex)
                    metadata.sampleCount = UInt32(layout.spectral.frameLength)
                    let spectrum = try diagnostics.withFrame(metadata) {
                        try diagnostics.withInterval(.speechActivity) {
                            try storage.analyzeSpectrum()
                        }
                    }
                    if let inspectSpectrum {
                        let source = try SourceInterval(
                            epoch: interval.epoch,
                            startSample: layout.source.startSample + Int64(start),
                            sampleCount: Int64(layout.spectral.frameLength),
                            sampleRate: interval.sampleRate)
                        let output = BorrowedLTSFSpectrum(
                            frameIndex: frameIndex,
                            centerSeconds: try layout.centerSeconds(frameIndex: frameIndex),
                            source: source,
                            firstFrequencyHz: layout.spectral.firstFrequencyHz,
                            frequencyStepHz: layout.spectral.frequencyStepHz, powers: spectrum)
                        withExtendedLifetime(storage) { inspectSpectrum(output) }
                    }
                }
            }
        } catch {
            state = .failed
            throw error
        }
        return LTSFAppendReport(
            consumedSampleCount: consumed, analyzedFrameCount: storage.spectraCount - before,
            isCancelled: isCancelled)
    }

    /// Emits once. Repeated finish returns the original completion without another
    /// emission. Unavailable output has empty arrays, never values from a prior use.
    @discardableResult
    public func finish(emit: (BorrowedLTSFOutput) -> Void) throws -> LTSFCompletion {
        guard !busy else { throw MaskError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw MaskError.invalidState
        }
        if let completion { return completion }
        guard Int64(storage.received) == layout.source.sampleCount else {
            throw MaskError.insufficientData
        }
        busy = true
        defer { busy = false }
        do {
            if layout.unavailability == nil {
                guard storage.spectraCount == layout.frameCount else {
                    throw MaskError.invalidState
                }
                var metadata = DiagnosticMetadata()
                metadata.profileToken = 34
                metadata.frameSequence = 0
                metadata.sampleCount = UInt32(clamping: layout.source.sampleCount)
                try diagnostics.withFrame(metadata) {
                    try diagnostics.withInterval(.maskIntervals) {
                        try storage.finishFeatures()
                        try storage.buildIntervals()
                    }
                }
            }
        } catch {
            state = .failed
            throw error
        }
        state = .finished
        let featureCount = layout.unavailability == nil ? storage.featureCount : 0
        let intensityCount =
            layout.configuration.relativeIntensityThresholdDB == nil ? 0 : featureCount
        let output = BorrowedLTSFOutput(
            layout: layout, profile: identity, provenance: provenance,
            unavailability: layout.unavailability,
            flatness: UnsafeBufferPointer(start: storage.flatness.baseAddress, count: featureCount),
            referenceIntensityDB: UnsafeBufferPointer(
                start: storage.intensity.baseAddress, count: intensityCount),
            referenceIntensityThresholdDB: storage.intensityThreshold,
            spectralIntervals: storage.spectralIntervals.values,
            intensityIntervals: storage.intensityIntervals.values,
            speechIntervals: storage.combinedIntervals.values)
        withExtendedLifetime(storage) { emit(output) }
        let report = LTSFCompletion(
            source: layout.source, frameCount: featureCount,
            unavailability: layout.unavailability, isCancelled: isCancelled)
        completion = report
        return report
    }

    /// Reuse allocations for an equally sized independent region. Validation is
    /// transactional; all source positions and epoch metadata come from the new source.
    public func reset(source: SourceInterval) throws {
        guard !busy else { throw MaskError.reentrantCall }
        guard let storage, source.sampleCount == layout.source.sampleCount else {
            throw MaskError.invalidState
        }
        let next = try LTSFIntervalLayout(configuration: layout.configuration, source: source)
        storage.reset()
        storage.layout = next
        layout = next
        completion = nil
        state = .prepared
        diagnostics.reset()
    }

    /// Idempotent. Active borrowed views remain alive until their callback returns.
    public func cancel() {
        if state == .cancelled { return }
        receivedAtCancellation = storage?.received ?? receivedAtCancellation
        state = .cancelled
        storage = nil
        completion = nil
        diagnostics.event(.cancelled, validity: .cancelled)
    }
}
