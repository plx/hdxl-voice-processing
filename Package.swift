// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "HDXLVoiceProcessing",
    platforms: [.macOS("27.0"), .iOS("27.0"), .watchOS("27.0")],
    products: [
        .library(name: "HDXLVoiceProcessing", targets: ["HDXLVoiceProcessing"]),
        .library(name: "HDXLVoiceProcessingAudio", targets: ["HDXLVoiceProcessingAudio"]),
        .library(
            name: "HDXLVoiceProcessingVisualization", targets: ["HDXLVoiceProcessingVisualization"]),
    ],
    traits: [
        .trait(
            name: "KernelBenchmarkAccess",
            description: "Expose isolated DSP stages to the development benchmark harness")
    ],
    targets: [
        .executableTarget(
            name: "StreamingReplayProbe",
            dependencies: ["HDXLVoiceProcessing", "HDXLVoiceProcessingAudio"],
            path: "Tools/StreamingReplayProbe"),
        .executableTarget(
            name: "PulseStageProbe", dependencies: ["HDXLVoiceProcessing"],
            path: "Tools/PulseStageProbe"),
        .executableTarget(
            name: "HNRStageProbe", dependencies: ["HDXLVoiceProcessing"],
            path: "Tools/HNRStageProbe"),
        .target(name: "HDXLVoiceProcessing"),
        .target(name: "HDXLVoiceProcessingAudio", dependencies: ["HDXLVoiceProcessing"]),
        .target(name: "HDXLVoiceProcessingVisualization", dependencies: ["HDXLVoiceProcessing"]),
        .executableTarget(
            name: "InstrumentationProbe", dependencies: ["HDXLVoiceProcessing"],
            path: "Tools/InstrumentationProbe"),
        .testTarget(
            name: "HDXLVoiceProcessingTests", dependencies: ["HDXLVoiceProcessing"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "ProductBoundaryTests",
            dependencies: ["HDXLVoiceProcessingAudio", "HDXLVoiceProcessingVisualization"]),
        .testTarget(
            name: "HDXLVoiceProcessingAudioTests", dependencies: ["HDXLVoiceProcessingAudio"]),
        .testTarget(
            name: "HDXLVoiceProcessingVisualizationTests",
            dependencies: ["HDXLVoiceProcessingVisualization"]),
    ],
    swiftLanguageModes: [.v6]
)
