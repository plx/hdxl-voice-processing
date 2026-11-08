// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "AudioConsumer",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    dependencies: [.package(name: "HDXLVoiceProcessing", path: "../..")],
    targets: [
        .executableTarget(
            name: "AudioConsumer",
            dependencies: [
                .product(name: "HDXLVoiceProcessingAudio", package: "HDXLVoiceProcessing")
            ])
    ],
    swiftLanguageModes: [.v6]
)
