// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "SessionWorkflow",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [.package(name: "HDXLVoiceProcessing", path: "../..")],
    targets: [
        .target(
            name: "SessionWorkflowSupport",
            dependencies: [
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing"),
                .product(name: "HDXLVoiceProcessingAudio", package: "HDXLVoiceProcessing"),
            ]),
        .executableTarget(
            name: "SessionWorkflow",
            dependencies: [
                "SessionWorkflowSupport",
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing"),
                .product(name: "HDXLVoiceProcessingAudio", package: "HDXLVoiceProcessing"),
            ]),
        .testTarget(
            name: "SessionWorkflowTests",
            dependencies: [
                "SessionWorkflowSupport",
                .product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing"),
                .product(name: "HDXLVoiceProcessingAudio", package: "HDXLVoiceProcessing"),
            ]),
    ], swiftLanguageModes: [.v6])
