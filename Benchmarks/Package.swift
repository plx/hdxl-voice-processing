// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "VoiceBenchmarks",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "CaptureBenchmarks", targets: ["CaptureBenchmarks"]),
        .executable(name: "CaptureWorkloadCheck", targets: ["CaptureWorkloadCheck"]),
        .executable(name: "ScheduleBenchmarks", targets: ["ScheduleBenchmarks"]),
        .executable(name: "ScheduleWorkloadCheck", targets: ["ScheduleWorkloadCheck"]),
        .executable(name: "TransportBenchmarks", targets: ["TransportBenchmarks"]),
        .executable(name: "TransportWorkloadCheck", targets: ["TransportWorkloadCheck"]),
        .executable(name: "YINBenchmarks", targets: ["YINBenchmarks"]),
        .executable(name: "YINWorkloadCheck", targets: ["YINWorkloadCheck"]),
        .executable(name: "CPPSBenchmarks", targets: ["CPPSBenchmarks"]),
        .executable(name: "CPPSWorkloadCheck", targets: ["CPPSWorkloadCheck"]),
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
            name: "CaptureWorkload",
            dependencies: [
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing"),
                .product(name: "HDXLVoiceProcessingAudio", package: "HDXLVoiceProcessing"),
            ]),
        .executableTarget(name: "CaptureWorkloadCheck", dependencies: ["CaptureWorkload"]),
        .executableTarget(
            name: "CaptureBenchmarks",
            dependencies: [
                "CaptureWorkload", .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/CaptureBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "ScheduleWorkload",
            dependencies: [
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")
            ]),
        .executableTarget(name: "ScheduleWorkloadCheck", dependencies: ["ScheduleWorkload"]),
        .executableTarget(
            name: "ScheduleBenchmarks",
            dependencies: [
                "ScheduleWorkload", .product(name: "Benchmark", package: "benchmark"),
            ], path: "Benchmarks/ScheduleBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "TransportWorkload",
            dependencies: [
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing"),
                .product(name: "HDXLVoiceProcessingAudio", package: "HDXLVoiceProcessing"),
            ]),
        .executableTarget(name: "TransportWorkloadCheck", dependencies: ["TransportWorkload"]),
        .executableTarget(
            name: "TransportBenchmarks",
            dependencies: ["TransportWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/TransportBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "YINWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(name: "YINWorkloadCheck", dependencies: ["YINWorkload"]),
        .executableTarget(
            name: "YINBenchmarks",
            dependencies: ["YINWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/YINBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
        .target(
            name: "CPPSWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")]),
        .executableTarget(name: "CPPSWorkloadCheck", dependencies: ["CPPSWorkload"]),
        .executableTarget(
            name: "CPPSBenchmarks",
            dependencies: ["CPPSWorkload", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/CPPSBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]),
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
