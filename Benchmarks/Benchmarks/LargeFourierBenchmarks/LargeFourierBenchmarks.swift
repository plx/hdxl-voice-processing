import Benchmark
import LargeFourierWorkload

private final class CapabilityBox { let value = 95 }
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
            .wallClock, .peakMemoryResident, .mallocCountTotal, .mallocBytesCount, .freeCountTotal,
            .objectAllocCount, .retainCount, .releaseCount,
        ]
    #else
        let metrics: [BenchmarkMetric] = [.wallClock, .cpuTotal, .peakMemoryResident]
    #endif
    let units = Dictionary(uniqueKeysWithValues: metrics.map { ($0, BenchmarkUnits.count) })
    let configuration = Benchmark.Configuration(
        metrics: metrics, timeUnits: .nanoseconds, units: units,
        warmupIterations: 3, scalingFactor: .one, maxDuration: .seconds(60), maxIterations: 30)
    for item in try! LargeFourierCase.matrix() {
        for operation in LargeFourierOperation.allCases {
            var state: (any LargeFourierBatch)?
            Benchmark(
                "LargeFourier.\(operation.rawValue).\(item.name)", configuration: configuration
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
                state = try item.makeWorkload(operation)
                try state!.verify()
            } teardown: {
                state = nil
            }
        }
    }
    #if AllocationDiagnostics
        Benchmark("Capability.LargeFourierAllocationARC", configuration: configuration) {
            benchmark in
            benchmark.startMeasurement()
            capabilityControl()
            benchmark.stopMeasurement()
        }
    #endif
}
