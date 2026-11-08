import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization

let visualizationEpoch = StreamEpoch(
    streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!, sequence: 3)

func visualizationSource(_ start: Int64 = 100, _ count: Int64 = 20) throws -> SourceInterval {
    try SourceInterval(
        epoch: visualizationEpoch, startSample: start, sampleCount: count, sampleRate: 16000)
}

func visualizationProfile() throws -> AnalysisProfile {
    try AnalysisProfile(
        identifier: VersionedIdentifier(name: "visualization-test-rms", version: 1),
        measurement: MeasurementDescriptor(
            kind: .rms, unit: .normalizedAmplitude,
            algorithm: VersionedIdentifier(name: "rms", version: 1)),
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1),
        channels: PCMChannelSelection(channelIndex: 0), precision: .float64,
        frameLength: 20, hopLength: 10, analysisSampleRate: 16000,
        window: VersionedIdentifier(name: "rectangular", version: 1),
        preprocessing: [:], algorithmSettings: ["fixture": .boolean(true)],
        partialWindowPolicy: .emitUnavailable)
}

func visualizationResult(
    start: Int64 = 100, outcome: MeasurementOutcome? = nil,
    intermediates: [IntermediateSnapshot] = []
) throws -> MeasurementResult {
    let profile = try visualizationProfile()
    return try MeasurementResult(
        measurement: profile.measurement, profile: profile.identity(),
        timing: AnalysisTiming(
            source: visualizationSource(start), includedSampleCount: 15,
            sourceStartSeconds: 42, hostStartNanoseconds: 9_000_000,
            completedHostNanoseconds: 10_000_000, effectiveDelaySeconds: 0.005),
        outcome: outcome
            ?? .available(
                ScalarEstimate(value: 0.25, confidence: 0.7, warnings: [.partialCoverage])),
        intermediatePolicy: IntermediateOutputPolicy(maximumScalarCount: 100),
        intermediates: intermediates)
}

func visualizationSnapshot(_ starts: [Int64] = [100, 110, 120]) throws
    -> VisualizationMetricSnapshot
{
    let rows = try starts.map { VisualizationMeasurement(try visualizationResult(start: $0)) }
    let key = try VisualizationSeriesKey(
        measurement: visualizationProfile().measurement, profile: visualizationProfile().identity(),
        source: VisualizationSource(visualizationSource()))
    return try VisualizationMetricSnapshot(series: key, measurements: rows)
}
