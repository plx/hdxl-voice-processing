import Accelerate
import Foundation

/// An original evaluation of the published sinc/Hermite interpolation equations.
/// Interior coefficients repeat on the exact rational grid; no per-output trigonometric work.
private final class IntervalInterpolator<Sample: BinaryFloatingPoint & Sendable> {
    let depth: Int
    let ratio: ResamplingRatio
    let baseNumerator: Int64
    let denominator: Int64
    let phaseCount: Int
    let coefficients: UnsafeMutableBufferPointer<Sample>
    let scratch: UnsafeMutableBufferPointer<Sample>
    var scalarCount: Int { coefficients.count + scratch.count }

    init(_ layout: IntervalConditioningLayout, depth: Int) {
        self.depth = depth
        ratio = layout.configuration.ratio
        denominator = Int64(2 * ratio.numerator)
        // Zero-based input position of output j:
        // [N*P - (M-1)*Q - P + 2*j*Q] / (2*P).
        baseNumerator =
            Int64(layout.inputSampleCount) * Int64(ratio.numerator)
            - Int64(layout.outputSampleCount - 1) * Int64(ratio.denominator)
            - Int64(ratio.numerator)
        phaseCount = ratio.numerator <= 4096 ? ratio.numerator : 0
        coefficients = .allocate(capacity: phaseCount * 2 * depth)
        coefficients.initialize(repeating: 0)
        scratch = .allocate(capacity: 2 * depth)
        scratch.initialize(repeating: 0)
        if depth >= 3 {
            for phase in 0..<phaseCount {
                let fraction = position(phase).fraction
                writeWeights(
                    fraction: fraction, depth: depth,
                    into: UnsafeMutableBufferPointer(
                        rebasing: coefficients[(phase * 2 * depth)..<((phase + 1) * 2 * depth)]))
            }
        }
    }
    deinit {
        coefficients.deinitialize()
        coefficients.deallocate()
        scratch.deinitialize()
        scratch.deallocate()
    }
    func position(_ output: Int) -> (left: Int, fraction: Double) {
        let numerator = baseNumerator + Int64(2 * ratio.denominator) * Int64(output)
        let remainder = ((numerator % denominator) + denominator) % denominator
        return (Int((numerator - remainder) / denominator), Double(remainder) / Double(denominator))
    }
    private func writeWeights(
        fraction: Double, depth: Int, into output: UnsafeMutableBufferPointer<Sample>
    ) {
        for offset in 0..<(2 * depth) {
            let distance = fraction - Double(offset - depth + 1)
            let angle = .pi * distance
            let sinc = distance == 0 ? 1 : sin(angle) / angle
            output[offset] = Sample(sinc * 0.5 * (1 + cos(angle / (Double(depth) + 0.5))))
        }
    }
    private func dot(_ input: UnsafePointer<Sample>, _ weights: UnsafePointer<Sample>, count: Int)
        -> Sample
    {
        if Sample.self == Float.self {
            var result: Float = 0
            input.withMemoryRebound(to: Float.self, capacity: count) { x in
                weights.withMemoryRebound(to: Float.self, capacity: count) { w in
                    vDSP_dotpr(x, 1, w, 1, &result, vDSP_Length(count))
                }
            }
            return Sample(result)
        }
        var result: Double = 0
        input.withMemoryRebound(to: Double.self, capacity: count) { x in
            weights.withMemoryRebound(to: Double.self, capacity: count) { w in
                vDSP_dotprD(x, 1, w, 1, &result, vDSP_Length(count))
            }
        }
        return Sample(result)
    }
    func interpolate(_ input: UnsafeBufferPointer<Sample>, outputIndex: Int) -> Sample {
        let (left, fraction) = position(outputIndex)
        if depth == 1 {
            // The reference's explicitly linear mode has zero-valued outside boundaries.
            guard left >= 0, left < input.count - 1 else { return 0 }
            return Sample(1 - fraction) * input[left] + Sample(fraction) * input[left + 1]
        }
        if left < 0 { return input[0] }
        if left >= input.count - 1 { return input[input.count - 1] }
        if fraction == 0 { return input[left] }
        let usable = min(depth, left + 1, input.count - left - 1)
        if usable == 1 {
            return Sample(1 - fraction) * input[left] + Sample(fraction) * input[left + 1]
        }
        if usable == 2 {
            // Cubic Hermite basis with centered finite-difference endpoint derivatives.
            let t = Sample(fraction)
            let t2 = t * t
            let t3 = t2 * t
            let d0 = (input[left + 1] - input[left - 1]) / 2
            let d1 = (input[left + 2] - input[left]) / 2
            return (2 * t3 - 3 * t2 + 1) * input[left]
                + (t3 - 2 * t2 + t) * d0
                + (-2 * t3 + 3 * t2) * input[left + 1] + (t3 - t2) * d1
        }
        let weights: UnsafePointer<Sample>
        if usable == depth, phaseCount > 0 {
            weights = UnsafePointer(
                coefficients.baseAddress!.advanced(by: (outputIndex % phaseCount) * 2 * depth))
        } else {
            writeWeights(fraction: fraction, depth: usable, into: scratch)
            weights = UnsafePointer(scratch.baseAddress!)
        }
        return dot(input.baseAddress!.advanced(by: left - usable + 1), weights, count: 2 * usable)
    }
}

private final class IntervalConditioningStorage<Sample: BinaryFloatingPoint & Sendable> {
    let layout: IntervalConditioningLayout
    let input: UnsafeMutableBufferPointer<Sample>
    let output: UnsafeMutableBufferPointer<Sample>
    let time: UnsafeMutableBufferPointer<Sample>
    let spectrum: UnsafeMutableBufferPointer<FourierBin<Sample>>
    let forward: PreparedFourierTransform<Sample>?
    let inverse: PreparedFourierTransform<Sample>?
    let interpolation: IntervalInterpolator<Sample>?
    var scalarWorkspaceBytes: Int {
        let own =
            (input.count + output.count + time.count + 2 * spectrum.count
                + (interpolation?.scalarCount ?? 0)) * MemoryLayout<Sample>.stride
        let plans =
            (forward?.scalarWorkspaceBytes ?? 0)
            + (inverse === forward ? 0 : (inverse?.scalarWorkspaceBytes ?? 0))
        return own + plans
    }
    init(_ layout: IntervalConditioningLayout, diagnostics: WorkerDiagnostics) throws {
        guard
            (Sample.self == Float.self && layout.configuration.precision == .float32)
                || (Sample.self == Double.self && layout.configuration.precision == .float64)
        else { throw ConditioningError.precisionMismatch }
        self.layout = layout
        if let n = layout.forwardTransformLength, let m = layout.inverseTransformLength {
            let plan = try PreparedFourierTransform<Sample>(
                FourierConfiguration(
                    length: n,
                    sampleRate: Double(layout.configuration.sourceSampleRate),
                    precision: layout.configuration.precision), diagnostics: diagnostics)
            forward = plan
            inverse =
                n == m
                ? plan
                : try PreparedFourierTransform<Sample>(
                    FourierConfiguration(
                        length: m,
                        sampleRate: Double(layout.configuration.targetSampleRate),
                        precision: layout.configuration.precision), diagnostics: diagnostics)
        } else {
            forward = nil
            inverse = nil
        }
        input = .allocate(capacity: layout.inputSampleCount)
        input.initialize(repeating: 0)
        output = .allocate(capacity: layout.outputSampleCount)
        output.initialize(repeating: 0)
        time = .allocate(capacity: layout.inverseTransformLength ?? 0)
        time.initialize(repeating: 0)
        spectrum = .allocate(capacity: layout.inverseTransformLength.map { $0 / 2 + 1 } ?? 0)
        spectrum.initialize(repeating: FourierBin(real: 0))
        if layout.configuration.targetSampleRate != layout.configuration.sourceSampleRate,
            layout.configuration.targetSampleRate != 2 * layout.configuration.sourceSampleRate,
            case .praat7WholeInterval(let depth) = layout.configuration.method
        {
            interpolation = IntervalInterpolator(layout, depth: depth)
        } else {
            interpolation = nil
        }
    }
    deinit {
        input.deinitialize()
        input.deallocate()
        output.deinitialize()
        output.deallocate()
        time.deinitialize()
        time.deallocate()
        spectrum.deinitialize()
        spectrum.deallocate()
    }
    func resample() throws {
        let configuration = layout.configuration
        if configuration.sourceSampleRate == configuration.targetSampleRate {
            output.baseAddress!.update(from: input.baseAddress!, count: input.count)
            return
        }
        var interpolationInput = UnsafeBufferPointer(input)
        if let n = layout.forwardTransformLength, let forward, let inverse {
            for i in 0..<time.count { time[i] = 0 }
            for i in 0..<spectrum.count { spectrum[i] = FourierBin(real: 0) }
            time.baseAddress!.advanced(by: 1000).update(
                from: input.baseAddress!, count: input.count)
            _ = try forward.forwardReal(
                UnsafeBufferPointer(rebasing: time[0..<n]),
                into: UnsafeMutableBufferPointer(rebasing: spectrum[0..<(n / 2 + 1)]))
            spectrum[n / 2] = FourierBin(real: 0)
            if configuration.targetSampleRate < configuration.sourceSampleRate {
                // Independent cosine/sine basis selection for the pinned reference cutoff.
                // Its packed ordinal rule can retain a final cosine while removing its sine.
                let stopOrdinal = Int(
                    floor(
                        Double(configuration.targetSampleRate)
                            * (1 / Double(configuration.sourceSampleRate)) * Double(n)))
                for k in 1..<(n / 2) {
                    if 2 * k + 1 >= stopOrdinal { spectrum[k].real = 0 }
                    if 2 * k + 2 >= stopOrdinal { spectrum[k].imaginary = 0 }
                }
                try inverse.inverseReal(UnsafeBufferPointer(spectrum), into: time)
                interpolationInput = UnsafeBufferPointer(
                    start: time.baseAddress!.advanced(by: 1000), count: input.count)
            } else {
                let firstTaperOrdinal = Int(Double(n) * 0.95)
                let width = Double(n - firstTaperOrdinal)
                for k in 1..<(n / 2) {
                    let cosineOrdinal = 2 * k + 1
                    let sineOrdinal = 2 * k + 2
                    if cosineOrdinal > firstTaperOrdinal {
                        spectrum[k].real *= Sample(Double(n - cosineOrdinal) / width)
                    }
                    if sineOrdinal > firstTaperOrdinal {
                        spectrum[k].imaginary *= Sample(Double(n - sineOrdinal) / width)
                    }
                }
                try inverse.inverseReal(UnsafeBufferPointer(spectrum), into: time)
                for j in 0..<output.count { output[j] = 2 * time[2000 + j] }
                return
            }
        }
        for j in 0..<output.count {
            output[j] = interpolation!.interpolate(interpolationInput, outputIndex: j)
        }
    }
    func preEmphasize() throws {
        if let coefficient = layout.configuration.preEmphasisCoefficient {
            let a = Sample(coefficient)
            var previous: Sample = 0
            for i in 0..<output.count {
                let current = output[i]
                if i > 0 { output[i] = current - a * previous }
                previous = current
                guard output[i].isFinite else { throw ConditioningError.nonfiniteResult }
            }
        } else {
            for value in output where !value.isFinite { throw ConditioningError.nonfiniteResult }
        }
    }
}

/// Single-owner whole-interval reference conditioner. Preparation fixes the input count.
/// Append arbitrary contiguous chunks, then finish once; no output is fabricated before completion.
/// Input is copied and never modified. The output is borrowed only during the finish callback.
/// Cancellation may be requested from that callback; other reentrant operations are rejected.
public final class PreparedIntervalConditioner<Sample: BinaryFloatingPoint & Sendable> {
    public let layout: IntervalConditioningLayout
    public let identity: ProfileIdentity
    public private(set) var source: SourceInterval
    public private(set) var receivedSampleCount = 0
    public var scalarWorkspaceBytes: Int { storage?.scalarWorkspaceBytes ?? 0 }
    public var isCancelled: Bool { state == .cancelled }
    private enum State { case prepared, finished, failed, cancelled }
    private var state = State.prepared
    private var storage: IntervalConditioningStorage<Sample>?
    private var record: ConditionedInterval
    private let diagnostics: WorkerDiagnostics
    private var busy = false

    public convenience init(configuration: ConditioningConfiguration, source: SourceInterval) throws
    {
        try self.init(
            configuration: configuration, source: source, diagnostics: WorkerDiagnostics())
    }
    package init(
        configuration: ConditioningConfiguration, source: SourceInterval,
        diagnostics: WorkerDiagnostics
    ) throws {
        guard let count = Int(exactly: source.sampleCount),
            source.sampleRate == Double(configuration.sourceSampleRate)
        else {
            throw ConditioningError.unexpectedInterval
        }
        let layout = try IntervalConditioningLayout(
            configuration: configuration, inputSampleCount: count)
        self.layout = layout
        self.identity = try configuration.identity()
        self.source = source
        self.record = try ConditionedInterval(layout: layout, source: source)
        self.diagnostics = diagnostics
        self.storage = try IntervalConditioningStorage(layout, diagnostics: diagnostics)
    }
    public func append(_ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval) throws {
        guard !busy else { throw ConditioningError.reentrantCall }
        guard state == .prepared, let storage else { throw ConditioningError.invalidState }
        guard interval.epoch == source.epoch, interval.sampleRate == source.sampleRate,
            interval.startSample == source.startSample + Int64(receivedSampleCount),
            interval.sampleCount == Int64(samples.count),
            samples.count <= layout.inputSampleCount - receivedSampleCount
        else { throw ConditioningError.unexpectedInterval }
        for value in samples where !value.isFinite { throw ConditioningError.nonfiniteInput }
        if !samples.isEmpty {
            storage.input.baseAddress!.advanced(by: receivedSampleCount).update(
                from: samples.baseAddress!, count: samples.count)
        }
        receivedSampleCount += samples.count
    }
    /// Repeated finish returns the same metadata without emitting twice. Incomplete input is an error.
    @discardableResult public func finish(
        emit: (UnsafeBufferPointer<Sample>, ConditionedInterval) -> Void
    ) throws -> ConditionedInterval {
        guard !busy else { throw ConditioningError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw ConditioningError.invalidState
        }
        if state == .finished { return record }
        guard receivedSampleCount == layout.inputSampleCount else {
            throw ConditioningError.insufficientData
        }
        busy = true
        defer { busy = false }
        do {
            try diagnostics.withInterval(.resample) { try storage.resample() }
            try diagnostics.withInterval(.preEmphasis) { try storage.preEmphasize() }
        } catch {
            state = .failed
            throw error
        }
        state = .finished
        withExtendedLifetime(storage) { emit(UnsafeBufferPointer(storage.output), record) }
        return record
    }
    /// Explicitly starts a separate interval with zero pre-emphasis history and the same prepared size.
    public func reset(source: SourceInterval) throws {
        guard !busy else { throw ConditioningError.reentrantCall }
        guard state != .cancelled, storage != nil else { throw ConditioningError.invalidState }
        let record = try ConditionedInterval(layout: layout, source: source)
        self.source = source
        self.record = record
        self.receivedSampleCount = 0
        state = .prepared
    }
    public func cancel() {
        state = .cancelled
        storage = nil
    }
}
