// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "VoiceBenchmarks",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "ConditioningBenchmarks", targets: ["ConditioningBenchmarks"]),
        .executable(name: "ConditioningWorkloadCheck", targets: ["ConditioningWorkloadCheck"]),
        .executable(name: "LargeFourierBenchmarks", targets: ["LargeFourierBenchmarks"]),
        .executable(name: "LargeFourierWorkloadCheck", targets: ["LargeFourierWorkloadCheck"]),
        .executable(name: "FourierBenchmarks", targets: ["FourierBenchmarks"]),
        .executable(name: "FourierWorkloadCheck", targets: ["FourierWorkloadCheck"]),
        .executable(name: "VoiceDSPBenchmarks", targets: ["VoiceDSPBenchmarks"]),
        .executable(name: "WorkloadCheck", targets: ["WorkloadCheck"]),
        .executable(name: "FramingBenchmarks", targets: ["FramingBenchmarks"]),
        .executable(name: "FramingWorkloadCheck", targets: ["FramingWorkloadCheck"]),
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
            name: "ConditioningWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(
            name: "ConditioningWorkloadCheck", dependencies: ["ConditioningWorkload"]),
        .executableTarget(
            name: "ConditioningBenchmarks",
            dependencies: [
                "ConditioningWorkload", .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/ConditioningBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "LargeFourierWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(
            name: "LargeFourierWorkloadCheck", dependencies: ["LargeFourierWorkload"]),
        .executableTarget(
            name: "LargeFourierBenchmarks",
            dependencies: [
                "LargeFourierWorkload", .product(name: "Benchmark", package: "benchmark"),
            ], path: "Benchmarks/LargeFourierBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "FourierWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(name: "FourierWorkloadCheck", dependencies: ["FourierWorkload"]),
        .executableTarget(
            name: "FourierBenchmarks",
            dependencies: ["FourierWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/FourierBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "SmokeWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(name: "WorkloadCheck", dependencies: ["SmokeWorkload"]),
        .target(
            name: "FramingWorkload",
            dependencies: [
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")
            ]),
        .executableTarget(name: "FramingWorkloadCheck", dependencies: ["FramingWorkload"]),
        .executableTarget(
            name: "FramingBenchmarks",
            dependencies: ["FramingWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/FramingBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .executableTarget(
            name: "VoiceDSPBenchmarks",
            dependencies: ["SmokeWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/VoiceDSPBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
    ],
    swiftLanguageModes: [.v6]
)
