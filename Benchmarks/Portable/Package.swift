// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "VoiceConformance",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [.package(name: "Voice", path: "../..")],
    targets: [
        .target(
            name: "VoiceSuiteWorkload",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "Voice")]),
        .executableTarget(name: "AlgorithmConformance", dependencies: ["VoiceSuiteWorkload"]),
    ])
