import Foundation

private final class IntervalCepstralStorage<Sample: BinaryFloatingPoint & Sendable> {
    let conditioner: PreparedIntervalConditioner<Double>
    let kernel: PreparedPowerCepstrum
    let conversion: CepstralInputConversion
    let frame: UnsafeMutableBufferPointer<Double>
    var scalarWorkspaceBytes: Int {
        conditioner.scalarWorkspaceBytes + kernel.scalarWorkspaceBytes
            + conversion.scalarWorkspaceBytes + frame.count * MemoryLayout<Double>.stride
    }
    init(
        configuration: CepstrogramConfiguration, source: SourceInterval,
        diagnostics: WorkerDiagnostics
    ) throws {
        conversion = CepstralInputConversion(precision: configuration.inputPrecision)
        conditioner = try PreparedIntervalConditioner(
            configuration: configuration.conditioning,
            source: source, diagnostics: diagnostics)
        kernel = try PreparedPowerCepstrum(configuration.frame, diagnostics: diagnostics)
        frame = .allocate(capacity: configuration.frame.frameLength)
        frame.initialize(repeating: 0)
    }
    deinit {
        frame.deinitialize()
        frame.deallocate()
    }
}

/// Whole-interval PCM analysis with reference centering. Prepare for a fixed source
/// length, append contiguous chunks, then finish. No output is available before the
/// complete interval arrives. Frames borrow reused scratch; no cepstrogram is retained.
/// The dependency support is conservatively the entire separately conditioned interval.
public final class PreparedIntervalCepstrogram<Sample: BinaryFloatingPoint & Sendable> {
    public let layout: IntervalCepstrogramLayout
    public let identity: ProfileIdentity
    public private(set) var source: SourceInterval
    public var scalarWorkspaceBytes: Int { storage?.scalarWorkspaceBytes ?? 0 }
    public var receivedSampleCount: Int {
        storage?.conditioner.receivedSampleCount ?? receivedAtCancellation
    }
    public var isCancelled: Bool { state == .cancelled }
    private var receivedAtCancellation = 0
    private enum State { case prepared, finished, failed, cancelled }
    private var state = State.prepared
    private var storage: IntervalCepstralStorage<Sample>?
    private let diagnostics: WorkerDiagnostics
    private var busy = false
    private var completion: CepstrogramCompletion?
    // Prepared callback state avoids heap boxes for mutable locals captured through
    // the conditioner and kernel callbacks during finalization.
    private var emitted: UInt64 = 0
    private var unavailable: UInt64 = 0
    private var complete: UInt64 = 0
    private var callbackError: (any Error)?

    public convenience init(configuration: CepstrogramConfiguration, source: SourceInterval) throws
    {
        try self.init(
            configuration: configuration, source: source, diagnostics: WorkerDiagnostics())
    }
    package init(
        configuration: CepstrogramConfiguration, source: SourceInterval,
        diagnostics: WorkerDiagnostics
    ) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else {
            throw CepstrumError.precisionMismatch
        }
        guard let count = Int(exactly: source.sampleCount),
            source.sampleRate == Double(configuration.conditioning.sourceSampleRate)
        else {
            throw CepstrumError.unexpectedInterval
        }
        self.layout = try IntervalCepstrogramLayout(
            configuration: configuration, inputSampleCount: count)
        self.identity = try configuration.identity()
        self.source = source
        self.diagnostics = diagnostics
        self.storage = try IntervalCepstralStorage(
            configuration: configuration, source: source, diagnostics: diagnostics)
    }
    public func append(_ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval) throws {
        guard !busy else { throw CepstrumError.reentrantCall }
        guard state == .prepared, let storage else { throw CepstrumError.invalidState }
        guard interval.epoch == source.epoch, interval.sampleRate == source.sampleRate,
            interval.startSample == source.startSample + Int64(receivedSampleCount),
            interval.sampleCount == Int64(samples.count),
            samples.count <= layout.resampling.inputSampleCount - receivedSampleCount
        else {
            throw CepstrumError.unexpectedInterval
        }
        for sample in samples where !sample.isFinite { throw CepstrumError.nonfiniteInput }
        _ = try storage.conversion.consume(samples, interval: interval) { buffer, chunk in
            try storage.conditioner.append(buffer, interval: chunk)
            return buffer.count
        }
    }

    /// A positive but too-short interval emits one unavailable frame. Repeated finish
    /// returns the original completion without duplicating output. Cancellation from
    /// a callback stops before the next frame and preserves the current borrowed view.
    @discardableResult public func finish(emit: (BorrowedPowerCepstrum<Double>) -> Void) throws
        -> CepstrogramCompletion
    {
        guard !busy else { throw CepstrumError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw CepstrumError.invalidState
        }
        if let completion { return completion }
        guard storage.conditioner.receivedSampleCount == layout.resampling.inputSampleCount else {
            throw CepstrumError.insufficientData
        }
        busy = true
        defer { busy = false }
        let origin = try SourceInterval(
            epoch: source.epoch, startSample: source.startSample,
            sampleCount: 0, sampleRate: source.sampleRate)
        emitted = 0
        unavailable = 0
        complete = 0
        callbackError = nil
        defer { callbackError = nil }
        do {
            try storage.conditioner.finish { resampled, record in
                do {
                    for index in 0..<max(1, layout.frameCount) {
                        guard state != .cancelled else { break }
                        let isShort = layout.frameCount == 0
                        let first =
                            isShort ? 0 : try layout.firstAnalysisSampleIndex(frameIndex: index)
                        let center =
                            isShort
                            ? source.durationSeconds / 2
                            : try layout.centerSeconds(frameIndex: index)
                        let count =
                            isShort
                            ? min(resampled.count, layout.configuration.frame.frameLength - 1)
                            : storage.frame.count
                        let context = try CepstralFrameContext(
                            origin: origin, timing: record.timing,
                            frameIndex: UInt64(index), firstAnalysisSampleIndex: Int64(first),
                            suppliedAnalysisSampleCount: count,
                            centerSecondsFromOrigin: center,
                            usesBoundaryExtension: first < 0 || first + count > resampled.count)
                        let coefficient = layout.configuration.preEmphasisCoefficient
                        var finite = true
                        for j in 0..<count {
                            let i = first + j
                            let value: Double
                            if i < 0 || i >= resampled.count {
                                value = 0
                            } else if i == 0 {
                                value = resampled[i]
                            } else {
                                value = resampled[i].addingProduct(
                                    -coefficient, resampled[i - 1])
                            }
                            storage.frame[j] = value
                            finite = finite && value.isFinite
                        }
                        if finite {
                            try storage.kernel.analyze(
                                UnsafeBufferPointer(rebasing: storage.frame[0..<count]),
                                context: context, profile: identity
                            ) { receive($0, emit: emit) }
                        } else {
                            try storage.kernel.emitUnavailable(
                                .analysisFailure, context: context, profile: identity
                            ) { receive($0, emit: emit) }
                        }
                    }
                } catch { callbackError = error }
            }
            if let callbackError { throw callbackError }
        } catch {
            if state != .cancelled { state = .failed }
            throw error
        }
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
    private func receive(
        _ output: BorrowedPowerCepstrum<Double>, emit: (BorrowedPowerCepstrum<Double>) -> Void
    ) {
        emitted += 1
        if output.unavailability != nil { unavailable += 1 }
        if output.context.suppliedAnalysisSampleCount == layout.configuration.frame.frameLength {
            complete += 1
        }
        emit(output)
    }
    /// Starts a separate interval of the same prepared length. It never joins PCM
    /// across the old and new intervals, even when the caller reuses an epoch.
    public func reset(source: SourceInterval) throws {
        guard !busy else { throw CepstrumError.reentrantCall }
        guard state != .cancelled, let storage else { throw CepstrumError.invalidState }
        try storage.conditioner.reset(source: source)
        self.source = source
        self.completion = nil
        self.state = .prepared
        diagnostics.reset()
    }
    public func cancel() {
        receivedAtCancellation = receivedSampleCount
        state = .cancelled
        storage?.conditioner.cancel()
        storage = nil
    }
}
