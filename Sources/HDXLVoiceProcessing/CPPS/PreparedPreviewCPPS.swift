/// Finite-FIR PCM conditioning followed by bounded centered CPPS smoothing. Its
/// complete profile differs from whole-interval CPPS. Chunking changes delivery
/// timing, not frame values or original source positions. Reset discards pending
/// frames at a discontinuity; finish first when a labeled old-interval tail is wanted.
public final class PreparedPreviewCPPS<Sample: BinaryFloatingPoint & Sendable> {
    public let profile: CPPSProfile
    private let smoother: PreparedCPPS
    public var layout: CPPSLayout { smoother.layout }
    public var smoothingScalarWorkspaceBytes: Int { smoother.scalarWorkspaceBytes }
    public var smoothingRecordWorkspaceBytes: Int { smoother.recordWorkspaceBytes }
    private let cepstrogram: PreparedPreviewCepstrogram<Sample>
    private var callbackError: (any Error)?
    private var busy = false
    private var failed = false
    public var origin: SourceInterval { cepstrogram.origin }
    public var receivedSampleCount: Int64 { cepstrogram.receivedSampleCount }
    public var scalarWorkspaceBytes: Int {
        cepstrogram.scalarWorkspaceBytes + smoother.scalarWorkspaceBytes
    }

    public convenience init(
        profile: CPPSProfile, epoch: StreamEpoch, startSample: Int64 = 0,
        outputBlockCapacity: Int = 256
    ) throws {
        try self.init(
            profile: profile, epoch: epoch, startSample: startSample,
            outputBlockCapacity: outputBlockCapacity, diagnostics: WorkerDiagnostics())
    }
    package init(
        profile: CPPSProfile, epoch: StreamEpoch, startSample: Int64 = 0,
        outputBlockCapacity: Int = 256, diagnostics: WorkerDiagnostics
    ) throws {
        self.profile = profile
        cepstrogram = try PreparedPreviewCepstrogram(
            configuration: profile.cepstrogram,
            epoch: epoch, startSample: startSample, outputBlockCapacity: outputBlockCapacity,
            diagnostics: diagnostics)
        smoother = try PreparedCPPS(
            profile: profile, origin: cepstrogram.origin, diagnostics: diagnostics)
    }
    @discardableResult public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (BorrowedCPPSOutput) -> Void
    ) throws -> CepstrogramProcessReport {
        guard !busy else { throw CPPSError.reentrantCall }
        guard !failed else { throw CPPSError.invalidState }
        // Validate before entering the upstream's mutating callback path.
        guard interval.epoch == origin.epoch, interval.sampleRate == origin.sampleRate,
            interval.startSample == origin.startSample + receivedSampleCount,
            interval.sampleCount == Int64(samples.count)
        else { throw CPPSError.unexpectedFrame }
        for value in samples where !value.isFinite { throw CPPSError.invalidInput }
        busy = true
        defer {
            busy = false
            callbackError = nil
        }
        let before = smoother.emittedFrameCount
        do {
            let upstream = try cepstrogram.process(samples, interval: interval) { frame in
                guard callbackError == nil else { return }
                do { try smoother.append(frame, emit: emit) } catch { callbackError = error }
            }
            if let callbackError { throw callbackError }
            return CepstrogramProcessReport(
                consumedSampleCount: upstream.consumedSampleCount,
                emittedFrameCount: UInt64(smoother.emittedFrameCount - before), isCancelled: false)
        } catch {
            failed = true
            throw error
        }
    }
    @discardableResult public func finish(emit: (BorrowedCPPSOutput) -> Void) throws
        -> CPPSCompletion
    {
        guard !busy else { throw CPPSError.reentrantCall }
        guard !failed else { throw CPPSError.invalidState }
        busy = true
        defer {
            busy = false
            callbackError = nil
        }
        do {
            let result = try cepstrogram.finish { frame in
                guard callbackError == nil else { return }
                do { try smoother.append(frame, emit: emit) } catch { callbackError = error }
            }
            if let callbackError { throw callbackError }
            return try smoother.finish(
                source: result.source, expectedFrameCount: Int(result.emittedFrameCount), emit: emit
            )
        } catch {
            failed = true
            throw error
        }
    }
    public func reset(for discontinuity: SourceDiscontinuity) throws {
        guard !busy else { throw CPPSError.reentrantCall }
        try cepstrogram.reset(for: discontinuity)
        try smoother.reset(origin: cepstrogram.origin)
        failed = false
    }
}
