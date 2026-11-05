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

// Owned metadata collection is explicit and bounded to this three-window example.
// Production consumers may process borrowed output immediately on their worker.
let maskSource = try SourceInterval(
    epoch: StreamEpoch(streamID: UUID()), startSample: 12_000,
    sampleCount: 1440, sampleRate: 48_000)
let eligibility = try PreparedEnergyEligibility<Double>(
    configuration: EnergyEligibilityConfiguration(
        sampleRate: 48_000, declaredInputBandwidthHz: 24_000, windowSamples: 480),
    epoch: maskSource.epoch, startSample: maskSource.startSample)
let examplePCM = Array(repeating: 0.125, count: Int(maskSource.sampleCount))
var eligibilityFrames: [EnergyEligibilityFrame] = []
_ = try examplePCM.withUnsafeBufferPointer { samples in
    try eligibility.process(samples, interval: maskSource) { eligibilityFrames.append($0) }
}
try eligibility.finish { eligibilityFrames.append($0) }
let mask = try MaskTimeline(
    MaskPlan(
        source: maskSource, provenances: [eligibility.provenance],
        policy: MaskSelectionPolicy(selectionSources: [0]),
        observations: eligibilityFrames.map { try $0.observation(provenanceIndex: 0) },
        effectiveDelaySeconds: eligibility.configuration.effectiveDelaySeconds))
precondition(mask.coverage.selectedSampleCount == 960)
precondition(mask.selectedRegions.first?.startSample == 12_480)
print(
    "Energy selection: \(mask.coverage.selectedSampleCount)/\(mask.coverage.sourceSampleCount) original samples"
)
// A stateful downstream kernel resets at each selected region boundary; see the
// mask/CPP integration tests for end-to-end processing without joining regions.
