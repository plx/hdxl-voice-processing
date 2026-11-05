import Foundation

package final class CepstralStorage<Sample: BinaryFloatingPoint & Sendable> {
    let windowed: UnsafeMutableBufferPointer<Sample>
    let spectrumReal: UnsafeMutableBufferPointer<Sample>
    let spectrumImaginary: UnsafeMutableBufferPointer<Sample>
    let powerSpectrum: UnsafeMutableBufferPointer<Sample>
    let logPowerSpectrum: UnsafeMutableBufferPointer<Sample>
    let signedCepstrum: UnsafeMutableBufferPointer<Sample>
    let powerCepstrum: UnsafeMutableBufferPointer<Sample>
    let bins: UnsafeMutableBufferPointer<FourierBin<Sample>>
    let inverse: UnsafeMutableBufferPointer<Sample>
    let window: PreparedWindow<Sample>
    let fft: PreparedFourierTransform<Sample>
    var validWindow = 0
    var validSpectrum = 0
    var validPower = 0
    var validLog = 0
    var validSigned = 0
    var validCepstrum = 0
    var scalarWorkspaceBytes: Int {
        (windowed.count + spectrumReal.count * 8 + inverse.count + window.specification.sampleCount)
            * MemoryLayout<Sample>.stride + fft.scalarWorkspaceBytes
    }
    init(_ c: PowerCepstrumConfiguration, diagnostics: WorkerDiagnostics) throws {
        window = try PreparedWindow(
            WindowSpecification(
                definition: .praatGaussian2,
                sampleCount: c.frameLength, sampleRate: Double(c.sampleRate), precision: c.precision
            ))
        fft = try PreparedFourierTransform(
            FourierConfiguration(
                length: c.transformLength,
                sampleRate: Double(c.sampleRate), precision: c.precision), diagnostics: diagnostics)
        func allocate(_ count: Int) -> UnsafeMutableBufferPointer<Sample> {
            let result = UnsafeMutableBufferPointer<Sample>.allocate(capacity: count)
            result.initialize(repeating: 0)
            return result
        }
        windowed = allocate(c.transformLength)
        spectrumReal = allocate(c.binCount)
        spectrumImaginary = allocate(c.binCount)
        powerSpectrum = allocate(c.binCount)
        logPowerSpectrum = allocate(c.binCount)
        signedCepstrum = allocate(c.binCount)
        powerCepstrum = allocate(c.binCount)
        inverse = allocate(c.transformLength)
        bins = .allocate(capacity: c.binCount)
        bins.initialize(repeating: FourierBin(real: 0))
    }
    deinit {
        for buffer in [
            windowed, spectrumReal, spectrumImaginary, powerSpectrum,
            logPowerSpectrum, signedCepstrum, powerCepstrum, inverse,
        ] {
            buffer.deinitialize()
            buffer.deallocate()
        }
        bins.deinitialize()
        bins.deallocate()
    }
    func clearValidity() {
        validWindow = 0
        validSpectrum = 0
        validPower = 0
        validLog = 0
        validSigned = 0
        validCepstrum = 0
    }
    func buffer(_ stage: CepstralStage) -> UnsafeMutableBufferPointer<Sample> {
        switch stage {
        case .windowed: windowed
        case .spectrumReal: spectrumReal
        case .spectrumImaginary: spectrumImaginary
        case .powerSpectrum: powerSpectrum
        case .logPowerSpectrum: logPowerSpectrum
        case .signedCepstrum: signedCepstrum
        case .powerCepstrum: powerCepstrum
        }
    }
    func validCount(_ stage: CepstralStage) -> Int {
        switch stage {
        case .windowed: validWindow
        case .spectrumReal, .spectrumImaginary: validSpectrum
        case .powerSpectrum: validPower
        case .logPowerSpectrum: validLog
        case .signedCepstrum: validSigned
        case .powerCepstrum: validCepstrum
        }
    }
}

/// Reusable single-owner worker primitive, not an audio-callback operation.
/// Accepts a conditioned frame with raw pre-emphasis already applied. The whole-input
/// and preview workers perform that conditioning. No F0/voicing gate is applied.
public final class PreparedPowerCepstrum {
    public let configuration: PowerCepstrumConfiguration
    public let identity: ProfileIdentity
    public var scalarWorkspaceBytes: Int { storage.scalarWorkspaceBytes }
    private let storage: CepstralStorage<Double>
    private let diagnostics: WorkerDiagnostics
    private var busy = false

    public convenience init(_ configuration: PowerCepstrumConfiguration) throws {
        try self.init(configuration, diagnostics: WorkerDiagnostics())
    }
    package init(_ configuration: PowerCepstrumConfiguration, diagnostics: WorkerDiagnostics) throws
    {
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.diagnostics = diagnostics
        self.storage = try CepstralStorage(configuration, diagnostics: diagnostics)
    }

    /// Finite short input emits insufficientData without inventing a padded measurement.
    /// Nonfinite input or oversized input is rejected before scratch or callback mutation.
    /// Reentry is rejected, preserving all borrowed values until the callback returns.
    public func analyze(
        _ conditioned: UnsafeBufferPointer<Double>, context: CepstralFrameContext,
        emit: (BorrowedPowerCepstrum<Double>) -> Void
    ) throws {
        try analyze(conditioned, context: context, profile: identity, emit: emit)
    }
    package func analyze(
        _ conditioned: UnsafeBufferPointer<Double>, context: CepstralFrameContext,
        profile: ProfileIdentity, emit: (BorrowedPowerCepstrum<Double>) -> Void
    ) throws {
        guard !busy else { throw CepstrumError.reentrantCall }
        guard conditioned.count <= configuration.frameLength else {
            throw CepstrumError.invalidBufferSize
        }
        guard conditioned.count == context.suppliedAnalysisSampleCount else {
            throw CepstrumError.unexpectedInterval
        }
        for value in conditioned where !value.isFinite { throw CepstrumError.nonfiniteInput }
        guard conditioned.isEmpty || context.timing.includedSampleCount > 0 else {
            throw CepstrumError.unexpectedInterval
        }
        busy = true
        defer { busy = false }
        storage.clearValidity()
        var metadata = DiagnosticMetadata()
        metadata.frameSequence = context.frameIndex
        metadata.sampleCount = UInt32(conditioned.count)
        metadata.profileToken = 33
        metadata.validity = conditioned.count == configuration.frameLength ? .available : .warmup
        let reason = diagnostics.withFrame(metadata) {
            diagnostics.withInterval(.cepstrum) { transform(conditioned) }
        }
        emit(
            BorrowedPowerCepstrum(
                configuration: configuration, profile: profile,
                context: context, unavailability: reason, stages: storage))
    }

    package func emitUnavailable(
        _ reason: UnavailabilityReason, context: CepstralFrameContext,
        profile: ProfileIdentity, emit: (BorrowedPowerCepstrum<Double>) -> Void
    ) throws {
        guard !busy else { throw CepstrumError.reentrantCall }
        busy = true
        defer { busy = false }
        storage.clearValidity()
        emit(
            BorrowedPowerCepstrum(
                configuration: configuration, profile: profile,
                context: context, unavailability: reason, stages: storage))
    }

    private func transform(_ input: UnsafeBufferPointer<Double>) -> UnavailabilityReason? {
        let c = configuration
        let s = storage
        guard input.count == c.frameLength else { return .insufficientData }
        // Neumaier compensation in the working precision. An overflow is explicitly
        // unavailable; it cannot silently become a finite or all-zero cepstrum.
        var sum: Double = 0
        var correction: Double = 0
        var isZero = true
        for x in input {
            isZero = isZero && x == 0
            let next = sum + x
            correction += abs(sum) >= abs(x) ? (sum - next) + x : (x - next) + sum
            sum = next
        }
        let mean = (sum + correction) / Double(input.count)
        guard mean.isFinite else { return .analysisFailure }
        for i in input.indices {
            s.windowed[i] = input[i] - mean
            guard s.windowed[i].isFinite else { return .analysisFailure }
        }
        do {
            _ = try s.window.write(
                UnsafeBufferPointer(rebasing: s.windowed[0..<input.count]),
                into: s.windowed)
            s.validWindow = s.windowed.count
            _ = try s.fft.forwardReal(UnsafeBufferPointer(s.windowed), into: s.bins)
            let dt = Double(1 / Double(c.sampleRate))
            for k in 0..<c.binCount {
                let re = s.bins[k].real * dt
                let im = s.bins[k].imaginary * dt
                guard re.isFinite, im.isFinite else { return .analysisFailure }
                s.spectrumReal[k] = re
                s.spectrumImaginary[k] = im
                s.validSpectrum += 1
            }
            for k in 0..<c.binCount {
                let re = s.spectrumReal[k]
                let im = s.spectrumImaginary[k]
                let power = 2 * (re * re + im * im)
                guard power.isFinite else { return .analysisFailure }
                s.powerSpectrum[k] = power
                s.validPower += 1
            }
            for k in 0..<c.binCount {
                let operand = Double(s.powerSpectrum[k]) + (k == c.binCount - 1 ? 0 : 1e-300)
                guard operand > 0 else { return isZero ? .silence : .analysisFailure }
                let value = Double(log(operand))
                guard value.isFinite else { return .analysisFailure }
                s.logPowerSpectrum[k] = value
                s.bins[k] = FourierBin(real: value)
                s.validLog += 1
            }
            try s.fft.inverseReal(UnsafeBufferPointer(s.bins), into: s.inverse)
            for k in 0..<c.binCount {
                let value = s.inverse[k] * Double(c.sampleRate)
                guard value.isFinite else { return .analysisFailure }
                s.signedCepstrum[k] = value
                s.validSigned += 1
            }
            for k in 0..<c.binCount {
                let value = s.signedCepstrum[k] * s.signedCepstrum[k]
                guard value.isFinite else { return .analysisFailure }
                s.powerCepstrum[k] = value
                s.validCepstrum += 1
            }
            return nil
        } catch { return .analysisFailure }
    }
}
