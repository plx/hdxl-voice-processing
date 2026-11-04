// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "HDXLVoiceProcessing",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "HDXLVoiceProcessing", targets: ["HDXLVoiceProcessing"]),
        .library(name: "HDXLVoiceProcessingAudio", targets: ["HDXLVoiceProcessingAudio"]),
        .library(
            name: "HDXLVoiceProcessingVisualization", targets: ["HDXLVoiceProcessingVisualization"]),
    ],
    targets: [
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
    ],
    swiftLanguageModes: [.v6]
)
