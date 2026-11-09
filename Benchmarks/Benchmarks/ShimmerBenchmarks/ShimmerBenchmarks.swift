import Benchmark
import ShimmerWorkload

private final class CapabilityBox { let value = 51 }
@inline(never) private func capabilityControl() {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    bytes.initializeMemory(as: UInt8.self, repeating: 51, count: 4096)
    blackHole(bytes)
    bytes.deallocate()
    let retained = Unmanaged.passRetained(CapabilityBox())
    let extra = retained.retain()
    blackHole(extra.takeUnretainedValue())
    extra.release()
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
    let configuration = Benchmark.Configuration(
        metrics: metrics, timeUnits: .nanoseconds, units: units,
        warmupIterations: 3, scalingFactor: .one, maxDuration: .seconds(600), maxIterations: 30)
    for item in ShimmerCase.matrix() {
        for operation in item.operations {
            var state: (any ShimmerBatch)?
            Benchmark("Shimmer.\(operation.rawValue).\(item.name)", configuration: configuration) {
                benchmark in
                let workload = state!
                try! workload.prepareRun(operation)
                benchmark.startMeasurement()
                if operation == .prepare {
                    blackHole(try! workload.prepare())
                } else {
                    blackHole(try! workload.run(operation))
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
        Benchmark("Capability.ShimmerAllocationARC", configuration: configuration) { benchmark in
            benchmark.startMeasurement()
            capabilityControl()
            benchmark.stopMeasurement()
        }
    #endif
}
