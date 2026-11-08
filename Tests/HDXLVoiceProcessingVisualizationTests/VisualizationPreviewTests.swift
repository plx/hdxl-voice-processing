import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization
import Testing

@Test func visualizationPreviewFixturesCoverAllStatesWithSyntheticOwnedData() throws {
    for scenario in VisualizationPreviewScenario.allCases {
        let fixture = try VisualizationPreviewFixture.make(scenario)
        #expect(fixture.scenario == scenario)
        #expect(fixture.snapshot.series.profile.identifier.name == "synthetic-preview-only")
        #expect(fixture.snapshot == (try VisualizationPreviewFixture.make(scenario).snapshot))
        #expect(fixture.snapshot.series.scheduledOrigin == nil)
        switch scenario {
        case .noData, .unsupported, .loading, .failure:
            #expect(fixture.snapshot.measurements.isEmpty)
        default: #expect(fixture.snapshot.measurements.count == 3)
        }
        if case .unsupportedMetric(let kind) = fixture.state {
            #expect(kind == fixture.snapshot.series.measurement.kind)
        }
        if scenario == .gap {
            #expect(
                fixture.snapshot.measurements.last?.result.outcome
                    == .unavailable(.missingAcquisition))
            #expect(
                fixture.snapshot.boundaries.first?.missingSource
                    == fixture.snapshot.measurements.last?.id.support)
        }
    }
}

@Test func visualizationInventorySupportsLaterAlgorithmsWithoutRequiringTheirExecution() throws {
    let inventory = try VisualizationComponentDescriptor.standardInventory()
    #expect(inventory.count == 7 && Set(inventory.map(\.id)).count == 7)
    let scalar = try #require(inventory.first { $0.kind == .metric })
    #expect(scalar.measurements == Set(MeasurementKind.allCases))
    let extensionPoint = try VisualizationComponentDescriptor(
        id: VersionedIdentifier(name: "host-harmonic-inspector", version: 1), kind: .custom,
        title: "Harmonic inspection", measurements: [.h1MinusH2, .correctedH1MinusH2],
        frameDomains: [.spectrum, .diagnostic])
    #expect(extensionPoint.measurements.contains(.correctedH1MinusH2))
    #expect(throws: VisualizationError.invalidConfiguration) {
        try VisualizationComponentDescriptor(id: extensionPoint.id, kind: .custom, title: "  ")
    }
}

#if os(macOS)
    import AppKit
    import SwiftUI

    /// Optional output contains only these named synthetic fixtures. No microphone,
    /// external file, host recording, calibration dataset or environment dump is read.
    @Test(arguments: VisualizationPreviewScenario.allCases)
    @MainActor func visualizationPreviewsRenderAtPhoneAndDesktopWidths(
        _ scenario: VisualizationPreviewScenario
    ) throws {
        _ = NSApplication.shared
        let fixture = try VisualizationPreviewFixture.make(scenario)
        let output = ProcessInfo.processInfo.environment["HDXL_VISUALIZATION_PREVIEW_OUTPUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        for width in [350, 800] {
            for (name, size) in [
                ("standard", DynamicTypeSize.large), ("accessible", .accessibility3),
            ] {
                let content = VisualizationFixtureView(fixture: fixture)
                    .frame(width: CGFloat(width))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.background)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                    .environment(\.colorScheme, .light)
                    .environment(\.dynamicTypeSize, size)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                #expect(image.width == width)
                #expect(image.height > 150 && image.height < 8192)
                if let output {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(
                        to: output.appending(path: "\(scenario.rawValue)-\(width)-\(name).png"),
                        options: .atomic)
                }
            }
        }
    }
#endif
