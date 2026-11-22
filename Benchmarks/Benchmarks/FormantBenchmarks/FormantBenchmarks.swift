import Benchmark
import FormantWorkload

#if KernelBenchmarks

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
        for item in try! FormantCase.matrix() {
            for operation in FormantOperation.allCases {
                var trial: FormantTrial?
                Benchmark(
                    "BurgFormants.\(operation.rawValue).\(item.name)",
                    configuration: .init(
                        metrics: metrics, timeUnits: .nanoseconds, units: units,
                        warmupIterations: 2, scalingFactor: .one, maxDuration: .seconds(60),
                        maxIterations: 101)
                ) { benchmark in
                    let trial = trial!
                    trial.prepare(operation)
                    benchmark.startMeasurement()
                    try! trial.run(operation)
                    benchmark.stopMeasurement()
                    trial.verify()
                } setup: {
                    trial = try! FormantTrial(item)
                } teardown: {
                    trial = nil
                }
            }
        }
        #if AllocationDiagnostics
            Benchmark(
                "Capability.BurgFormantsAllocationARC",
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

#else
    let benchmarks: @Sendable () -> Void = {}
#endif
