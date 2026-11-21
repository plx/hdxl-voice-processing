#if KernelBenchmarks
    import Foundation
    import FramingWorkload
    import HDXLVoiceProcessing

    public enum KernelOperation: String, Codable, CaseIterable, Sendable {
        case control, windowCopy, windowInPlace
        case ringWriteContiguous, ringWriteWrapped, ringReadContiguous, ringReadWrapped, ringOverlap
        case interleavedSelect, interleavedMix, planarSelect, planarMix
        case levelReduction, filterPrepare, filter, meanRemoval, preEmphasis, resamplerPrepare,
            resample
        case fftPrepare, splitReal, fftForward, fftInverse, magnitude, power, logPower,
            inverseCepstrum
        case peakDiscrete, peakParabolic, backgroundFit, ownedWindow

        /// Each in-place/stateful operation gets its original input or filter history before timing.
        var needsFreshInput: Bool {
            self == .windowInPlace || self == .preEmphasis || self == .filter
                || self == .ringOverlap || self == .ringWriteContiguous || self == .ringWriteWrapped
                || self == .splitReal
        }

    }

    public struct KernelCase: Codable, Sendable {
        public let operation: KernelOperation
        public let precision: AnalysisPrecision
        public let sourceRate: Int
        public let inputSamples: Int
        public let outputSamples: Int
        public let transformLength: Int?
        public let hop: Int?
        public let targetRate: Int?
        public let fitMethod: CPPFitMethod?
        public let nearFloor: Bool
        public let controlBatch: Int?
        public let name: String

        init(
            _ op: KernelOperation, _ precision: AnalysisPrecision, rate: Int = 16_000,
            input: Int, output: Int? = nil, fft: Int? = nil, hop: Int? = nil, target: Int? = nil,
            fit: CPPFitMethod? = nil, nearFloor: Bool = false, controlBatch: Int? = nil
        ) {
            operation = op
            self.precision = precision
            sourceRate = rate
            inputSamples = input
            outputSamples = output ?? input
            transformLength = fft
            self.hop = hop
            targetRate = target
            fitMethod = fit
            self.nearFloor = nearFloor
            self.controlBatch = controlBatch
            var parts = [
                op.rawValue, precision.rawValue, "\(rate)Hz", "in\(input)", "out\(outputSamples)",
            ]
            if let fft { parts.append("fft\(fft)") }
            if let hop { parts.append("hop\(hop)") }
            if let target { parts.append("to\(target)Hz") }
            if let fit { parts.append(fit.rawValue) }
            if let controlBatch { parts.append("batch\(controlBatch)") }
            parts.append(nearFloor ? "nearFloor" : "normal")
            name = parts.joined(separator: ".")
        }

        public static func matrix() throws -> [Self] {
            var cases = (0...7).map {
                Self(.control, .float64, input: 0, output: 0, controlBatch: 1 << $0)
            }
            for p in [AnalysisPrecision.float32, .float64] {
                var geometry = try FramingCase.matrix().compactMap { row -> (Int, Int, Int)? in
                    let configuration = row.configuration
                    guard configuration.window.precision == p,
                        configuration.window.definition == .praatGaussian2
                    else { return nil }
                    return (
                        Int(configuration.window.sampleRate), configuration.window.sampleCount,
                        configuration.hopLength
                    )
                }
                // The cepstrogram grid also has 5/10/20 kHz analysis configurations.
                for rate in [5000, 10_000, 20_000] {
                    let frame = try PowerCepstrumConfiguration(sampleRate: rate)
                    for hopMS in [2, 5, 10, 30] {
                        geometry.append((rate, frame.frameLength, rate * hopMS / 1000))
                    }
                }
                for (rate, n, h) in geometry {
                    for op in [
                        KernelOperation.windowCopy, .windowInPlace, .ownedWindow,
                        .ringWriteContiguous, .ringWriteWrapped, .ringReadContiguous,
                        .ringReadWrapped, .ringOverlap,
                    ] {
                        if op == .ringOverlap && h >= n { continue }
                        cases.append(Self(op, p, rate: rate, input: n, hop: h))
                    }
                }
                for n in [17, 64, 256, 1024] {
                    for op in [
                        KernelOperation.interleavedSelect, .interleavedMix, .planarSelect,
                        .planarMix,
                    ] {
                        cases.append(Self(op, p, rate: 48_000, input: n))
                    }
                }
                for low in [false, true] {
                    for op in [KernelOperation.levelReduction, .filter, .filterPrepare] {
                        cases.append(Self(op, p, rate: 48_000, input: 256, nearFloor: low))
                    }
                    for n in [320, 1000, 1024] {
                        let fft = try FourierConfiguration.lengthPadding(n)
                        for op in [
                            KernelOperation.fftPrepare, .splitReal, .fftForward, .fftInverse,
                            .magnitude, .power,
                        ] {
                            cases.append(
                                Self(
                                    op, p, input: n, output: op == .fftInverse ? fft : fft / 2 + 1,
                                    fft: fft, nearFloor: low))
                        }
                    }
                }
                // The existing Fourier families measure powers of two from 32 through 2²²,
                // except 64. Include the remaining legal radix-2 edge sizes here.
                for n in [2, 4, 8, 16, 64] {
                    for op in [KernelOperation.fftPrepare, .splitReal, .fftForward, .fftInverse] {
                        cases.append(
                            Self(op, p, input: n, output: op == .fftInverse ? n : n / 2 + 1, fft: n)
                        )
                    }
                }
                for rate in [16_000, 44_100, 48_000] {
                    let cfg = try conditioning(p, source: rate, target: 10_000)
                    let layout = try IntervalConditioningLayout(
                        configuration: cfg, inputSampleCount: 1024)
                    for op in [KernelOperation.resamplerPrepare, .resample, .preEmphasis] {
                        cases.append(
                            Self(
                                op, p, rate: rate, input: 1024, output: layout.outputSampleCount,
                                fft: layout.forwardTransformLength, target: 10_000))
                    }
                }
            }
            for rate in [5000, 10_000, 20_000] {
                let frame = try PowerCepstrumConfiguration(sampleRate: rate)
                for low in [false, true] {
                    for op in [KernelOperation.meanRemoval, .logPower, .inverseCepstrum] {
                        cases.append(
                            Self(
                                op, .float64, rate: rate, input: frame.frameLength,
                                output: op == .meanRemoval ? frame.frameLength : frame.binCount,
                                fft: frame.transformLength, nearFloor: low))
                    }
                }
                for op in [KernelOperation.peakDiscrete, .peakParabolic] {
                    cases.append(
                        Self(
                            op, .float64, rate: rate, input: frame.frameLength,
                            output: frame.binCount, fft: frame.transformLength))
                }
                for method in CPPFitMethod.allCases {
                    cases.append(
                        Self(
                            .backgroundFit, .float64, rate: rate, input: frame.frameLength,
                            output: frame.binCount, fft: frame.transformLength, fit: method))
                }
            }
            return cases
        }
    }

    func conditioning(_ p: AnalysisPrecision, source: Int, target: Int, preEmphasis: Double? = 50)
        throws -> ConditioningConfiguration
    {
        try ConditioningConfiguration(
            sourceSampleRate: source, targetSampleRate: target, precision: p,
            method: .praat7WholeInterval(interpolationDepth: 50), preEmphasisFromHz: preEmphasis,
            declaredInputBandwidthHz: Double(source) / 2, requiredInputBandwidthHz: 4000)
    }
#endif
