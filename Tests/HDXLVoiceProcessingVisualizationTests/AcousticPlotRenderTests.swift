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
                try verifyVisualizationRender(
                    view, width: width, name: "acoustic-\(i)-\(width).png", output: output)
            }
        }
    }

}
