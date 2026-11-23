#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import HDXLVoiceProcessingVisualization

    @Test @MainActor func acousticPlotsRenderWithSelectionAtNarrowAndWideWidths() throws {
        _ = NSApplication.shared
        let fixture = try AcousticPlotPrimaryTests.fixture.get()
        let plots = try fixture.primaryPlots()
        let output = ProcessInfo.processInfo.environment["HDXL_VISUALIZATION_PREVIEW_OUTPUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        for (i, plot) in plots.enumerated() {
            let index = AcousticPlotIndex(
                column: plot.columns.count / 2, bin: min(3, plot.binCount - 1))
            let cursor = try #require(plot.cursor(for: index))
            for width in [350, 800] {
                let content = AcousticPlotView(plot, selection: .constant(cursor))
                    .padding(12).frame(width: CGFloat(width)).fixedSize(
                        horizontal: false, vertical: true
                    )
                    .background(.background).environment(\.colorScheme, .light)
                    .environment(\.dynamicTypeSize, width == 350 ? .accessibility2 : .large)
                    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                #expect(image.width == width && image.height > 200 && image.height < 4096)
                if let output {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(
                        to: output.appending(path: "acoustic-\(i)-\(width).png"), options: .atomic)
                }
            }
        }
    }
#endif
