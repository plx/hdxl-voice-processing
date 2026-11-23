import Foundation
import HDXLVoiceProcessing
import SwiftUI

/// Small deterministic source for previews and the fixed-history rendering tests.
/// Construct once outside view evaluation. This exercises public analysis outputs without capture.
struct AcousticPlotFixtures {
    let source: SourceInterval
    let axis: VisualizationTimeAxis
    let pcm: [Double]
    let schedule: AnalysisScheduleProfile
    let frames: [ScheduledFrame]
    let spectralFrames: [SpectrogramFrame]
    let spectralLayout: SpectrogramLayout
    let cepstralFrames: [PowerCepstrumFrame]
    let cepstralRecipe: CepstrogramConfiguration

    init() throws {
        let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000048")!)
        let start: Int64 = (1 << 54) + 11
        let n = 4_800
        let source = try SourceInterval(
            epoch: epoch, startSample: start, sampleCount: Int64(n), sampleRate: 16_000)
        let origin = try SourceInterval(
            epoch: epoch, startSample: start, sampleCount: 0, sampleRate: 16_000)
        let pcm = (0..<n).map { i -> Double in
            if i >= 3520 { return 0 }
            if (1580..<1600).contains(i) { return 1 }
            let phase = 2 * Double.pi * Double(i) / 16_000
            let f = i < 1920 ? 125.0 : 200.0
            return 0.45 * sin(f * phase) + 0.14 * sin(2 * f * phase) + 0.008 * sin(1777 * phase)
        }
        let c = try CepstrogramConfiguration(
            sourceSampleRate: 16_000, hopSeconds: 0.01, declaredInputBandwidthHz: 8000)
        let channels = try PCMChannelSelection(channelIndex: 0)
        let schedule = try AnalysisScheduleProfile(
            inputFormat: PCMFormat(sampleRate: 16_000, channelCount: 1, encoding: .float64),
            channels: channels,
            levels: LevelConfiguration(
                sampleRate: 16_000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
                accumulation: .direct, weighting: .none),
            pitch: YINProfile(
                estimator: YINConfiguration(
                    sampleRate: 16_000, pitchFloorHz: 80,
                    pitchCeilingHz: 450, integrationLength: 399, hopLength: 160)),
            cpps: CPPSProfile(
                cepstrogram: c,
                settings: CPPSConfiguration(
                    timeWindowSeconds: 0.02,
                    prominence: CPPConfiguration(fitMethod: .leastSquares))),
            hnr: HNRConfiguration(method: .forwardCrossCorrelation, sampleRate: 16_000))
        let analysis = try PreparedAnalysisSchedule<Double>(
            profile: schedule, origin: .init(source: origin, continuityEpoch: epoch.successor()),
            mode: .finite, expectedSampleCount: Int64(n))
        var frames: [ScheduledFrame] = []
        try pcm.withUnsafeBufferPointer {
            _ = try analysis.processInterleaved($0, interval: source) { frames.append($0) }
        }
        _ = try analysis.finish { frames.append($0) }
        let layout = try SpectrogramLayout(
            framing: FramingConfiguration(
                window: WindowSpecification(
                    definition: .hannPeriodic, sampleCount: 512, sampleRate: 16_000,
                    precision: .float64),
                hopLength: 160, partialWindowPolicy: .emitUnavailable), transformLength: 512,
            channels: channels)
        let transform = try PreparedSpectrogram<Double>(
            layout: layout, epoch: epoch, startSample: start)
        var spectra: [SpectrogramFrame] = []
        _ = try pcm.withUnsafeBufferPointer {
            try transform.process($0, interval: source) { spectra.append($0.owned()) }
        }
        _ = try transform.finish { spectra.append($0.owned()) }
        let cepstrum = try PreparedIntervalCepstrogram<Double>(configuration: c, source: source)
        try pcm.withUnsafeBufferPointer { try cepstrum.append($0, interval: source) }
        let exporter = try PowerCepstrogramExporter(configuration: c)
        var columns: [Result<PowerCepstrumFrame, any Error>] = []
        _ = try cepstrum.finish { frame in columns.append(Result { try exporter.owned(frame) }) }
        self.source = source
        axis = try VisualizationTimeAxis(origin: origin)
        self.pcm = pcm
        self.schedule = schedule
        self.frames = frames
        spectralFrames = spectra
        spectralLayout = layout
        cepstralFrames = try columns.map { try $0.get() }
        cepstralRecipe = c
    }

    func metric(_ metric: ScheduledMetric, algorithm: ScheduledAlgorithm) throws -> AcousticPlotData
    {
        let points = try frames.filter { $0.algorithm == algorithm }.map {
            try VisualizationMeasurement($0, metric: metric)
        }
        guard let series = points.first?.id.series else {
            throw VisualizationError.invalidConfiguration
        }
        let snapshot = try VisualizationMetricSnapshot(series: series, measurements: points)
        return try AcousticPlotData(
            metric: snapshot, axis: axis, recipe: VisualizationProfileSnapshot(schedule))
    }

    func waveform(pulses: PulseSnapshot? = nil) throws -> AcousticPlotData {
        let wave = try VisualizationFrameSnapshot(
            waveform: pcm, source: source, profile: schedule.identity(),
            stage: .init(name: "synthetic-mono-pcm", version: 1))
        return try AcousticPlotData(waveform: wave, axis: axis, pulses: pulses)
    }

    func primaryPlots() throws -> [AcousticPlotData] {
        guard let frame = spectralFrames.first else {
            throw VisualizationError.invalidConfiguration
        }
        return try [
            waveform(), metric(.fundamentalFrequency, algorithm: .yin),
            metric(.levelDBFS, algorithm: .levels),
            metric(.cpp, algorithm: .cpps), metric(.cpps, algorithm: .cpps),
            AcousticPlotData(spectrum: frame, axis: axis),
            AcousticPlotData(
                spectrogram: spectralFrames, layout: spectralLayout,
                axis: axis, presentation: .decibels(referencePower: 1)),
            AcousticPlotData(
                cepstrogram: cepstralFrames, configuration: cepstralRecipe, axis: axis),
            metric(.harmonicToNoiseRatio, algorithm: .hnr),
        ]
    }
}

private struct AcousticPlotGallery: View {
    let plots: [AcousticPlotData]
    @State private var selected = 0
    @State private var cursor: VisualizationSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Synthetic fixture", selection: $selected) {
                    ForEach(plots.indices, id: \.self) { i in Text(plots[i].kind.title).tag(i) }
                }
                AcousticPlotView(plots[selected], selection: $cursor)
                    .id(selected)
            }.padding()
        }
    }
}

#Preview("Acoustic plots · phone width") {
    AcousticPlotGallery(plots: try! AcousticPlotFixtures().primaryPlots()).frame(width: 350)
}

#Preview("Acoustic plots · desktop") {
    AcousticPlotGallery(plots: try! AcousticPlotFixtures().primaryPlots()).frame(width: 800)
}

#Preview("Harmonics, pulses and perturbation") {
    let fixture = try! AcousticPlotFixtures()
    AcousticPlotGallery(plots: try! AcousticPlotFamilyFixtures(fixture).plots(fixture))
}
