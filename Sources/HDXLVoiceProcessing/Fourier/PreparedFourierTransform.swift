import Accelerate

/// Single-owner, synchronous reusable FFT workspace. Intentionally not Sendable.
/// Each concurrent worker must construct and retain its own instance on that worker.
/// All inputs are staged before output writes, including exact in-place complex calls.
/// Output buffers require exact counts. Failures leave caller output unchanged; later calls remain usable.
public final class PreparedFourierTransform<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: FourierConfiguration
    public let identity: ProfileIdentity
    /// Owned scalar storage, excluding opaque vDSP setup tables and object bookkeeping.
    public var scalarWorkspaceBytes: Int { configuration.length * 2 * MemoryLayout<Sample>.stride }
    private let real: UnsafeMutablePointer<Sample>
    private let imaginary: UnsafeMutablePointer<Sample>
    private let floatSetup: FFTSetup?
    private let doubleSetup: FFTSetupD?
    private let log2Length: vDSP_Length
    private let inverseScale: Sample
    private let diagnostics: WorkerDiagnostics

    public convenience init(_ configuration: FourierConfiguration) throws {
        try self.init(configuration, diagnostics: WorkerDiagnostics())
    }

    package init(_ configuration: FourierConfiguration, diagnostics: WorkerDiagnostics) throws {
        guard
            (Sample.self == Float.self && configuration.precision == .float32)
                || (Sample.self == Double.self && configuration.precision == .float64)
        else { throw FourierError.precisionMismatch }
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.log2Length = vDSP_Length(configuration.length.trailingZeroBitCount)
        self.inverseScale = 1 / Sample(configuration.length)
        self.diagnostics = diagnostics
        if Sample.self == Float.self {
            guard let setup = vDSP_create_fftsetup(log2Length, FFTRadix(kFFTRadix2)) else {
                throw FourierError.setupFailed
            }
            floatSetup = setup
            doubleSetup = nil
        } else {
            guard let setup = vDSP_create_fftsetupD(log2Length, FFTRadix(kFFTRadix2)) else {
                throw FourierError.setupFailed
            }
            floatSetup = nil
            doubleSetup = setup
        }
        real = .allocate(capacity: configuration.length)
        imaginary = .allocate(capacity: configuration.length)
        real.initialize(repeating: 0, count: configuration.length)
        imaginary.initialize(repeating: 0, count: configuration.length)
    }

    deinit {
        if let floatSetup { vDSP_destroy_fftsetup(floatSetup) }
        if let doubleSetup { vDSP_destroy_fftsetupD(doubleSetup) }
        real.deinitialize(count: configuration.length)
        imaginary.deinitialize(count: configuration.length)
        real.deallocate()
        imaginary.deallocate()
    }

    /// Input is already conditioned/windowed. Short nonempty input is explicitly zero-padded to N.
    /// Empty input is rejected: a missing frame must not become a valid silence spectrum.
    @discardableResult
    public func forwardReal(
        _ input: UnsafeBufferPointer<Sample>,
        into output: UnsafeMutableBufferPointer<FourierBin<Sample>>
    ) throws -> FourierApplication {
        let n = configuration.length
        guard (1...n).contains(input.count), output.count == configuration.realBinCount else {
            throw FourierError.invalidBufferSize
        }
        for x in input where !x.isFinite { throw FourierError.nonfiniteInput }
        for i in 0..<n / 2 {
            real[i] = 2 * i < input.count ? input[2 * i] : 0
            imaginary[i] = 2 * i + 1 < input.count ? input[2 * i + 1] : 0
        }
        run(realTransform: true, inverse: false)
        // vDSP's real forward result is twice the conventional DFT.
        for i in 0..<n / 2 {
            real[i] *= 0.5
            imaginary[i] *= 0.5
            guard real[i].isFinite, imaginary[i].isFinite else {
                throw FourierError.nonfiniteResult
            }
        }
        output[0] = FourierBin(real: real[0])
        output[n / 2] = FourierBin(real: imaginary[0])
        for i in 1..<n / 2 { output[i] = FourierBin(real: real[i], imaginary: imaginary[i]) }
        return FourierApplication(
            suppliedSampleCount: input.count, zeroPaddingSampleCount: n - input.count)
    }

    /// Conventional one-sided bins, with exactly real DC and Nyquist, reconstruct N real samples.
    /// Negative frequencies are the implicit conjugates. No gain or window correction is applied.
    public func inverseReal(
        _ input: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<Sample>
    ) throws {
        let n = configuration.length
        guard input.count == configuration.realBinCount, output.count == n else {
            throw FourierError.invalidBufferSize
        }
        try validate(input)
        guard input[0].imaginary == 0, input[n / 2].imaginary == 0 else {
            throw FourierError.nonrealEndpoint
        }
        real[0] = input[0].real
        imaginary[0] = input[n / 2].real
        for i in 1..<n / 2 {
            real[i] = input[i].real
            imaginary[i] = input[i].imaginary
        }
        run(realTransform: true, inverse: true)
        for i in 0..<n / 2 {
            real[i] *= inverseScale
            imaginary[i] *= inverseScale
            guard real[i].isFinite, imaginary[i].isFinite else {
                throw FourierError.nonfiniteResult
            }
        }
        for i in 0..<n / 2 {
            output[2 * i] = real[i]
            output[2 * i + 1] = imaginary[i]
        }
    }

    @discardableResult
    public func forwardComplex(
        _ input: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<FourierBin<Sample>>
    ) throws -> FourierApplication {
        try complex(input, into: output, inverse: false)
        return FourierApplication(
            suppliedSampleCount: input.count,
            zeroPaddingSampleCount: configuration.length - input.count)
    }

    /// Full N-bin complex inverse. Output is divided by N; complex input need not be Hermitian.
    public func inverseComplex(
        _ input: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<FourierBin<Sample>>
    ) throws {
        try complex(input, into: output, inverse: true)
    }

    private func complex(
        _ input: UnsafeBufferPointer<FourierBin<Sample>>,
        into output: UnsafeMutableBufferPointer<FourierBin<Sample>>, inverse: Bool
    ) throws {
        let n = configuration.length
        guard inverse ? input.count == n : (1...n).contains(input.count), output.count == n else {
            throw FourierError.invalidBufferSize
        }
        try validate(input)
        for i in input.indices {
            real[i] = input[i].real
            imaginary[i] = input[i].imaginary
        }
        for i in input.count..<n {
            real[i] = 0
            imaginary[i] = 0
        }
        run(realTransform: false, inverse: inverse)
        for i in 0..<n {
            if inverse {
                real[i] *= inverseScale
                imaginary[i] *= inverseScale
            }
            guard real[i].isFinite, imaginary[i].isFinite else {
                throw FourierError.nonfiniteResult
            }
        }
        for i in 0..<n { output[i] = FourierBin(real: real[i], imaginary: imaginary[i]) }
    }

    private func validate(_ input: UnsafeBufferPointer<FourierBin<Sample>>) throws {
        for z in input where !z.real.isFinite || !z.imaginary.isFinite {
            throw FourierError.nonfiniteInput
        }
    }

    private func run(realTransform: Bool, inverse: Bool) {
        diagnostics.withInterval(.fft) {
            let direction = FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD)
            // Preparation permits exactly Float or Double; these are the storage's actual bound types.
            if let floatSetup {
                var split = DSPSplitComplex(
                    realp: UnsafeMutableRawPointer(real).assumingMemoryBound(to: Float.self),
                    imagp: UnsafeMutableRawPointer(imaginary).assumingMemoryBound(to: Float.self))
                if realTransform {
                    vDSP_fft_zrip(floatSetup, &split, 1, log2Length, direction)
                } else {
                    vDSP_fft_zip(floatSetup, &split, 1, log2Length, direction)
                }
            } else if let doubleSetup {
                var split = DSPDoubleSplitComplex(
                    realp: UnsafeMutableRawPointer(real).assumingMemoryBound(to: Double.self),
                    imagp: UnsafeMutableRawPointer(imaginary).assumingMemoryBound(to: Double.self))
                if realTransform {
                    vDSP_fft_zripD(doubleSetup, &split, 1, log2Length, direction)
                } else {
                    vDSP_fft_zipD(doubleSetup, &split, 1, log2Length, direction)
                }
            }
        }
    }
}
