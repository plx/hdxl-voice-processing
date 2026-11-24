import Benchmark
import Foundation
import VoiceSuiteWorkload

private final class CapabilityBox { let value = 55 }

@inline(never) private func allocationControl() {
    let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    bytes.initializeMemory(as: UInt8.self, repeating: 55, count: 4096)
    blackHole(bytes)
    bytes.deallocate()
    let object = Unmanaged.passRetained(CapabilityBox())
    let retained = object.retain()
    blackHole(retained.takeUnretainedValue())
    retained.release()
    object.release()
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
    func configuration(iterations: Int) -> Benchmark.Configuration {
        Benchmark.Configuration(
            metrics: metrics, timeUnits: .nanoseconds,
            units: Dictionary(uniqueKeysWithValues: metrics.map { ($0, BenchmarkUnits.count) }),
            warmupIterations: 1, scalingFactor: .one, maxDuration: .seconds(1200),
            maxIterations: iterations)
    }
    let env = ProcessInfo.processInfo.environment
    guard let path = env["VOICE_SUITE_INPUTS"], let selected = env["VOICE_SUITE_FIXTURE"] else {
        return
    }
    let directory = URL(filePath: path, directoryHint: .isDirectory)
    for fixture in try! SuiteFixture.load(in: directory) where fixture.name == selected {
        let fixtureConfiguration = configuration(
            iterations: fixture.condition.hasPrefix("long-") ? 3 : 10)
        for composition in SuiteComposition.allCases {
            for pair in [false, true] where !pair || composition == .full {
                var workload: SuiteTrial?
                var expected: [SuiteResult] = []
                let name = (pair ? "pair." : "single.") + composition.rawValue + "." + fixture.name
                Benchmark("VoiceSuite.Run." + name, configuration: fixtureConfiguration) {
                    benchmark in
                    let trial = workload!
                    benchmark.startMeasurement()
                    let observed = try! trial.run()
                    blackHole(observed)
                    benchmark.stopMeasurement()
                    precondition(observed == expected)
                } setup: {
                    workload = try SuiteTrial(
                        item: fixture, composition: composition, directory: directory,
                        simultaneous: pair)
                    expected = try workload!.run(chunk: fixture.sampleCount)
                } teardown: {
                    expected = []
                    workload = nil
                }
            }
        }
        if fixture.name == CPPSPhaseTrial.fixtureName {
            for phase in CPPSPhase.allCases {
                var state: CPPSPhaseTrial?
                let name = "VoiceSuite.Run.phase." + phase.rawValue + "." + fixture.name
                Benchmark(name, configuration: fixtureConfiguration) { benchmark in
                    let trial = state!
                    try! trial.prepareIteration()
                    benchmark.startMeasurement()
                    blackHole(try! trial.measure())
                    benchmark.stopMeasurement()
                    _ = try! trial.check()
                } setup: {
                    state = try CPPSPhaseTrial(item: fixture, directory: directory, phase: phase)
                } teardown: {
                    state = nil
                }
            }
        }
    }
    #if AllocationDiagnostics
        Benchmark(
            "Capability.VoiceSuiteAllocationARC", configuration: configuration(iterations: 10)
        ) { benchmark in
            benchmark.startMeasurement()
            allocationControl()
            benchmark.stopMeasurement()
        }
    #endif
}
