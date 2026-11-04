import Benchmark
import SmokeWorkload

private final class AllocationBox {
    let value = 42
}

/// Exercise observable malloc and Swift runtime ARC hooks; no claimed DSP workload.
@inline(never)
private func exerciseAllocationAndARC() {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    bytes.initializeMemory(as: UInt8.self, repeating: 0x5A, count: 4096)
    blackHole(bytes)
    bytes.deallocate()
    let reference = Unmanaged.passRetained(AllocationBox())
    let additionalReference = reference.retain()
    blackHole(additionalReference.takeUnretainedValue())
    additionalReference.release()
    reference.release()
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

    var workload: GainEnergyWorkload?
    Benchmark(
        "Smoke.GainEnergy",
        configuration: .init(
            metrics: metrics, warmupIterations: 3, scalingFactor: .one,
            maxDuration: .seconds(1), maxIterations: 100)
    ) { benchmark in
        guard let workload else { preconditionFailure("Missing setup state") }
        benchmark.startMeasurement()
        for _ in 0..<GainEnergyWorkload.framesPerBatch {
            blackHole(workload.run())
        }
        benchmark.stopMeasurement()
        precondition(workload.checksum == GainEnergyWorkload.expectedChecksum)
        precondition(workload.energy == GainEnergyWorkload.expectedEnergy)
    } setup: {
        workload = try GainEnergyWorkload()
    } teardown: {
        // Release setup buffers outside the measured region.
        workload = nil
    }

    #if AllocationDiagnostics
        Benchmark(
            "Capability.AllocationARC",
            configuration: .init(
                metrics: metrics, warmupIterations: 3, scalingFactor: .one,
                maxDuration: .seconds(1), maxIterations: 100)
        ) { benchmark in
            benchmark.startMeasurement()
            exerciseAllocationAndARC()
            benchmark.stopMeasurement()
        }
    #endif
}
