#if KernelBenchmarks
    import Benchmark
    import Foundation
    import HDXLVoiceProcessing

    extension KernelCase {
        func fourierTrial<S: BinaryFloatingPoint & Sendable>(_ type: S.Type, amplitude: Double)
            throws -> KernelTrial
        {
            let n = transformLength!
            let m = inputSamples
            let bins = n / 2 + 1
            let k = min(3, n / 2)
            let config = try FourierConfiguration(
                length: n, sampleRate: Double(sourceRate), precision: precision)
            if operation == .fftPrepare {
                return KernelTrial(expected: Double(2 * n * MemoryLayout<S>.stride)) {
                    let prepared = try PreparedFourierTransform<S>(config)
                    blackHole(prepared)
                    return Double(prepared.scalarWorkspaceBytes)
                }
            }
            let plan = try PreparedFourierTransform<S>(config)
            // A shifted impulse has a known phase and unit magnitude in every DFT bin.
            let input = Buffer(Array(repeating: S.zero, count: m))
            input.values[1] = S(amplitude)
            let a = Double(input.values[1])
            let output = Buffer(Array(repeating: FourierBin<S>(real: 0), count: bins))
            let time = Buffer(Array(repeating: S.zero, count: n))
            switch operation {
            case .splitReal:
                for i in 0..<m { input.values[i] = S(amplitude * Double(i % 7 + 1) / 8) }
                let firstPair = Double(input.values[0]) + 2 * Double(input.values[1])
                return KernelTrial(expected: firstPair) {
                    plan.resetPackedPairsForBenchmark(to: -1)
                } checkOutput: {
                    for j in 0..<n / 2 {
                        let pair = plan.packedPairForBenchmark(at: j)
                        let even = 2 * j < m ? input.values[2 * j] : 0
                        let odd = 2 * j + 1 < m ? input.values[2 * j + 1] : 0
                        guard pair.even == even else {
                            throw KernelError.sample(
                                name, actual: Double(pair.even), expected: Double(even))
                        }
                        guard pair.odd == odd else {
                            throw KernelError.sample(
                                name, actual: Double(pair.odd), expected: Double(odd))
                        }
                    }
                } run: {
                    let values = plan.packRealForBenchmark(input.input, at: 0)
                    return Double(values.even) + 2 * Double(values.odd)
                }
            case .fftForward:
                let phase = -2 * Double.pi * Double(k) / Double(n)
                return KernelTrial(expected: a * (cos(phase) + 0.25 * sin(phase))) {
                    try plan.forwardReal(input.input, into: output.values)
                    return Double(output.values[k].real) + 0.25 * Double(output.values[k].imaginary)
                }
            case .fftInverse:
                try plan.forwardReal(input.input, into: output.values)
                return KernelTrial(expected: a) {
                    try plan.inverseReal(output.input, into: time.values)
                    return Double(time.values[1])
                }
            case .magnitude, .power:
                let window = try WindowSpecification(
                    definition: .rectangular, sampleCount: m,
                    sampleRate: Double(sourceRate), precision: precision)
                let converter = try PreparedSpectrum<S>(
                    SpectrumConfiguration(transform: config, window: window))
                try plan.forwardReal(input.input, into: output.values)
                let spectrum = Buffer(Array(repeating: S.zero, count: bins))
                if operation == .magnitude {
                    return KernelTrial(expected: a) {
                        try converter.writeMagnitude(output.input, into: spectrum.values)
                        return Double(spectrum.values[k])
                    }
                }
                return KernelTrial(expected: 2 * a * a / Double(n * m)) {
                    try converter.writePower(output.input, into: spectrum.values)
                    return Double(spectrum.values[k])
                }
            default: preconditionFailure("Unexpected Fourier operation")
            }
        }

        func cppProfile() throws -> CPPProfile {
            let settings = try CPPConfiguration(
                interpolation: operation == .peakDiscrete ? .none : .parabolic,
                fitEndSeconds: 0.02, fitMethod: fitMethod ?? .leastSquares)
            return try CPPProfile(
                frame: PowerCepstrumConfiguration(sampleRate: sourceRate), settings: settings)
        }

        func cepstralTrial() throws -> KernelTrial {
            let frame = try PowerCepstrumConfiguration(sampleRate: sourceRate)
            switch operation {
            case .meanRemoval:
                let stage = try PreparedPowerCepstrum(frame)
                let a = nearFloor ? 1e-146 : 0.5
                let signal = Buffer((0..<frame.frameLength).map { $0 % 2 == 0 ? a : 3 * a })
                let expectedMean =
                    a * Double(frame.frameLength + 2 * (frame.frameLength / 2))
                    / Double(frame.frameLength)
                return KernelTrial(expected: a - expectedMean) {
                    stage.removeMeanForBenchmark(signal.input, at: 0) ?? .nan
                }
            case .inverseCepstrum:
                let stage = try PreparedPowerCepstrum(frame)
                let floor = nearFloor ? log(1e-300) : log(0.5)
                let bins = Buffer(Array(repeating: floor, count: frame.binCount))
                bins.values[0] += 1
                bins.values[1] += 0.5
                stage.loadLogSpectrumForBenchmark(bins.input)
                let n = Double(frame.transformLength)
                let expected = Double(frame.sampleRate) * (1 + cos(2 * .pi / n)) / n
                return KernelTrial(expected: expected) {
                    try stage.inverseCepstrumForBenchmark(at: 1) ?? .nan
                }
            case .logPower:
                let stage = try PreparedPowerCepstrum(frame)
                let p = nearFloor ? 1e-302 : 0.5
                let powers = Buffer((0..<frame.binCount).map { $0.isMultiple(of: 3) ? 0 : p })
                powers.values[frame.binCount - 1] = p
                stage.loadPowerForBenchmark(powers.input)
                // Nyquist is the only bin without the additive floor.
                return KernelTrial(expected: log(p + 1e-300) + log(p)) {
                    guard
                        let last = stage.logPowerForBenchmark(at: frame.binCount - 1, isZero: false)
                    else { return .nan }
                    return last + stage.logPowerSampleForBenchmark(at: 1)
                }
            default:
                let worker = try PreparedCPP(cppProfile())
                if operation == .backgroundFit {
                    let line = Buffer((0..<frame.binCount).map { 10 + 0.5 * Double($0) })
                    worker.loadDecibelsForBenchmark(line.input)
                    return KernelTrial(expected: 0.5 * Double(sourceRate) + 10) {
                        let fit = worker.fitForBenchmark()
                        return fit.slope + fit.intercept
                    }
                }
                let center = Double(sourceRate) * 0.008 + 0.25
                let db = Buffer((0..<frame.binCount).map { 100 - pow(Double($0) - center, 2) })
                worker.loadDecibelsForBenchmark(db.input)
                let k = operation == .peakDiscrete ? center.rounded() : center
                return KernelTrial(expected: 100 - pow(k - center, 2) + k) {
                    let peak = worker.peakForBenchmark()
                    return peak.db + peak.q * Double(sourceRate)
                }
            }
        }
    }
#endif
