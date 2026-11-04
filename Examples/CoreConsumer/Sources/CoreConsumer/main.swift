import Foundation
import HDXLVoiceProcessing

let source = try PCMFormat(sampleRate: 48_000, channelCount: 1)
print("PCM: \(source.sampleRate) Hz, \(source.channelCount) channel(s)")

// This demonstrates metadata and unavailable results, not an implemented RMS algorithm.
let profile = try AnalysisProfile(
    identifier: VersionedIdentifier(name: "consumer-example", version: 1),
    measurement: MeasurementDescriptor(
        kind: .rms, unit: .normalizedAmplitude,
        algorithm: VersionedIdentifier(name: "example-rms", version: 1)),
    inputFormat: source, channels: PCMChannelSelection(channelIndex: 0), precision: .float64,
    frameLength: 480, hopLength: 480, analysisSampleRate: source.sampleRate,
    window: VersionedIdentifier(name: "rectangular", version: 1),
    preprocessing: [:], algorithmSettings: ["averaging": .text("mean-square")],
    partialWindowPolicy: .discard)
let support = try SourceInterval(
    epoch: StreamEpoch(streamID: UUID()), startSample: 0, sampleCount: 0,
    sampleRate: source.sampleRate)
let result = try MeasurementResult(
    measurement: profile.measurement, profile: profile.identity(),
    timing: AnalysisTiming(source: support, includedSampleCount: 0),
    outcome: .unavailable(.insufficientData))
let restored = try JSONDecoder().decode(MeasurementResult.self, from: result.canonicalJSON())
switch restored.outcome {
case .available(let estimate): print("\(estimate.value) \(restored.measurement.unit.rawValue)")
case .unavailable(let reason): print("Measurement unavailable: \(reason.rawValue)")
}
