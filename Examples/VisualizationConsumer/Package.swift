// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "VisualizationConsumer",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [.package(name: "HDXLVoiceProcessing", path: "../..")],
    targets: [
        .executableTarget(
            name: "VisualizationConsumer",
            dependencies: [
                .product(name: "HDXLVoiceProcessingVisualization", package: "HDXLVoiceProcessing")
            ])
    ],
    swiftLanguageModes: [.v6]
)
