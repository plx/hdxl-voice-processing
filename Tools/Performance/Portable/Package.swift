// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PortableWorkloads",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "WorkloadReplay", targets: ["WorkloadReplay"]),
        .executable(name: "ReplayWorkloads", targets: ["ReplayWorkloads"]),
    ],
    dependencies: [.package(name: "Voice", path: "../../..")],
    targets: [
        .target(
            name: "WorkloadReplay",
            dependencies: [.product(name: "HDXLVoiceProcessing", package: "Voice")]),
        .executableTarget(name: "ReplayWorkloads", dependencies: ["WorkloadReplay"]),
    ])
