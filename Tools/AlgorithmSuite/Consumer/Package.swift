// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "VoiceSuiteConsumer", platforms: [.macOS("27.0")],
    dependencies: [.package(name: "Voice", path: "../../..")],
    targets: [
        .executableTarget(
            name: "ReplayVoiceSuite",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "Voice")])
    ])
