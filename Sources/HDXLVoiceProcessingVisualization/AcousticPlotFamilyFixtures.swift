import Foundation
import HDXLVoiceProcessing

/// Additional finite examples for the pulse, perturbation, spectral-shape, LPC and H1–H2 views.
struct AcousticPlotFamilyFixtures {
    let spectralAxis: VisualizationTimeAxis
    let perturbationAxis: VisualizationTimeAxis
    let pulses: PulseSnapshot
    let jitter: [JitterAnalysisResult]
    let shimmer: [ShimmerAnalysisResult]
    let spectrum: SpectrogramFrame
    let shape: SpectralShapeResult
    let formants: BurgFormantFrame
    let harmonics: CorrectedHarmonicFrame

    init(_ f: AcousticPlotFixtures) throws {
        let timing = try AnalysisTiming(source: f.source, includedSampleCount: f.source.sampleCount)
        let contour = try PulseF0Contour(
            sampleRate: 16_000, sampleCount: f.pcm.count, firstCenterSeconds: 0.005,
            stepSeconds: 0.01, ceilingHz: 450,
            frequenciesHz: (0..<30).map { $0 < 12 ? 125 : ($0 < 22 ? 200 : 0) })
        let tracker = try PreparedPulseTracker<Double>(
            configuration: PulseConfiguration(sampleRate: 16_000),
            maximumSampleCount: f.pcm.count, maximumF0FrameCount: 30,
            maximumTrackingAttempts: 512)
        var pulses: PulseSnapshot?
        try f.pcm.withUnsafeBufferPointer { buffer in
            try tracker.analyze(buffer, contour: contour, timing: timing) {
                pulses = try $0.snapshot(maximumRecordCount: 2048)
            }
        }
        guard let pulses else { throw VisualizationError.invalidConfiguration }
        self.pulses = pulses

        // Known period and cycle-amplitude histories, including an explicitly rejected cycle.
        func fixtureInterval(_ id: String, length: Int64) throws -> SourceInterval {
            try SourceInterval(
                epoch: StreamEpoch(streamID: UUID(uuidString: id)!),
                startSample: f.source.startSample, sampleCount: length, sampleRate: 16_000)
        }
        func axis(_ source: SourceInterval) throws -> VisualizationTimeAxis {
            try VisualizationTimeAxis(
                origin: .init(
                    epoch: source.epoch, startSample: source.startSample,
                    sampleCount: 0, sampleRate: source.sampleRate))
        }
        let perturbationSource = try fixtureInterval(
            "00000000-0000-0000-0000-000000004802", length: f.source.sampleCount)
        perturbationAxis = try axis(perturbationSource)
        let cycleTiming = try AnalysisTiming(
            source: perturbationSource, includedSampleCount: perturbationSource.sampleCount)
        var end = 0.0
        let periods = try (0..<25).map { i in
            let begin = end
            end += i.isMultiple(of: 2) ? 0.008 : 0.0083
            return try JitterPeriodInput(
                startSeconds: begin, endSeconds: end,
                rejections: i == 17 ? .excluded : [])
        }
        let amplitudes = try periods.enumerated().map { i, period in
            try ShimmerAmplitudeInput(
                timeSeconds: period.startSeconds, amplitude: i.isMultiple(of: 2) ? 0.3 : 0.35,
                sequenceIndex: UInt64(i), rejections: i == 17 ? .excluded : [])
        }
        let jt = try PreparedJitter(
            configuration: JitterConfiguration(sampleRate: 16_000),
            maximumPeriodCount: periods.count)
        let sh = try PreparedShimmer(
            configuration: ShimmerConfiguration(sampleRate: 16_000),
            maximumAmplitudeCount: amplitudes.count)
        let queries: [(Double, Double)] = [(0, 0.105), (0.082, 0.202), (0.24, 0.27)]
        jitter = try queries.map { a, b in
            try periods.withUnsafeBufferPointer {
                try jt.analyze(
                    $0, dependencyTiming: cycleTiming, query: .init(startSeconds: a, endSeconds: b))
            }
        }
        shimmer = try queries.map { a, b in
            try amplitudes.withUnsafeBufferPointer {
                try sh.analyze(
                    $0, dependencyTiming: cycleTiming, query: .init(startSeconds: a, endSeconds: b))
            }
        }

        let vowel = Self.vowelWindow()
        let source = try fixtureInterval(
            "00000000-0000-0000-0000-000000004803", length: Int64(vowel.count))
        spectralAxis = try axis(source)
        let yin = try YINConfiguration(
            sampleRate: 16_000, pitchFloorHz: 80, pitchCeilingHz: 450, integrationLength: 599,
            hopLength: 160)
        let estimator = try PreparedYIN<Double>(yin)
        var pitchFrame: YINFrameResult?
        try vowel.withUnsafeBufferPointer { buffer in
            try estimator.analyze(
                buffer, timing: .init(source: source, includedSampleCount: source.sampleCount)
            ) { pitchFrame = $0.result }
        }
        guard let pitch = try pitchFrame?.measurementResult() else {
            throw VisualizationError.invalidConfiguration
        }
        let pitchEvidence = try FormantPitchEvidence(measurement: pitch)
        let burg = try BurgFormantProfile(sourceSampleRate: 16_000, ceilingHz: 5000)
        let lpc = try PreparedBurgFormants<Double>(configuration: burg, source: source)
        var poles: BurgFormantFrame?
        try vowel.withUnsafeBufferPointer { buffer in
            try lpc.analyze(buffer, source: source, pitch: { _ in pitchEvidence }) { poles = $0 }
        }
        guard let poles else { throw VisualizationError.invalidConfiguration }
        formants = poles
        let extractor = try PreparedHarmonicDifference<Double>(
            .init(fit: .init(sourceSampleRate: 16_000, pitch: .yin(yin)), formants: burg))
        harmonics = try vowel.withUnsafeBufferPointer {
            try extractor.analyze($0, source: source, pitch: pitch, formants: poles)
        }
        let layout = try SpectrogramLayout(
            framing: .init(
                window: .init(
                    definition: .hannPeriodic, sampleCount: vowel.count,
                    sampleRate: 16_000, precision: .float64),
                hopLength: vowel.count, partialWindowPolicy: .emitUnavailable),
            transformLength: 1024, channels: .init(channelIndex: 0))
        let fft = try PreparedSpectrogram<Double>(
            layout: layout, epoch: source.epoch, startSample: source.startSample)
        var row: SpectrogramFrame?
        _ = try vowel.withUnsafeBufferPointer {
            try fft.process($0, interval: source) { row = $0.owned() }
        }
        guard let row else { throw VisualizationError.invalidConfiguration }
        spectrum = row
        let settings = try SpectralShapeProfile(
            source: .frame, analysisBand: .init(lowerHz: 0, upperHz: 8000),
            relativeLogFloorDB: -120,
            bandRatio: .init(
                name: .init(name: "low-over-high", version: 1),
                numerator: .init(lowerHz: 0, upperHz: 1000),
                denominator: .init(lowerHz: 1000, upperHz: 8000)),
            fitBand: .init(lowerHz: 100, upperHz: 5000))
        shape = try PreparedSpectralShape(layout: layout, configuration: settings).evaluate(row)
    }

    /// The repository's low-F0 pole-cascade fixture, generated from its stated recipe.
    /// Keep 50 ms of steady excitation after the resonators have settled.
    private static func vowelWindow() -> [Double] {
        var phase = 1.0
        var state: UInt32 = 46_001
        var pcm = (0..<3200).map { _ -> Double in
            state = state &* 1_664_525 &+ 1_013_904_223
            let input = (phase >= 1 ? 1.0 : 0.0) + 0.002 * (Double(state) / 2_147_483_648 - 1)
            phase = phase.truncatingRemainder(dividingBy: 1) + 105.0 / 16_000
            return input
        }
        for (hz, bw) in [(550.0, 70.0), (1480, 110), (2550, 170), (3450, 210), (4250, 255)] {
            let pole = exp(-Double.pi * bw / 16_000)
            let feedback = 2 * pole * cos(2 * Double.pi * hz / 16_000)
            var previous = 0.0
            var prior = 0.0
            for i in pcm.indices {
                pcm[i] += feedback * previous - pole * pole * prior
                prior = previous
                previous = pcm[i]
            }
        }
        let peak = pcm.map(abs).max()!
        return pcm[1600..<2400].map { ($0 * 26_000 / peak).rounded() / 32_768 }
    }

    func plots(_ f: AcousticPlotFixtures) throws -> [AcousticPlotData] {
        func metric(_ points: [AcousticMetricObservation], axis: VisualizationTimeAxis) throws
            -> AcousticPlotData
        {
            guard let first = points.first else { throw VisualizationError.invalidConfiguration }
            return try AcousticPlotData(
                metric: first.measurement.id.series, observations: points, axis: axis)
        }
        guard let centroid = try AcousticMetricObservation(shape, descriptor: .centroid) else {
            throw VisualizationError.invalidConfiguration
        }
        return try [
            f.waveform(pulses: pulses),
            AcousticPlotData(
                spectrum: spectrum, axis: spectralAxis, presentation: .binRMSAmplitude,
                harmonics: harmonics.raw, formants: formants, shape: shape),
            metric([centroid], axis: spectralAxis),
            metric(
                [AcousticMetricObservation(formants, number: 1, kind: .formantFrequency)],
                axis: spectralAxis),
            metric([AcousticMetricObservation(harmonics.raw)], axis: spectralAxis),
            metric([AcousticMetricObservation(harmonics)], axis: spectralAxis),
            metric(
                jitter.map { try AcousticMetricObservation($0, variant: .local) },
                axis: perturbationAxis),
            metric(
                shimmer.map { try AcousticMetricObservation($0, variant: .db) },
                axis: perturbationAxis),
        ]
    }
}
