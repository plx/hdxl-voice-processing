#if KernelBenchmarks
    import Foundation
    import HDXLVoiceProcessing

    /// Owned non-COW storage. A measured closure retains its own instance, including its output.
    final class Buffer<Element> {
        let values: UnsafeMutableBufferPointer<Element>
        var input: UnsafeBufferPointer<Element> { UnsafeBufferPointer(values) }
        init(_ array: [Element]) {
            values = .allocate(capacity: array.count)
            _ = values.initialize(from: array)
        }
        deinit {
            values.deinitialize()
            values.deallocate()
        }
        func restore(from source: Buffer<Element>) {
            precondition(values.count == source.values.count)
            values.baseAddress!.update(from: source.input.baseAddress!, count: values.count)
        }
    }

    public final class KernelTrial {
        public let expected: Double
        public let reset: () -> Void
        public let run: () throws -> Double

        init(expected: Double, reset: @escaping () -> Void = {}, run: @escaping () throws -> Double)
        {
            self.expected = expected
            self.reset = reset
            self.run = run
        }
    }

    /// A non-inlined control keeps the same closure call, loop and checksum consumption as a kernel.
    @inline(never) private func control(_ value: Double) -> Double { value }

    extension KernelCase {
        public func makeTrial() throws -> KernelTrial {
            switch operation {
            case .control: return KernelTrial(expected: 1) { control(1) }
            case .meanRemoval, .logPower, .inverseCepstrum, .peakDiscrete, .peakParabolic,
                .backgroundFit:
                return try cepstralTrial()
            default:
                return precision == .float32
                    ? try makeTrial(Float.self) : try makeTrial(Double.self)
            }
        }

        private func makeTrial<S: BinaryFloatingPoint & Sendable>(_ type: S.Type) throws
            -> KernelTrial
        {
            let amplitude = nearFloor ? (precision == .float32 ? 1e-17 : 1e-146) : 0.5
            switch operation {
            case .fftPrepare, .fftForward, .fftInverse, .splitReal, .power, .magnitude:
                return try fourierTrial(type, amplitude: amplitude)
            case .interleavedSelect, .interleavedMix, .planarSelect, .planarMix:
                return channelTrial(type)
            case .preEmphasis, .resample, .resamplerPrepare:
                return try conditioningTrial(type)
            case .filter, .levelReduction, .filterPrepare:
                return try levelTrial(type, amplitude: amplitude)
            default: return try framingTrial(type)
            }
        }

        func framingTrial<S: BinaryFloatingPoint & Sendable>(_ type: S.Type) throws -> KernelTrial {
            let n = inputSamples
            let h = hop!
            let mid = n / 2
            let signal = Buffer((0..<n).map { S(Double($0 % 31 - 15) / 16) })
            let window = try WindowSpecification(
                definition: .praatGaussian2, sampleCount: n,
                sampleRate: Double(sourceRate), precision: precision)
            switch operation {
            case .windowCopy, .windowInPlace:
                let prepared = try PreparedWindow<S>(window)
                let scratch = Buffer(Array(repeating: S.zero, count: n))
                let expected = Double(signal.values[mid] * prepared.coefficientSnapshot()[mid])
                if operation == .windowInPlace {
                    return KernelTrial(expected: expected) {
                        scratch.restore(from: signal)
                    } run: {
                        try prepared.write(scratch.input, into: scratch.values)
                        return Double(scratch.values[mid])
                    }
                }
                return KernelTrial(expected: expected) {
                    try prepared.write(signal.input, into: scratch.values)
                    return Double(scratch.values[mid])
                }
            case .ownedWindow:
                var owned: [S] = []
                return KernelTrial(expected: Double(signal.values[mid])) {
                    owned = Array(signal.input)
                    return Double(owned[mid])
                }
            default:
                let ring = try KernelBenchmarkRing<S>(window)
                let wrapped = operation == .ringWriteWrapped || operation == .ringReadWrapped
                let offset = wrapped ? min(h, n - 1) : 0
                ring.resetCursor(to: offset)
                ring.append(signal.input)
                switch operation {
                case .ringWriteWrapped, .ringWriteContiguous:
                    return KernelTrial(expected: Double(signal.values[mid])) {
                        ring.append(signal.input)
                        return Double(ring.storedSample(at: (offset + mid) % n))
                    }
                case .ringReadWrapped, .ringReadContiguous:
                    return KernelTrial(expected: Double(signal.values[mid])) {
                        Double(ring.read(count: n, sample: mid))
                    }
                case .ringOverlap:
                    return KernelTrial(expected: Double(signal.values[h / 2])) {
                        ring.resetCursor(to: 0)
                        ring.append(signal.input)
                    } run: {
                        ring.append(UnsafeBufferPointer(rebasing: signal.input[..<h]))
                        return Double(ring.read(count: n, sample: n - h + h / 2))
                    }
                default: preconditionFailure("Unexpected framing operation")
                }
            }
        }

        func channelTrial<S: BinaryFloatingPoint & Sendable>(_ type: S.Type) -> KernelTrial {
            let n = inputSamples
            let left = Buffer((0..<n).map { S(Double($0 % 17 - 8) / 16) })
            let right = Buffer((0..<n).map { S(Double($0 % 13 + 1) / 16) })
            let interleaved = Buffer((0..<n).flatMap { [left.values[$0], right.values[$0]] })
            let output = Buffer(Array(repeating: S.zero, count: n))
            let selected = (operation == .interleavedSelect || operation == .planarSelect) ? 1 : nil
            let mid = n / 2
            let expected =
                selected == nil
                ? (Double(left.values[mid]) + Double(right.values[mid])) / 2
                : Double(right.values[mid])
            if operation == .interleavedSelect || operation == .interleavedMix {
                return KernelTrial(expected: expected) {
                    PreparedAnalysisSchedule<S>.copyMonoForBenchmark(
                        channels: 2, selected: selected,
                        sampleAt: { i, c in interleaved.values[2 * i + c] }, into: output.values)
                    return Double(output.values[mid])
                }
            }
            let planes = Buffer([left.input, right.input])
            return KernelTrial(expected: expected) {
                withExtendedLifetime((left, right)) {
                    PreparedAnalysisSchedule<S>.copyMonoForBenchmark(
                        channels: 2, selected: selected,
                        sampleAt: { i, c in planes.values[c][i] }, into: output.values)
                }
                return Double(output.values[mid])
            }
        }
    }
#endif
