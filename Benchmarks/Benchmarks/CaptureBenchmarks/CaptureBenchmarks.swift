import Benchmark
import CaptureWorkload

private final class CapabilityBox { let value = 28 }
@inline(never) private func capabilityControl() {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    bytes.initializeMemory(as: UInt8.self, repeating: 28, count: 4096)
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
    for item in CaptureCase.matrix {
        var state: CaptureBatch?
        Benchmark(
            item.name,
            configuration: .init(
                metrics: metrics, timeUnits: .nanoseconds,
                units: units, warmupIterations: 2, scalingFactor: .one, maxDuration: .seconds(10),
                maxIterations: 20)
        ) { benchmark in
            let batch = state!
            try! batch.prepareIteration()
            benchmark.startMeasurement()
            batch.run()
            benchmark.stopMeasurement()
            precondition(batch.verify())
        } setup: {
            state = try CaptureBatch(item: item)
        } teardown: {
            state = nil
        }
    }
    #if AllocationDiagnostics
        Benchmark(
            "Capability.CaptureAllocationARC",
            configuration: .init(
                metrics: metrics,
                timeUnits: .nanoseconds, units: units, warmupIterations: 2, scalingFactor: .one,
                maxDuration: .seconds(10), maxIterations: 20)
        ) { benchmark in
            benchmark.startMeasurement()
            capabilityControl()
            benchmark.stopMeasurement()
        }
    #endif
}
