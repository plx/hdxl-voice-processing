// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "VoiceBenchmarks",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "VoiceDSPBenchmarks", targets: ["VoiceDSPBenchmarks"]),
        .executable(name: "WorkloadCheck", targets: ["WorkloadCheck"]),
    ],
    traits: [
        .trait(
            name: "AllocationDiagnostics", description: "Enable malloc and ARC diagnostic metrics")
    ],
    dependencies: [
        .package(name: "HDXLVoiceProcessing", path: ".."),
        .package(
            url: "https://github.com/ordo-one/benchmark.git", exact: "1.38.0",
            traits: [
                .trait(
                    name: "MallocInterposer", condition: .when(traits: ["AllocationDiagnostics"]))
            ]),
    ],
    targets: [
        .target(
            name: "SmokeWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(name: "WorkloadCheck", dependencies: ["SmokeWorkload"]),
        .executableTarget(
            name: "VoiceDSPBenchmarks",
            dependencies: ["SmokeWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/VoiceDSPBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
    ],
    swiftLanguageModes: [.v6]
)
