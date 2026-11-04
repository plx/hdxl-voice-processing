import Accelerate
import Foundation

private final class PreviewConditioningStorage<Sample: BinaryFloatingPoint & Sendable> {
    let layout: PreviewConditioningLayout
    let coefficients: UnsafeMutableBufferPointer<Sample>
    /// Mirrored finite history gives each convolution a contiguous span, including zero extension.
    let history: UnsafeMutableBufferPointer<Sample>
    let output: UnsafeMutableBufferPointer<Sample>
    let width: Int
    var written: Int64 = 0
    var previousResampled: Sample = 0
    var hasPrevious = false
    var pending = 0
    var scalarWorkspaceBytes: Int {
        (coefficients.count + history.count + output.count) * MemoryLayout<Sample>.stride
    }
    init(_ layout: PreviewConditioningLayout) throws {
        guard
            (Sample.self == Float.self && layout.configuration.precision == .float32)
                || (Sample.self == Double.self && layout.configuration.precision == .float64)
        else {
            throw ConditioningError.precisionMismatch
        }
        self.layout = layout
        width = 2 * layout.filterRadius + 1
        coefficients = .allocate(capacity: layout.coefficientCount)
        history = .allocate(capacity: 2 * width)
        output = .allocate(capacity: layout.outputBlockCapacity)
        coefficients.initialize(repeating: 0)
        history.initialize(repeating: 0)
        output.initialize(repeating: 0)
        guard case .streamingPreview(_, let fraction) = layout.configuration.method else {
            throw ConditioningError.invalidQuality
        }
        let cutoff =
            0.5 * fraction
            * min(
                1,
                Double(layout.configuration.targetSampleRate)
                    / Double(layout.configuration.sourceSampleRate))
        // Prepare in binary64, then round coefficients once to the declared working precision.
        var phaseWeights = [Double](repeating: 0, count: width)
        for phase in 0..<layout.configuration.ratio.numerator {
            let position = layout.position(Int64(phase))
            let phaseFraction =
                Double(position.remainder) / Double(2 * layout.configuration.ratio.numerator)
            var sum = 0.0
            for offset in 0..<width {
                let distance = phaseFraction - Double(offset - layout.filterRadius)
                let angle = .pi * distance / Double(layout.filterRadius)
                let window =
                    abs(distance) >= Double(layout.filterRadius)
                    ? 0
                    : 0.42 + 0.5 * cos(angle) + 0.08 * cos(2 * angle)
                let sinc =
                    distance == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * distance) / (.pi * distance)
                phaseWeights[offset] = window * sinc
                sum += phaseWeights[offset]
            }
            for offset in 0..<width {
                coefficients[phase * width + offset] = Sample(phaseWeights[offset] / sum)
            }
        }
    }
    deinit {
        coefficients.deinitialize()
        coefficients.deallocate()
        history.deinitialize()
        history.deallocate()
        output.deinitialize()
        output.deallocate()
    }
    func reset() {
        history.update(repeating: 0)
        written = 0
        previousResampled = 0
        hasPrevious = false
        pending = 0
    }
    func append(_ value: Sample) {
        let slot = Int(written % Int64(width))
        history[slot] = value
        history[slot + width] = value
        written += 1
    }
    func resample(index: Int64, left: Int64) -> Sample {
        let start = left - Int64(layout.filterRadius)
        let slot = Int(((start % Int64(width)) + Int64(width)) % Int64(width))
        let phase = Int(index % Int64(layout.configuration.ratio.numerator))
        let x = history.baseAddress!.advanced(by: slot)
        let w = coefficients.baseAddress!.advanced(by: phase * width)
        if Sample.self == Float.self {
            var result: Float = 0
            x.withMemoryRebound(to: Float.self, capacity: width) { input in
                w.withMemoryRebound(to: Float.self, capacity: width) { weights in
                    vDSP_dotpr(input, 1, weights, 1, &result, vDSP_Length(width))
                }
            }
            return Sample(result)
        }
        var result: Double = 0
        x.withMemoryRebound(to: Double.self, capacity: width) { input in
            w.withMemoryRebound(to: Double.self, capacity: width) { weights in
                vDSP_dotprD(input, 1, weights, 1, &result, vDSP_Length(width))
            }
        }
        return Sample(result)
    }
    func preEmphasize() throws {
        let coefficient = layout.configuration.preEmphasisCoefficient.map { Sample($0) }
        for j in 0..<pending {
            let raw = output[j]
            if let coefficient, hasPrevious { output[j] = raw - coefficient * previousResampled }
            previousResampled = raw
            hasPrevious = true
            guard output[j].isFinite else { throw ConditioningError.nonfiniteResult }
        }
    }
}

/// Single-owner, synchronous worker primitive. Never call from a capture callback.
/// Preparation owns all filter/history/output buffers; process and finish reuse them.
/// The emitter borrows PCM only until it returns. Output samples are invariant to input chunks;
/// delivery blocks and their measured input-clock delay may differ. Original input is never edited.
public final class PreparedPreviewConditioner<Sample: BinaryFloatingPoint & Sendable> {
    public let layout: PreviewConditioningLayout
    public let identity: ProfileIdentity
    public private(set) var origin: SourceInterval
    public private(set) var receivedSampleCount: Int64 = 0
    public private(set) var emittedSampleCount: Int64 = 0
    public var scalarWorkspaceBytes: Int { storage?.scalarWorkspaceBytes ?? 0 }
    public var isCancelled: Bool { state == .cancelled }
    private enum State { case prepared, finished, failed, cancelled }
    private var state = State.prepared
    private var storage: PreviewConditioningStorage<Sample>?
    private let diagnostics: WorkerDiagnostics
    private var nextOutput: Int64 = 0
    private var busy = false
    private var completion: PreviewConditioningCompletion?

    public convenience init(
        layout: PreviewConditioningLayout, epoch: StreamEpoch, startSample: Int64 = 0
    ) throws {
        try self.init(
            layout: layout, epoch: epoch, startSample: startSample, diagnostics: WorkerDiagnostics()
        )
    }
    package init(
        layout: PreviewConditioningLayout, epoch: StreamEpoch, startSample: Int64 = 0,
        diagnostics: WorkerDiagnostics
    ) throws {
        self.layout = layout
        self.origin = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: Double(layout.configuration.sourceSampleRate))
        self.identity = try layout.configuration.identity()
        self.diagnostics = diagnostics
        self.storage = try PreviewConditioningStorage(layout)
    }
    /// Invalid PCM/continuity rejects the whole chunk before mutation. A callback can cancel;
    /// the report then identifies the consumed prefix. Recursive process/reset/finish throws.
    @discardableResult public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (UnsafeBufferPointer<Sample>, PreviewConditionedBlock) -> Void
    ) throws -> PreviewConditioningProcessReport {
        guard !busy else { throw ConditioningError.reentrantCall }
        guard state == .prepared, let storage else { throw ConditioningError.invalidState }
        guard interval.epoch == origin.epoch, interval.sampleRate == origin.sampleRate,
            interval.startSample == origin.startSample + receivedSampleCount,
            interval.sampleCount == Int64(samples.count)
        else { throw ConditioningError.unexpectedInterval }
        guard
            Int64(samples.count) <= PreviewConditioningLayout.maximumInputSampleCount
                - receivedSampleCount
        else {
            throw ConditioningError.capacityExceeded
        }
        for value in samples where !value.isFinite { throw ConditioningError.nonfiniteInput }
        busy = true
        defer { busy = false }
        var consumed = 0
        let previousEmitted = emittedSampleCount
        do {
            while state == .prepared {
                try diagnostics.withInterval(.resample) {
                    // Drain lookahead already present before consuming more source. This matters
                    // when one input sample unlocks more than one borrowed output block.
                    try fillAvailable(storage)
                    while storage.pending < layout.outputBlockCapacity && consumed < samples.count {
                        storage.append(samples[consumed])
                        consumed += 1
                        receivedSampleCount += 1
                        try fillAvailable(storage)
                    }
                }
                let wasFull = storage.pending == layout.outputBlockCapacity
                try flush(storage, finalizing: false, emit: emit)
                if consumed == samples.count && !wasFull { break }
            }
        } catch {
            state = .failed
            throw error
        }
        return PreviewConditioningProcessReport(
            consumedSampleCount: consumed,
            emittedSampleCount: emittedSampleCount - previousEmitted,
            isCancelled: state == .cancelled)
    }
    /// Declares the interval complete, enabling explicitly labelled trailing zero extension.
    /// No synthetic samples are counted as observed source. Repeated finish does not emit again.
    @discardableResult public func finish(
        emit: (UnsafeBufferPointer<Sample>, PreviewConditionedBlock) -> Void
    ) throws -> PreviewConditioningCompletion {
        guard !busy else { throw ConditioningError.reentrantCall }
        guard state != .cancelled, state != .failed, let storage else {
            throw ConditioningError.invalidState
        }
        if let completion { return completion }
        busy = true
        defer { busy = false }
        let total = try layout.outputSampleCount(inputSampleCount: receivedSampleCount)
        do {
            while nextOutput < total && state == .prepared {
                try diagnostics.withInterval(.resample) {
                    while nextOutput < total && storage.pending < layout.outputBlockCapacity {
                        let needed =
                            layout.position(nextOutput).left + Int64(layout.filterRadius) + 1
                        while storage.written < needed { storage.append(0) }
                        try fillAvailable(storage)
                    }
                }
                try flush(storage, finalizing: true, emit: emit)
            }
        } catch {
            state = .failed
            throw error
        }
        let source = try SourceInterval(
            epoch: origin.epoch, startSample: origin.startSample,
            sampleCount: receivedSampleCount, sampleRate: origin.sampleRate)
        let result = PreviewConditioningCompletion(
            source: source, outputSampleCount: emittedSampleCount,
            isCancelled: state == .cancelled)
        if state != .cancelled {
            state = .finished
            completion = result
        }
        return result
    }
    /// Starts a separately conditioned interval. All FIR and raw pre-emphasis history is discarded.
    /// Explicit origin/epoch selection acknowledges the boundary; gaps are never silently bridged.
    public func reset(epoch: StreamEpoch, startSample: Int64 = 0) throws {
        guard !busy else { throw ConditioningError.reentrantCall }
        guard state != .cancelled, let storage else { throw ConditioningError.invalidState }
        let origin = try SourceInterval(
            epoch: epoch, startSample: startSample, sampleCount: 0,
            sampleRate: Double(layout.configuration.sourceSampleRate))
        self.origin = origin
        storage.reset()
        receivedSampleCount = 0
        emittedSampleCount = 0
        nextOutput = 0
        completion = nil
        state = .prepared
        diagnostics.reset()
    }
    public func cancel() {
        state = .cancelled
        storage = nil
        completion = nil
    }

    private func fillAvailable(_ storage: PreviewConditioningStorage<Sample>) throws {
        let total = try layout.outputSampleCount(inputSampleCount: receivedSampleCount)
        while nextOutput < total && storage.pending < layout.outputBlockCapacity {
            let left = layout.position(nextOutput).left
            guard left + Int64(layout.filterRadius) < storage.written else { break }
            let value = storage.resample(index: nextOutput, left: left)
            guard value.isFinite else { throw ConditioningError.nonfiniteResult }
            storage.output[storage.pending] = value
            storage.pending += 1
            nextOutput += 1
        }
    }
    private func flush(
        _ storage: PreviewConditioningStorage<Sample>, finalizing: Bool,
        emit: (UnsafeBufferPointer<Sample>, PreviewConditionedBlock) -> Void
    ) throws {
        guard storage.pending > 0 else { return }
        let record = try PreviewConditionedBlock(
            layout: layout, origin: origin,
            outputStartIndex: emittedSampleCount, outputSampleCount: storage.pending,
            deliveryInputSampleCount: receivedSampleCount, isFinalizing: finalizing)
        try diagnostics.withInterval(.preEmphasis) { try storage.preEmphasize() }
        let buffer = UnsafeBufferPointer(start: storage.output.baseAddress, count: storage.pending)
        emittedSampleCount += Int64(storage.pending)
        storage.pending = 0
        withExtendedLifetime(storage) { emit(buffer, record) }
    }
}
