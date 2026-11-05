// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "VoiceBenchmarks",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "MaskBenchmarks", targets: ["MaskBenchmarks"]),
        .executable(name: "MaskWorkloadCheck", targets: ["MaskWorkloadCheck"]),
        .executable(name: "CPPBenchmarks", targets: ["CPPBenchmarks"]),
        .executable(name: "CPPWorkloadCheck", targets: ["CPPWorkloadCheck"]),
        .executable(name: "CepstrumBenchmarks", targets: ["CepstrumBenchmarks"]),
        .executable(name: "CepstrumWorkloadCheck", targets: ["CepstrumWorkloadCheck"]),
        .executable(name: "LevelBenchmarks", targets: ["LevelBenchmarks"]),
        .executable(name: "LevelWorkloadCheck", targets: ["LevelWorkloadCheck"]),
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
            name: "MaskWorkload",
            dependencies: [
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")
            ]),
        .executableTarget(name: "MaskWorkloadCheck", dependencies: ["MaskWorkload"]),
        .executableTarget(
            name: "MaskBenchmarks",
            dependencies: [
                "MaskWorkload", .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/MaskBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "CPPWorkload",
            dependencies: [
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")
            ]),
        .executableTarget(name: "CPPWorkloadCheck", dependencies: ["CPPWorkload"]),
        .executableTarget(
            name: "CPPBenchmarks",
            dependencies: [
                "CPPWorkload", .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/CPPBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "CepstrumWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(name: "CepstrumWorkloadCheck", dependencies: ["CepstrumWorkload"]),
        .executableTarget(
            name: "CepstrumBenchmarks",
            dependencies: ["CepstrumWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/CepstrumBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "LevelWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(name: "LevelWorkloadCheck", dependencies: ["LevelWorkload"]),
        .executableTarget(
            name: "LevelBenchmarks",
            dependencies: ["LevelWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/LevelBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
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
