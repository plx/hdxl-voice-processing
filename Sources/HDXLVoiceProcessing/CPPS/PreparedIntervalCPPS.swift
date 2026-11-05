/// Complete PCM-to-CPPS pipeline for one declared interval. Input chunks are
/// contiguous; processing waits for the entire interval because the conditioning
/// recipe is noncausal. Smoothing itself uses bounded storage independent of length.
public final class PreparedIntervalCPPS<Sample: BinaryFloatingPoint & Sendable> {
    public let profile: CPPSProfile
    private let smoother: PreparedCPPS
    public var layout: CPPSLayout { smoother.layout }
    public var smoothingScalarWorkspaceBytes: Int { smoother.scalarWorkspaceBytes }
    public var smoothingRecordWorkspaceBytes: Int { smoother.recordWorkspaceBytes }
    private let cepstrogram: PreparedIntervalCepstrogram<Sample>
    private var callbackError: (any Error)?
    private var busy = false
    private var failed = false
    public var source: SourceInterval { cepstrogram.source }
    public var receivedSampleCount: Int { cepstrogram.receivedSampleCount }
    public var scalarWorkspaceBytes: Int {
        cepstrogram.scalarWorkspaceBytes + smoother.scalarWorkspaceBytes
    }

    public convenience init(profile: CPPSProfile, source: SourceInterval) throws {
        try self.init(profile: profile, source: source, diagnostics: WorkerDiagnostics())
    }
    package init(profile: CPPSProfile, source: SourceInterval, diagnostics: WorkerDiagnostics)
        throws
    {
        self.profile = profile
        cepstrogram = try PreparedIntervalCepstrogram(
            configuration: profile.cepstrogram,
            source: source, diagnostics: diagnostics)
        smoother = try PreparedCPPS(
            profile: profile,
            origin: SourceInterval(
                epoch: source.epoch, startSample: source.startSample,
                sampleCount: 0, sampleRate: source.sampleRate), diagnostics: diagnostics)
    }
    public func append(_ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval) throws {
        guard !busy else { throw CPPSError.reentrantCall }
        guard !failed else { throw CPPSError.invalidState }
        try cepstrogram.append(samples, interval: interval)
    }
    @discardableResult public func finish(emit: (BorrowedCPPSOutput) -> Void) throws
        -> CPPSCompletion
    {
        guard !busy else { throw CPPSError.reentrantCall }
        guard !failed else { throw CPPSError.invalidState }
        guard receivedSampleCount == source.sampleCount else { throw CPPSError.incompleteInput }
        busy = true
        defer {
            busy = false
            callbackError = nil
        }
        do {
            let upstream = try cepstrogram.finish { frame in
                guard callbackError == nil else { return }
                do { try smoother.append(frame, emit: emit) } catch { callbackError = error }
            }
            if let callbackError { throw callbackError }
            return try smoother.finish(
                source: source, expectedFrameCount: Int(upstream.emittedFrameCount), emit: emit)
        } catch {
            failed = true
            throw error
        }
    }
    /// Reuses the prepared whole-interval conditioner for the same sample count.
    public func reset(source: SourceInterval) throws {
        guard !busy else { throw CPPSError.reentrantCall }
        try cepstrogram.reset(source: source)
        try smoother.reset(
            origin: SourceInterval(
                epoch: source.epoch, startSample: source.startSample,
                sampleCount: 0, sampleRate: source.sampleRate))
        failed = false
    }
}
