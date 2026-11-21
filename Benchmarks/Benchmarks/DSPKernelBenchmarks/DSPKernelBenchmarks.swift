import Benchmark
import Foundation

#if KernelBenchmarks
    import KernelWorkload
#endif

let benchmarks: @Sendable () -> Void = {
    #if KernelBenchmarks
        guard let path = ProcessInfo.processInfo.environment["HDXL_KERNEL_PLAN"] else {
            FileHandle.standardError.write(
                Data(
                    "Use python3 Tools/Kernels/benchmark.py to calibrate and run the DSP kernel matrix.\n"
                        .utf8))
            exit(2)
        }
        let records: [KernelRecord]
        do {
            records = try JSONDecoder().decode(
                [KernelRecord].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            FileHandle.standardError.write(
                Data("Could not load the calibrated DSP kernel plan: \(error)\n".utf8))
            exit(2)
        }
        #if AllocationDiagnostics
            let metrics: [BenchmarkMetric] = [
                .wallClock, .mallocCountTotal, .mallocBytesCount, .freeCountTotal,
                .objectAllocCount, .retainCount, .releaseCount,
            ]
        #else
            let metrics: [BenchmarkMetric] = [.wallClock, .cpuTotal]
        #endif
        let units = Dictionary(uniqueKeysWithValues: metrics.map { ($0, BenchmarkUnits.count) })
        let config = Benchmark.Configuration(
            metrics: metrics, timeUnits: .nanoseconds, units: units,
            warmupIterations: 3, scalingFactor: .one, maxDuration: .seconds(15), maxIterations: 100)
        for record in records {
            var state: KernelBatch?
            var measured = config
            measured.tags = ["batch": String(record.operationsPerBatch)]
            Benchmark("Kernel.\(record.name)", configuration: measured) { benchmark in
                let batch = state!
                batch.reset()
                benchmark.startMeasurement()
                let checksum = try! batch.run()
                blackHole(checksum)
                benchmark.stopMeasurement()
                try! batch.verify(checksum)
            } setup: {
                state = try KernelBatch(record)
            } teardown: {
                state = nil
            }
        }
        #if AllocationDiagnostics
            Benchmark("Capability.KernelAllocationARC", configuration: config) { benchmark in
                benchmark.startMeasurement()
                allocationControl()
                benchmark.stopMeasurement()
            }
        #endif
    #endif
}

#if AllocationDiagnostics && KernelBenchmarks
    private final class ControlObject {}
    @inline(never) private func allocationControl() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 1, count: 4096)
        blackHole(memory)
        memory.deallocate()
        let object = Unmanaged.passRetained(ControlObject())
        let second = object.retain()
        blackHole(second.takeUnretainedValue())
        second.release()
        object.release()
    }
#endif
