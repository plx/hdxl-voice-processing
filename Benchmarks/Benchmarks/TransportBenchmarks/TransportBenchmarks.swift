import Benchmark
import TransportWorkload

private final class CapabilityBox { let value = 23 }

@inline(never)
private func capabilityControl() {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    bytes.initializeMemory(as: UInt8.self, repeating: 23, count: 4096)
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
            .wallClock, .mallocCountTotal, .mallocBytesCount, .freeCountTotal,
            .objectAllocCount, .retainCount, .releaseCount,
        ]
    #else
        let metrics: [BenchmarkMetric] = [.wallClock, .cpuTotal]
    #endif
    let units = Dictionary(uniqueKeysWithValues: metrics.map { ($0, BenchmarkUnits.count) })
    for item in TransportCase.matrix {
        for operation in TransportOperation.allCases {
            var state: TransportBatch?
            Benchmark(
                "Transport.\(operation.rawValue).\(item.name)",
                configuration: .init(
                    metrics: metrics, timeUnits: .nanoseconds, units: units,
                    warmupIterations: 2, scalingFactor: .one,
                    maxDuration: .seconds(10), maxIterations: 20)
            ) { benchmark in
                let batch = state!
                batch.prepareIteration()
                benchmark.startMeasurement()
                let checksum = batch.run()
                blackHole(checksum)
                benchmark.stopMeasurement()
                blackHole(batch.verify(checksum: checksum))
            } setup: {
                state = try TransportBatch(item: item, operation: operation)
            } teardown: {
                state = nil
            }
        }
    }
    #if AllocationDiagnostics
        Benchmark(
            "Capability.TransportAllocationARC",
            configuration: .init(
                metrics: metrics, timeUnits: .nanoseconds, units: units,
                warmupIterations: 2, scalingFactor: .one,
                maxDuration: .seconds(10), maxIterations: 20)
        ) { benchmark in
            benchmark.startMeasurement()
            capabilityControl()
            benchmark.stopMeasurement()
        }
    #endif
}
