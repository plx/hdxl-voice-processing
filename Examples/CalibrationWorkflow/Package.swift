// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CalibrationWorkflow",
    platforms: [.macOS("27.0")],
    dependencies: [.package(name: "HDXLVoiceProcessing", path: "../..")],
    targets: [
        .executableTarget(
            name: "CalibrationWorkflow",
            dependencies: [
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing"),
                .product(name: "HDXLVoiceProcessingAudio", package: "HDXLVoiceProcessing"),
            ])
    ],
    swiftLanguageModes: [.v6])
