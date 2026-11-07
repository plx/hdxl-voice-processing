// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MacOSCaptureHost", platforms: [.macOS("27.0")],
    dependencies: [.package(name: "HDXLVoiceProcessing", path: "../..")],
    targets: [
        .executableTarget(
            name: "MacOSCaptureHost",
            dependencies: [
                .product(name: "HDXLVoiceProcessingAudio", package: "HDXLVoiceProcessing")
            ]),
        .testTarget(name: "MacOSCaptureHostTests", dependencies: ["MacOSCaptureHost"]),
    ], swiftLanguageModes: [.v6])
