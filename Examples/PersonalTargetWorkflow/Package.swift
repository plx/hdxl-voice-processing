// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PersonalTargetWorkflow",
    platforms: [.macOS("27.0")],
    dependencies: [.package(name: "HDXLVoiceProcessing", path: "../..")],
    targets: [
        .executableTarget(
            name: "PersonalTargetWorkflow",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")])
    ],
    swiftLanguageModes: [.v6])
