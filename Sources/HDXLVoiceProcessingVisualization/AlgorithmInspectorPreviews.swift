import Foundation
import HDXLVoiceProcessing
import SwiftUI

/// A fixed, independently generated take for previewing production estimators.
struct InspectorPreviewFixture {
    static let context = InspectionContext(origin: .synthesizedDemonstration, configurationEpoch: 1)
    let input: FrozenInspectionInput
    let recipe: YINConfiguration
    let experiment: FrozenInspectionExperiment
    let alternative: InspectionAlternative
    let plot: AcousticPlotData

    init() throws {
        let recipe = try Self.pitch(0.10)
        let n = recipe.requiredSampleCount
        let source = try SourceInterval(
            epoch: .init(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000049")!),
            startSample: 1600, sampleCount: Int64(n), sampleRate: 16_000)
        let samples = (0..<n).map { i in
            let phase = Double(i) * 2 * Double.pi * 95 / source.sampleRate
            return 0.16 * sin(phase) + 0.55 * sin(2 * phase)
        }
        input = try .init(samples: samples, source: source, context: Self.context)
        self.recipe = recipe
        experiment = try .init(input: input, recipe: .pitch(recipe))
        alternative = try .init(
            "Raise the YIN dip threshold to 0.3", recipe: .pitch(Self.pitch(0.3)))
        let axis = try VisualizationTimeAxis(
            origin: .init(
                epoch: source.epoch, startSample: source.startSample, sampleCount: 0,
                sampleRate: source.sampleRate))
        plot = try AcousticPlotData(
            waveform: .init(
                waveform: samples, source: source,
                profile: recipe.identity(),
                stage: .init(name: "synthetic-inspector-pcm", version: 1)), axis: axis)
    }

    static func pitch(_ threshold: Double) throws -> YINConfiguration {
        try .init(
            sampleRate: 16_000, pitchFloorHz: 65, pitchCeilingHz: 450, integrationLength: 400,
            hopLength: 160, threshold: threshold)
    }
}

private struct InspectionPlotPreview: View {
    let fixture: InspectorPreviewFixture
    @State private var cursor: VisualizationSelection?
    var body: some View {
        ScrollView {
            try! AcousticPlotInspectorView(
                plot: fixture.plot, snapshots: [fixture.experiment.original], selection: $cursor
            )
            .padding()
        }
    }
}

#Preview("Pitch candidates · phone") {
    InspectionPlotPreview(fixture: try! InspectorPreviewFixture()).frame(width: 350)
}

#Preview("Frozen pitch experiment · desktop") {
    let fixture = try! InspectorPreviewFixture()
    ScrollView {
        try! FrozenInspectionExperimentView(fixture.experiment, alternatives: [fixture.alternative])
            .padding()
    }.frame(width: 800)
}

/// Preview the same scheduled CPPS calculation that supplied the plotted point.
private struct ScheduledInspectionPreview: View {
    let plot: AcousticPlotData
    let snapshot: AlgorithmInspection
    @State private var selection: VisualizationSelection?

    init() throws {
        var captured: Result<AlgorithmInspection, any Error>?
        let fixture = try AcousticPlotFixtures { borrowed in
            guard borrowed.frame.algorithm == .cpps, borrowed.frameIndex == 3 else { return }
            captured = Result { try .scheduled(borrowed, context: InspectorPreviewFixture.context) }
        }
        guard let captured else { throw VisualizationError.invalidSelection }
        snapshot = try captured.get()
        plot = try fixture.metric(.cpps, algorithm: .cpps)
        _selection = State(initialValue: .init(source: snapshot.window))
    }

    var body: some View {
        ScrollView {
            try! AcousticPlotInspectorView(plot: plot, snapshots: [snapshot], selection: $selection)
                .padding()
        }
    }
}

#Preview("Scheduled CPPS and its source") {
    try! ScheduledInspectionPreview().frame(width: 800)
}
