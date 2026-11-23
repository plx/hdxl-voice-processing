import SwiftUI
import Testing

@testable import HDXLVoiceProcessingVisualization

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

@Suite struct AcousticPlotRenderTests {
    @Test @MainActor func acousticPlotsRenderWithSelectionAtNarrowAndWideWidths() throws {
        #if os(macOS)
            _ = NSApplication.shared
        #endif
        let fixture = try AcousticPlotPrimaryTests.fixture.get()
        let plots =
            try fixture.primaryPlots() + AcousticPlotFamilyTests.extended.get().plots(fixture)
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
                let view = AcousticPlotView(
                    plot, selection: .constant(cursor), initialInspection: index)
                #expect(view.active == index)
                let content =
                    view
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
                let name = "acoustic-\(i)-\(width).png"
                #if os(iOS)
                    Attachment.record(UIImage(cgImage: image), named: name, as: .png)
                #elseif os(macOS)
                    if let output {
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: output.appending(path: name), options: .atomic)
                    }
                #endif
            }
        }
    }
}
