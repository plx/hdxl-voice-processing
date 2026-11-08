import Benchmark
import HNRWorkload

private final class CapabilityBox { let value = 39 }
@inline(never) private func capabilityControl() {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    bytes.initializeMemory(as: UInt8.self, repeating: 42, count: 4096)
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
    for item in try! HNRCase.matrix() {
        for operation in HNROperation.allCases {
            var state: (any HNRBatch)?
            Benchmark(
                "HNR.\(operation.rawValue).\(item.name)",
                configuration: operation == .prepare ? preparation : execution
            ) { benchmark in
                let workload = state!
                benchmark.startMeasurement()
                if operation == .prepare {
                    blackHole(try! workload.prepare())
                } else {
                    blackHole(try! workload.run())
                }
                benchmark.stopMeasurement()
            } setup: {
                state = try item.makeWorkload()
            } teardown: {
                state = nil
            }
        }
    }
    #if AllocationDiagnostics
        Benchmark("Capability.HNRAllocationARC", configuration: preparation) { benchmark in
            benchmark.startMeasurement()
            capabilityControl()
            benchmark.stopMeasurement()
        }
    #endif
}
