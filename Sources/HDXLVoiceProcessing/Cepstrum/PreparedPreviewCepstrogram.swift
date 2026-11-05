import Foundation

private final class PreviewCepstralStorage<Sample: BinaryFloatingPoint & Sendable> {
    let conditioner: PreparedPreviewConditioner<Double>
    let framer: PCMFramer<Double>
    let kernel: PreparedPowerCepstrum
    let conversion: CepstralInputConversion
    let conditioned: UnsafeMutableBufferPointer<Double>
    var previous: Double = 0
    var hasPrevious = false
    var scalarWorkspaceBytes: Int {
        conditioner.scalarWorkspaceBytes + kernel.scalarWorkspaceBytes
            + conversion.scalarWorkspaceBytes
            + (3 * kernel.configuration.frameLength + conditioned.count)
            * MemoryLayout<Double>.stride
    }
    init(
        configuration: CepstrogramConfiguration, layout: PreviewConditioningLayout,
        epoch: StreamEpoch, startSample: Int64, diagnostics: WorkerDiagnostics
    ) throws {
        conversion = CepstralInputConversion(precision: configuration.inputPrecision)
        conditioner = try PreparedPreviewConditioner(
            layout: layout, epoch: epoch,
            startSample: startSample, diagnostics: diagnostics)
        let framing = try FramingConfiguration(
            window: WindowSpecification(
                definition: .praatGaussian2,
                sampleCount: configuration.frame.frameLength,
                sampleRate: Double(configuration.frame.sampleRate),
                precision: configuration.frame.precision),
            hopLength: configuration.previewHopLength!,
            partialWindowPolicy: .emitUnavailable)
        framer = try PCMFramer(configuration: framing, epoch: epoch, diagnostics: diagnostics)
        kernel = try PreparedPowerCepstrum(configuration.frame, diagnostics: diagnostics)
        conditioned = .allocate(capacity: layout.outputBlockCapacity)
        conditioned.initialize(repeating: 0)
    }
    deinit {
        conditioned.deinitialize()
        conditioned.deallocate()
    }
}

public struct CepstrogramProcessReport: Sendable, Hashable {
    public let consumedSampleCount: Int
    public let emittedFrameCount: UInt64
    public let isCancelled: Bool
}

/// Bounded finite-FIR streaming preview. It is a different numerical profile from
/// whole-interval Praat conditioning. FIR support and boundary extension are explicit;
/// sample values and integer frame locations do not depend on delivery chunk sizes.
/// All operations are synchronous on one worker, never on an audio capture callback.
public final class PreparedPreviewCepstrogram<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: CepstrogramConfiguration
    public let conditioningLayout: PreviewConditioningLayout
    public let identity: ProfileIdentity
    public private(set) var origin: SourceInterval
    public var scalarWorkspaceBytes: Int { storage?.scalarWorkspaceBytes ?? 0 }
    public var receivedSampleCount: Int64 {
        storage?.conditioner.receivedSampleCount ?? receivedAtCancellation
    }
    public var isCancelled: Bool { state == .cancelled }
    private var receivedAtCancellation: Int64 = 0
    private var storage: PreviewCepstralStorage<Sample>?
    private enum State { case prepared, finished, failed, cancelled }
    private var state = State.prepared
    private var busy = false
    private var emitted: UInt64 = 0
    private var unavailable: UInt64 = 0
    private var complete: UInt64 = 0
    private var completion: CepstrogramCompletion?
    // Shared by the two finalization callbacks; prepared storage avoids a heap box.
    private var finalizationError: (any Error)?
    private let diagnostics: WorkerDiagnostics

    public convenience init(
        configuration: CepstrogramConfiguration, epoch: StreamEpoch,
        startSample: Int64 = 0, outputBlockCapacity: Int = 256
    ) throws {
        try self.init(
            configuration: configuration, epoch: epoch, startSample: startSample,
            outputBlockCapacity: outputBlockCapacity, diagnostics: WorkerDiagnostics())
    }
    package init(
        configuration: CepstrogramConfiguration, epoch: StreamEpoch,
        startSample: Int64 = 0, outputBlockCapacity: Int = 256, diagnostics: WorkerDiagnostics
    ) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else {
            throw CepstrumError.precisionMismatch
        }
        guard configuration.previewHopLength != nil else {
            throw CepstrumError.invalidConfiguration
        }
        self.configuration = configuration
        self.conditioningLayout = try PreviewConditioningLayout(
            configuration: configuration.conditioning,
            outputBlockCapacity: outputBlockCapacity)
        self.identity = try configuration.identity()
        self.origin = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: Double(configuration.conditioning.sourceSampleRate))
        self.diagnostics = diagnostics
        self.storage = try PreviewCepstralStorage(
            configuration: configuration, layout: conditioningLayout,
            epoch: epoch, startSample: startSample, diagnostics: diagnostics)
    }

    /// A gap or invalid PCM rejects the complete chunk before mutation. A callback may
    /// cancel; the returned count identifies how much source input was actually consumed.
    @discardableResult public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (BorrowedPowerCepstrum<Double>) -> Void
    ) throws -> CepstrogramProcessReport {
        guard !busy else { throw CepstrumError.reentrantCall }
        guard state == .prepared, let storage else { throw CepstrumError.invalidState }
        guard interval.epoch == origin.epoch, interval.sampleRate == origin.sampleRate,
            interval.startSample == origin.startSample + receivedSampleCount,
            interval.sampleCount == Int64(samples.count),
            Int64(samples.count) <= PreviewConditioningLayout.maximumInputSampleCount
                - receivedSampleCount
        else {
            throw CepstrumError.unexpectedInterval
        }
        for sample in samples where !sample.isFinite { throw CepstrumError.nonfiniteInput }
        busy = true
        defer { busy = false }
        let before = emitted
        var callbackError: (any Error)?
        let consumed: Int
        do {
            consumed = try storage.conversion.consume(
                samples, interval: interval, shouldContinue: { state == .prepared },
                body: { converted, chunk in
                    let report = try storage.conditioner.process(converted, interval: chunk) {
                        buffer, block in
                        guard callbackError == nil else { return }
                        do { try consume(buffer, block: block, storage: storage, emit: emit) } catch
                        {
                            callbackError = error
                        }
                    }
                    if let callbackError { throw callbackError }
                    return report.consumedSampleCount
                })
        } catch {
            if state != .cancelled { state = .failed }
            throw error
        }
        return CepstrogramProcessReport(
            consumedSampleCount: consumed,
            emittedFrameCount: emitted - before, isCancelled: state == .cancelled)
    }

    /// Flushes labelled FIR tail extension, then at most one unavailable short frame.
    /// Empty input emits no fabricated frame. Repeated finish never duplicates output.
    @discardableResult public func finish(emit: (BorrowedPowerCepstrum<Double>) -> Void) throws
        -> CepstrogramCompletion
    {
        guard !busy else { throw CepstrumError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw CepstrumError.invalidState
        }
        if let completion { return completion }
        busy = true
        defer { busy = false }
        finalizationError = nil
        defer { finalizationError = nil }
        do {
            _ = try storage.conditioner.finish { buffer, block in
                guard finalizationError == nil else { return }
                do { try consume(buffer, block: block, storage: storage, emit: emit) } catch {
                    finalizationError = error
                }
            }
            if let finalizationError { throw finalizationError }
            if state != .cancelled {
                try storage.framer.finish { buffer, support in
                    do {
                        try analyze(
                            buffer, support: support,
                            deliveryInputCount: storage.conditioner.receivedSampleCount,
                            storage: storage, emit: emit)
                    } catch { finalizationError = error }
                }
            }
            if let finalizationError { throw finalizationError }
        } catch {
            if state != .cancelled { state = .failed }
            throw error
        }
        let source = try SourceInterval(
            epoch: origin.epoch, startSample: origin.startSample,
            sampleCount: receivedSampleCount, sampleRate: origin.sampleRate)
        let result = CepstrogramCompletion(
            source: source, completeFrameCount: complete,
            emittedFrameCount: emitted, unavailableFrameCount: unavailable,
            isCancelled: state == .cancelled)
        if state != .cancelled {
            state = .finished
            completion = result
        }
        return result
    }

    private func consume(
        _ input: UnsafeBufferPointer<Double>, block: PreviewConditionedBlock,
        storage: PreviewCepstralStorage<Sample>, emit: (BorrowedPowerCepstrum<Double>) -> Void
    ) throws {
        let coefficient = configuration.preEmphasisCoefficient
        try diagnostics.withInterval(.preEmphasis) {
            for j in input.indices {
                let value =
                    storage.hasPrevious
                    ? input[j].addingProduct(-coefficient, storage.previous) : input[j]
                guard value.isFinite else { throw CepstrumError.nonfiniteResult }
                storage.conditioned[j] = value
                storage.previous = input[j]
                storage.hasPrevious = true
            }
        }
        let interval = try SourceInterval(
            epoch: origin.epoch, startSample: block.outputStartIndex,
            sampleCount: Int64(input.count), sampleRate: Double(configuration.frame.sampleRate))
        var callbackError: (any Error)?
        try storage.framer.process(
            UnsafeBufferPointer(rebasing: storage.conditioned[0..<input.count]), interval: interval
        ) { buffer, support in
            guard callbackError == nil else { return }
            do {
                try analyze(
                    buffer, support: support, deliveryInputCount: block.deliveryInputSampleCount,
                    storage: storage, emit: emit)
            } catch { callbackError = error }
        }
        if let callbackError { throw callbackError }
    }

    private func analyze(
        _ input: UnsafeBufferPointer<Double>, support: PCMFrameSupport,
        deliveryInputCount: Int64, storage: PreviewCepstralStorage<Sample>,
        emit: (BorrowedPowerCepstrum<Double>) -> Void
    ) throws {
        let start = support.source.startSample
        let firstDependency = max(0, start - 1)
        let lower =
            conditioningLayout.position(firstDependency).left
            - Int64(conditioningLayout.filterRadius)
        let upper =
            conditioningLayout.position(support.source.endSample - 1).left
            + Int64(conditioningLayout.filterRadius) + 1
        let clippedLower = max(0, lower)
        let clippedUpper = min(deliveryInputCount, upper)
        let source = try SourceInterval(
            epoch: origin.epoch, startSample: origin.startSample + clippedLower,
            sampleCount: clippedUpper - clippedLower, sampleRate: origin.sampleRate)
        let center =
            (Double(start) + Double(input.count) / 2) / Double(configuration.frame.sampleRate)
        // Exact rational position keeps delivery latency stable on long streams.
        let position = conditioningLayout.position(start)
        let fraction =
            Double(position.remainder) / Double(2 * configuration.conditioning.ratio.numerator)
        let delay = max(
            0,
            (Double(deliveryInputCount - position.left) - 0.5 - fraction) / origin.sampleRate
                - Double(input.count - 1) / (2 * Double(configuration.frame.sampleRate)))
        let timing = try AnalysisTiming(
            source: source, includedSampleCount: source.sampleCount, effectiveDelaySeconds: delay)
        let context = try CepstralFrameContext(
            origin: origin, timing: timing, frameIndex: support.frameIndex,
            firstAnalysisSampleIndex: start, suppliedAnalysisSampleCount: input.count,
            centerSecondsFromOrigin: center,
            usesBoundaryExtension: lower < 0 || upper > deliveryInputCount)
        try storage.kernel.analyze(input, context: context, profile: identity) { output in
            emitted += 1
            if output.unavailability != nil { unavailable += 1 }
            if support.unavailability == nil { complete += 1 }
            emit(output)
        }
    }

    /// Validates loss in the original input clock, then clears every FIR/frame/filter
    /// state and starts position zero in the next epoch. Missing PCM is never stitched.
    public func reset(for discontinuity: SourceDiscontinuity) throws {
        guard !busy else { throw CepstrumError.reentrantCall }
        guard state != .cancelled, let storage else { throw CepstrumError.invalidState }
        guard discontinuity.previousEpoch == origin.epoch else {
            throw CepstrumError.unexpectedInterval
        }
        if let missing = discontinuity.missingSource {
            guard missing.sampleRate == origin.sampleRate,
                missing.startSample == origin.startSample + receivedSampleCount
            else { throw CepstrumError.unexpectedInterval }
        }
        let boundary = try SourceDiscontinuity(
            previousEpoch: origin.epoch, nextEpoch: discontinuity.nextEpoch,
            reason: discontinuity.reason)
        let nextOrigin = try SourceInterval(
            epoch: discontinuity.nextEpoch, startSample: 0, sampleCount: 0,
            sampleRate: origin.sampleRate)
        try storage.conditioner.reset(epoch: discontinuity.nextEpoch)
        try storage.framer.reset(for: boundary)
        storage.previous = 0
        storage.hasPrevious = false
        origin = nextOrigin
        emitted = 0
        unavailable = 0
        complete = 0
        completion = nil
        state = .prepared
        diagnostics.reset()
    }
    public func cancel() {
        receivedAtCancellation = receivedSampleCount
        state = .cancelled
        storage?.conditioner.cancel()
        storage?.framer.cancel()
        storage = nil
    }
}
