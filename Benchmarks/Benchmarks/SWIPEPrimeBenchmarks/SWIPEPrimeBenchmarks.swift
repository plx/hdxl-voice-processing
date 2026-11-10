import Benchmark
import SWIPEPrimeWorkload

private final class CapabilityBox { let value = 44 }
@inline(never) private func capabilityControl() {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    bytes.initializeMemory(as: UInt8.self, repeating: 44, count: 4096)
    blackHole(bytes)
    bytes.deallocate()
    let retained = Unmanaged.passRetained(CapabilityBox())
    let additional = retained.retain()
    blackHole(additional.takeUnretainedValue())
    additional.release()
    retained.release()
}

let benchmarks: @Sendable () -> Void = {
    #if AllocationDiagnostics
        let metrics: [BenchmarkMetric] = [
            .wallClock, .mallocCountTotal, .mallocBytesCount,
            .freeCountTotal, .objectAllocCount, .retainCount, .releaseCount,
        ]
    #else
        let metrics: [BenchmarkMetric] = [.wallClock, .cpuTotal]
    #endif
    let units = Dictionary(uniqueKeysWithValues: metrics.map { ($0, BenchmarkUnits.count) })
    let preparation = Benchmark.Configuration(
        metrics: metrics, timeUnits: .nanoseconds, units: units,
        warmupIterations: 3, scalingFactor: .one, maxDuration: .seconds(60), maxIterations: 30)
    let execution = Benchmark.Configuration(
        metrics: metrics, timeUnits: .nanoseconds, units: units,
        warmupIterations: 1, scalingFactor: .one, maxDuration: .seconds(3600), maxIterations: 10)
    for item in try! SWIPEPrimeCase.matrix() {
        for algorithm in SWIPEPrimeBenchmarkAlgorithm.allCases {
            for operation in SWIPEPrimeBenchmarkOperation.allCases {
                var state: (any SWIPEPrimeBatch)?
                Benchmark(
                    "SWIPEComparison.\(algorithm.rawValue).\(operation.rawValue).\(item.name)",
                    configuration: operation == .prepare ? preparation : execution
                ) { benchmark in
                    let workload = state!
                    benchmark.startMeasurement()
                    if operation == .prepare {
                        let prepared = try! workload.prepare()
                        blackHole(prepared)
                        benchmark.stopMeasurement()
                        // Construction is timed separately from destruction and PCM generation.
                        withExtendedLifetime(prepared) {}
                    } else {
                        blackHole(try! workload.run())
                        benchmark.stopMeasurement()
                    }
                } setup: {
                    state = try item.makeWorkload(algorithm: algorithm)
                } teardown: {
                    state = nil
                }
            }
        }
    }
    #if AllocationDiagnostics
        Benchmark("Capability.SWIPEPrimeAllocationARC", configuration: preparation) { benchmark in
            benchmark.startMeasurement()
            capabilityControl()
            benchmark.stopMeasurement()
        }
    #endif
}
