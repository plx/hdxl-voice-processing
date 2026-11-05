/// Prepared exact widening of Float PCM. Double input is borrowed without a copy.
/// Numerical analysis always receives Double; no frame-sized allocations occur here.
package final class CepstralInputConversion {
    let scratch: UnsafeMutableBufferPointer<Double>
    var scalarWorkspaceBytes: Int { scratch.count * MemoryLayout<Double>.stride }
    init(precision: AnalysisPrecision) {
        scratch = .allocate(capacity: precision == .float32 ? 4096 : 0)
        scratch.initialize(repeating: 0)
    }
    deinit {
        scratch.deinitialize()
        scratch.deallocate()
    }
    func consume<S: BinaryFloatingPoint & Sendable>(
        _ samples: UnsafeBufferPointer<S>, interval: SourceInterval,
        shouldContinue: () -> Bool = { true },
        body: (UnsafeBufferPointer<Double>, SourceInterval) throws -> Int
    ) throws -> Int {
        if S.self == Double.self {
            return try samples.withMemoryRebound(to: Double.self) { try body($0, interval) }
        }
        var consumed = 0
        while consumed < samples.count && shouldContinue() {
            let count = min(scratch.count, samples.count - consumed)
            for i in 0..<count { scratch[i] = Double(samples[consumed + i]) }
            let chunk = try SourceInterval(
                epoch: interval.epoch,
                startSample: interval.startSample + Int64(consumed), sampleCount: Int64(count),
                sampleRate: interval.sampleRate)
            let accepted = try body(UnsafeBufferPointer(rebasing: scratch[0..<count]), chunk)
            consumed += accepted
            if accepted < count { break }
        }
        return consumed
    }
}
