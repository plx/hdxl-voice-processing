import Dispatch
import Foundation
import HDXLVoiceProcessing
import Synchronization

@inline(never)
private func syntheticWork(_ seed: UInt64) -> UInt64 {
    var value = seed
    for _ in 0..<32 {
        value = (value &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
        value ^= value >> 23
    }
    return value
}

private struct Trial: Codable {
    let mode: String
    let trial: Int
    let iterations: Int
    let nanoseconds: UInt64
    let checksum: String
    let intervals: UInt64
    let events: UInt64
    let suppressed: UInt64
    let unavailable: UInt64
}

private enum ProbeError: Error { case simulated, invalidArguments, outputMismatch }

@main
struct InstrumentationProbe {
    static func main() throws {
        if CommandLine.arguments.dropFirst() == ["--trace"] {
            try trace()
            return
        }
        guard CommandLine.arguments.count == 1 else { throw ProbeError.invalidArguments }
        let iterations = 10_000
        let modes: [DiagnosticMode?] = [nil, .disabled, .sampled, .detailed]
        // Warm every path, then rotate order to reduce simple ordering bias.
        for mode in modes { _ = measure(mode, trial: -1, iterations: 1_000) }
        var trials: [Trial] = []
        for trial in 0..<8 {
            for offset in 0..<modes.count {
                trials.append(
                    measure(
                        modes[(trial + offset) % modes.count], trial: trial, iterations: iterations)
                )
            }
        }
        guard Set(trials.map(\.checksum)).count == 1 else { throw ProbeError.outputMismatch }
        let data = try JSONEncoder().encode(trials)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func measure(_ mode: DiagnosticMode?, trial: Int, iterations: Int) -> Trial {
        let diagnostics = mode.map { WorkerDiagnostics(mode: $0) }
        var checksum: UInt64 = 0
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 1
        metadata.sampleCount = 32
        metadata.validity = .available
        let start = DispatchTime.now().uptimeNanoseconds
        if let diagnostics {
            for index in 0..<iterations {
                metadata.frameSequence = UInt64(index)
                metadata.elapsedProcessingCount = UInt64(index)
                checksum &+= diagnostics.withFrame(metadata) {
                    diagnostics.event(.dequeue)
                    let value = diagnostics.withInterval(.fft) { syntheticWork(UInt64(index)) }
                    return diagnostics.withInterval(.resultPublication) { value }
                }
            }
        } else {
            for index in 0..<iterations { checksum &+= syntheticWork(UInt64(index)) }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let counts = diagnostics?.counts
        return Trial(
            mode: mode?.rawValue ?? "bare", trial: trial, iterations: iterations,
            nanoseconds: elapsed, checksum: String(checksum, radix: 16),
            intervals: counts?.intervals ?? 0, events: counts?.events ?? 0,
            suppressed: counts?.suppressed ?? 0, unavailable: counts?.unavailable ?? 0)
    }

    private static func trace() throws {
        let outputs = Mutex<[UInt64]>([])
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            let diagnostics = WorkerDiagnostics(mode: .detailed)
            var metadata = DiagnosticMetadata()
            metadata.profileToken = 1
            metadata.sampleCount = 32
            metadata.queueDepth = 1
            metadata.queueWaitNanoseconds = 123  // Synthetic metadata, not a latency measurement.
            var checksum: UInt64 = 0
            for frame in 0..<32 {
                metadata.frameSequence = UInt64(frame)
                do {
                    try diagnostics.withFrame(metadata) {
                        // Worker observation, not a callback span.
                        diagnostics.event(.captureHandoff)
                        do {
                            try diagnostics.withInterval(.fft) {
                                // Trace-only overlap, never a capture path.
                                Thread.sleep(forTimeInterval: 0.001)
                                if frame == 5 { throw ProbeError.simulated }
                                if frame == 7 { throw CancellationError() }
                                if frame == 8 { diagnostics.reset() }
                                if frame == 9 {
                                    diagnostics.event(.overrun, validity: .discontinuity)
                                }
                                if frame == 10 { diagnostics.event(.routeChange) }
                                if frame == 11 { diagnostics.event(.configurationChange) }
                                checksum &+= syntheticWork(UInt64(frame))
                            }
                        } catch is CancellationError {
                            diagnostics.event(.cancelled, validity: .cancelled)
                            throw CancellationError()
                        } catch {
                            diagnostics.event(.error, validity: .failed)
                            throw error
                        }
                    }
                } catch {
                    // Synthetic failures are intentional; both scopes must end.
                }
            }
            outputs.withLock { $0.append(checksum) }
        }
        let values = outputs.withLock { $0 }
        guard values.count == 2, Set(values).count == 1 else { throw ProbeError.outputMismatch }
        print("{\"traceCompleted\":true,\"sessions\":2,\"framesPerSession\":32}")
    }
}
