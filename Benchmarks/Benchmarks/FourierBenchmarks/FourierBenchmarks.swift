import Benchmark
import FourierWorkload

private final class CapabilityBox { let value = 30 }
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
            .wallClock, .mallocCountTotal, .mallocBytesCount, .freeCountTotal, .objectAllocCount,
            .retainCount, .releaseCount,
        ]
    #else
        let metrics: [BenchmarkMetric] = [.wallClock, .cpuTotal]
    #endif
    let units = Dictionary(uniqueKeysWithValues: metrics.map { ($0, BenchmarkUnits.count) })
    let configuration = Benchmark.Configuration(
        metrics: metrics, timeUnits: .nanoseconds, units: units,
        warmupIterations: 3, scalingFactor: .one, maxDuration: .seconds(10), maxIterations: 30)
    for item in try! FourierCase.matrix() {
        for operation in item.operations {
            var state: (any FourierBatch)?
            Benchmark("Fourier.\(operation.rawValue).\(item.name)", configuration: configuration) {
                benchmark in
                let workload = state!
                benchmark.startMeasurement()
                if operation == .prepareFFT || operation == .prepareSpectrum {
                    blackHole(try! workload.prepare(operation))
                } else {
                    blackHole(try! workload.run(operation, iterations: item.operationsPerIteration))
                }
                benchmark.stopMeasurement()
            } setup: {
                state = try item.makeWorkload()
                try state!.verify()
            } teardown: {
                state = nil
            }
        }
        #if !AllocationDiagnostics
            for operation in [FourierOperation.spectrum, .cepstrum] {
                for concurrent in [false, true] {
                    var workers: [FourierWorker] = []
                    let name =
                        "Fourier.\(concurrent ? "Concurrent4" : "Sequential4")\(operation.rawValue).\(item.name)"
                    Benchmark(name, configuration: configuration) { benchmark in
                        benchmark.startMeasurement()
                        let checksum: Double
                        if concurrent {
                            checksum = await withTaskGroup(of: Double.self) { group in
                                for worker in workers {
                                    group.addTask {
                                        try! await worker.run(
                                            operation, iterations: item.operationsPerIteration)
                                    }
                                }
                                var total = 0.0
                                for await value in group { total += value }
                                return total
                            }
                        } else {
                            var total = 0.0
                            for worker in workers {
                                total += try! await worker.run(
                                    operation, iterations: item.operationsPerIteration)
                            }
                            checksum = total
                        }
                        blackHole(checksum)
                        benchmark.stopMeasurement()
                        precondition(checksum.isFinite)
                    } setup: {
                        workers = try (0..<item.comparisonWorkerCount).map { _ in
                            try FourierWorker(item)
                        }
                        for worker in workers { _ = try await worker.run(operation, iterations: 1) }
                    } teardown: {
                        workers = []
                    }
                }
            }
        #endif
    }
    #if AllocationDiagnostics
        Benchmark("Capability.FourierAllocationARC", configuration: configuration) { benchmark in
            benchmark.startMeasurement()
            capabilityControl()
            benchmark.stopMeasurement()
        }
    #endif
}
