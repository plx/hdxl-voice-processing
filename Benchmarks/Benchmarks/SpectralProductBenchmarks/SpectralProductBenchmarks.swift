import Benchmark
import SpectralProductWorkload

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
    for item in try! ProductCase.matrix() {
        for operation in ProductOperation.allCases {
            var trial: ProductTrial?
            Benchmark(
                "SpectralProducts.\(operation.rawValue).\(item.name)",
                configuration: .init(
                    metrics: metrics, timeUnits: .nanoseconds, units: units,
                    warmupIterations: 2, scalingFactor: .one, maxDuration: .seconds(60),
                    maxIterations: 15)
            ) { benchmark in
                let trial = trial!
                try! trial.prepare(operation)
                benchmark.startMeasurement()
                try! trial.run(operation)
                benchmark.stopMeasurement()
                try! trial.verify(operation)
            } setup: {
                trial = try! ProductTrial(item)
            } teardown: {
                trial = nil
            }
        }
        for operation in CepstralProductOperation.allCases {
            var trial: CepstralProductTrial?
            Benchmark(
                "SpectralProducts.\(operation.rawValue).\(item.name)",
                configuration: .init(
                    metrics: metrics, timeUnits: .nanoseconds, units: units,
                    warmupIterations: 2, scalingFactor: .one, maxDuration: .seconds(60),
                    maxIterations: 15)
            ) { benchmark in
                let trial = trial!
                try! trial.prepare(operation)
                benchmark.startMeasurement()
                try! trial.run(operation)
                benchmark.stopMeasurement()
                trial.verify(operation)
            } setup: {
                trial = try! CepstralProductTrial(item)
            } teardown: {
                trial = nil
            }
        }
    }
    #if AllocationDiagnostics
        Benchmark(
            "Capability.SpectralProductAllocationARC",
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
