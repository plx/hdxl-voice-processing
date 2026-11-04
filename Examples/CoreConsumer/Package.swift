// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "CoreConsumer",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [.package(name: "HDXLVoiceProcessing", path: "../..")],
    targets: [
        .executableTarget(
            name: "CoreConsumer",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "HDXLVoiceProcessing")])
    ],
    swiftLanguageModes: [.v6]
)
