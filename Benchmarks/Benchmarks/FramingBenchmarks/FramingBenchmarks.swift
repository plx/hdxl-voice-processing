import Benchmark
import FramingWorkload

private final class CapabilityBox { let value = 24 }

@inline(never)
private func capabilityControl() {
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
    for item in try! FramingCase.matrix() {
        for operation in ["Prepare", "WindowReuse", "Reset", "LargeChunks", "SmallChunks"] {
            var state: (any FramingBatch)?
            Benchmark(
                "Framing.\(operation).\(item.name)",
                configuration: .init(
                    metrics: metrics, timeUnits: .nanoseconds, units: units,
                    warmupIterations: 3, scalingFactor: .one,
                    maxDuration: .seconds(10), maxIterations: 30)
            ) { benchmark in
                let workload = state!
                try! workload.restart()
                benchmark.startMeasurement()
                switch operation {
                case "Prepare": blackHole(try! workload.prepare())
                case "WindowReuse":
                    for _ in 0..<item.primitiveOperationsPerIteration {
                        blackHole(try! workload.reuseWindow())
                    }
                case "Reset":
                    for _ in 0..<item.primitiveOperationsPerIteration { try! workload.restart() }
                default:
                    try! workload.run(
                        chunkSize: operation == "LargeChunks"
                            ? item.inputSampleCount : item.smallChunkSamples)
                    blackHole(workload.checksum)
                }
                benchmark.stopMeasurement()
                if operation == "LargeChunks" || operation == "SmallChunks" {
                    precondition(workload.checksum == workload.expectedChecksum)
                    precondition(workload.frameCount == item.expectedFrameCount)
                }
            } setup: {
                state = try item.makeWorkload()
            } teardown: {
                state = nil
            }
        }
    }
    #if AllocationDiagnostics
        Benchmark(
            "Capability.FramingAllocationARC",
            configuration: .init(
                metrics: metrics, timeUnits: .nanoseconds, units: units,
                warmupIterations: 3, scalingFactor: .one,
                maxDuration: .seconds(10), maxIterations: 30)
        ) { benchmark in
            benchmark.startMeasurement()
            capabilityControl()
            benchmark.stopMeasurement()
        }
    #endif
}
