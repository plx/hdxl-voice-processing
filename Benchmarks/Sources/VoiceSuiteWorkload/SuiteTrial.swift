import Dispatch
import Foundation
import HDXLVoiceProcessing
import Synchronization

public struct SuiteTrial: Sendable {
    public let item: SuiteFixture
    public let input: any SuiteInput
    public let simultaneous: Bool
    public let name: String

    public init(
        item: SuiteFixture, composition: SuiteComposition, directory: URL,
        simultaneous: Bool = false
    ) throws {
        self.item = item
        self.simultaneous = simultaneous
        input = try item.loadInput(in: directory, composition: composition)
        name = (simultaneous ? "pair" : "single") + "." + composition.rawValue + "." + item.name
    }

    /// Independent mutable workers read the same governed PCM at a shared start. Pair latency
    /// includes dispatch and the join, and represents completion of both analyses.
    @inline(never) public func run(chunk: Int = 173, diagnostics: RuntimeDiagnosticMode = .disabled)
        throws -> [SuiteResult]
    {
        if !simultaneous { return [try input.run(chunk: chunk, diagnostics: diagnostics)] }
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let other = Mutex<TimedResult?>(nil)
        @Sendable func measureWorker() -> TimedResult {
            let begin = DispatchTime.now().uptimeNanoseconds
            let result = Result { try input.run(chunk: chunk, diagnostics: diagnostics) }
            return TimedResult(
                begin: begin, end: DispatchTime.now().uptimeNanoseconds, result: result)
        }
        DispatchQueue.global(qos: .userInitiated).async(group: finished) {
            ready.signal()
            start.wait()
            let measured = measureWorker()
            other.withLock { $0 = measured }
        }
        ready.wait()
        start.signal()
        let first = measureWorker()
        finished.wait()
        let second = other.withLock { $0! }
        guard max(first.begin, second.begin) < min(first.end, second.end) else {
            throw SuiteError.mismatch("Independent workers did not overlap in " + name)
        }
        return try [first.result.get(), second.result.get()]
    }

    private struct TimedResult: Sendable {
        let begin, end: UInt64
        let result: Result<SuiteResult, any Error>
    }

    public func verify() throws -> [SuiteResult] {
        let whole = try input.run(chunk: item.sampleCount, diagnostics: .disabled)
        let split = try run()
        guard split.allSatisfy({ $0 == whole }), whole.epochs == item.repeats * item.regions.count,
            whole.analyzedSamples == item.repeats * item.regions.reduce(0, { $0 + $1.count }),
            let cpps = whole.lanes["cpps"], cpps.available + cpps.unavailable > 0
        else { throw SuiteError.mismatch(name) }
        return split
    }
}
