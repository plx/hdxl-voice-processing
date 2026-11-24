import HDXLVoiceProcessing

public struct SuiteRecipe: Encodable, Sendable {
    public let composition: SuiteComposition
    public let schedule: AnalysisScheduleProfile
    public let rollingCPPS: CPPSStatisticProfile
    public let scheduleIdentity: ProfileIdentity
    public let extensions: Extensions?
    public struct Extensions: Encodable, Sendable {
        public let layout: SpectrogramLayout
        public let frameShape, aggregateShape: SpectralShapeProfile
        public let mask: LTSFConfiguration
        public let harmonics: HarmonicCorrectionProfile
        public let pulses: PulseConfiguration
        public let jitter: JitterConfiguration
        public let shimmer: ShimmerConfiguration
        public let maximumTrackingAttempts = 16384
    }

    init(_ fixture: SuiteFixture, _ composition: SuiteComposition) throws {
        self.composition = composition
        let rate = fixture.sampleRate
        let precision = fixture.precision
        let full = composition.includesExtensions
        let window = rate / 20
        let hop = rate / 100
        let pitch = try YINConfiguration(
            sampleRate: rate, inputPrecision: precision, pitchFloorHz: 50, pitchCeilingHz: 700,
            integrationLength: window - (rate + 49) / 50 - 1, hopLength: hop)
        schedule = try AnalysisScheduleProfile(
            inputFormat: PCMFormat(
                sampleRate: Double(rate), channelCount: 1,
                encoding: precision == .float32 ? .float32 : .float64, layout: .interleaved),
            channels: .init(channelIndex: 0),
            levels: composition == .cpps
                ? nil
                : LevelConfiguration(
                    sampleRate: rate, inputPrecision: precision, windowLength: rate / 40,
                    hopLength: hop,
                    accumulation: .compensatedSliding,
                    weighting: .bs1770Revision5(warmupSampleCount: rate / 10)),
            pitch: composition == .cpps
                ? nil : YINProfile(estimator: pitch, tracker: YINTrackerConfiguration()),
            cpps: CPPSProfile(
                cepstrogram: CepstrogramConfiguration(
                    sourceSampleRate: rate, inputPrecision: precision, hopSeconds: 0.01,
                    declaredInputBandwidthHz: Double(rate) / 2,
                    conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9)),
                settings: CPPSConfiguration(
                    timeWindowSeconds: 0.02,
                    prominence: CPPConfiguration(
                        pitchCeilingHz: 330, fitEndSeconds: 0, fitMethod: .praat7002Robust))),
            hnr: full
                ? HNRConfiguration(
                    method: .autocorrelation, sampleRate: rate, inputPrecision: precision,
                    normalization: .causalWindow) : nil,
            swipePrime: full
                ? SWIPEPrimeConfiguration(
                    sampleRate: rate, inputPrecision: precision, hopLength: hop) : nil)
        scheduleIdentity = try schedule.identity()
        rollingCPPS = try CPPSStatisticProfile(
            measurement: schedule.cpps!, population: .allEligible,
            selection: MaskSelectionPolicy(), provenances: [], aggregation: .rollingFrameMean,
            rollingWindowSeconds: 3)
        guard full else {
            extensions = nil
            return
        }
        let framing = try FramingConfiguration(
            window: .init(
                definition: .hannPeriodic,
                sampleCount: rate / 40, sampleRate: Double(rate), precision: precision),
            hopLength: hop,
            partialWindowPolicy: .emitUnavailable)
        var fft = 1
        while fft < framing.window.sampleCount { fft *= 2 }
        let layout = try SpectrogramLayout(
            framing: framing, transformLength: fft, channels: .init(channelIndex: 0))
        func shape(_ source: SpectralShapeSource) throws -> SpectralShapeProfile {
            try SpectralShapeProfile(
                source: source, analysisBand: .init(lowerHz: 0, upperHz: 8000),
                includeDC: false, relativeLogFloorDB: -100,
                bandRatio: .init(
                    name: .init(name: "voice-suite-low-high", version: 1),
                    numerator: .init(lowerHz: 0, upperHz: 2000),
                    denominator: .init(lowerHz: 2000, upperHz: 8000)),
                fitBand: .init(lowerHz: 125, upperHz: 4000))
        }
        let exploratory = [
            "connected-speech", "noisy-speech", "long-stream", "aperiodic", "boundary",
            "inharmonic",
        ].contains(fixture.condition)
        extensions = try Extensions(
            layout: layout, frameShape: shape(.frame),
            aggregateShape: shape(.longTermSpectrum),
            mask: .init(
                sampleRate: rate, inputPrecision: precision,
                declaredInputBandwidthHz: Double(rate) / 2),
            harmonics: .init(
                fit: .init(sourceSampleRate: rate, inputPrecision: precision, pitch: .yin(pitch)),
                formants: .init(sourceSampleRate: rate, inputPrecision: precision, ceilingHz: 5000)),
            pulses: .init(sampleRate: rate, inputPrecision: precision),
            jitter: .init(
                sampleRate: rate, inputPrecision: precision,
                applicability: exploratory ? .exploratoryRolling : .sustainedPhonation,
                rollingWindowSampleCount: exploratory ? rate : nil),
            shimmer: .init(
                sampleRate: rate, inputPrecision: precision,
                applicability: exploratory ? .exploratoryRolling : .sustainedPhonation,
                rollingWindowSampleCount: exploratory ? rate : nil))
    }
}
