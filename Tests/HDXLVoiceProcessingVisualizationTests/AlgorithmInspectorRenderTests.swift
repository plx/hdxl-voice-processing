import HDXLVoiceProcessing
import SwiftUI
import Testing

@testable import HDXLVoiceProcessingVisualization

#if os(macOS)
    import AppKit
#endif

@Suite struct AlgorithmInspectorRenderTests {
    @Test @MainActor func selectedFitCandidatesUnavailableCyclesAndComparisonRender() throws {
        #if os(macOS)
            _ = NSApplication.shared
        #endif
        let pitch = try InspectorPreviewFixture()
        let f = try AlgorithmInspectionFamilyTests.fixture.get()
        let families = try AlgorithmInspectionFamilyTests.families.get()
        let recipe = try CPPConfiguration(fitMethod: .leastSquares)
        let input = try FrozenInspectionInput(
            samples: f.pcm, source: f.source, context: InspectorPreviewFixture.context)
        let fit = try FrozenInspectionExperiment(
            input: input, recipe: .cpp(cepstrogram: f.cepstralRecipe, prominence: recipe, frame: 3))
        let unavailable = try AlgorithmInspection.jitter(
            try #require(families.jitter.last), recipe: .init(sampleRate: 16_000),
            context: input.context)
        let comparison = try pitch.experiment.compare(pitch.alternative.recipe)
        let views: [(String, AnyView)] = [
            ("pitch", AnyView(AlgorithmInspectorView(pitch.experiment.original))),
            ("cpp", AnyView(AlgorithmInspectorView(fit.original))),
            ("insufficient-cycles", AnyView(AlgorithmInspectorView(unavailable))),
            ("frozen", AnyView(FrozenInspectionComparisonView(comparison))),
        ]
        let output = ProcessInfo.processInfo.environment["HDXL_VISUALIZATION_PREVIEW_OUTPUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        for (name, view) in views {
            for width in [350, 800] {
                try verifyVisualizationRender(
                    view, width: width, name: "inspector-\(name)-\(width).png", output: output)
            }
        }
    }
}
