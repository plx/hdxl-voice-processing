import Foundation
import HDXLVoiceProcessing

let source = try PCMFormat(sampleRate: 48_000, channelCount: 1)
print("PCM: \(source.sampleRate) Hz, \(source.channelCount) channel(s)")

// A metadata-only example; the prepared scheduler below executes the level algorithm.
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
// The scheduler consumes the prepared mask and resets all state between regions.
let scheduleProfile = try AnalysisScheduleProfile(
    inputFormat: PCMFormat(sampleRate: 48_000, channelCount: 1, encoding: .float64),
    channels: PCMChannelSelection(channelIndex: 0),
    levels: LevelConfiguration(
        sampleRate: 48_000, inputPrecision: .float64,
        windowLength: 480, hopLength: 240, accumulation: .compensatedSliding, weighting: .none))
let scheduleOrigin = try AnalysisScheduleOrigin(
    source: SourceInterval(
        epoch: maskSource.epoch, startSample: maskSource.startSample,
        sampleCount: 0, sampleRate: maskSource.sampleRate), continuityEpoch: maskSource.epoch)
let scheduler = try PreparedMaskedAnalysisSchedule<Double>(
    profile: scheduleProfile, origin: scheduleOrigin, mode: .finite,
    mask: PreparedAnalysisMask(timeline: mask, scope: .selected))
var scheduledFrames = 0
_ = try examplePCM.withUnsafeBufferPointer {
    try scheduler.processInterleaved($0, interval: maskSource) { frame in
        scheduledFrames += 1
        precondition(frame.coverage.selected == frame.coverage.source)
    }
}
let scheduled = try scheduler.finish()
precondition(scheduled.analyzedSampleCount == 960)
print(
    "Scheduled \(scheduledFrames) level frames from \(scheduled.analyzedSampleCount) selected samples"
)

// Both HNR families operate on core PCM without an external F0 estimate. Finite
// input delivery can use either whole-interval or explicitly causal normalization.
let hnrPCM = (0..<10_001).map { index in
    let time = Double(index) / 48_000
    return 0.3 * sin(2 * .pi * 125 * time) + 0.02 * cos(2 * .pi * 1543 * time)
}
let hnrEpoch = StreamEpoch(streamID: UUID())
let hnrSource = try SourceInterval(
    epoch: hnrEpoch, startSample: 0,
    sampleCount: Int64(hnrPCM.count), sampleRate: 48_000)
let hnrOrigin = try AnalysisScheduleOrigin(
    source: SourceInterval(
        epoch: hnrEpoch,
        startSample: 0, sampleCount: 0, sampleRate: 48_000), continuityEpoch: hnrEpoch)
for method in HNRMethod.allCases {
    for normalization in [HNRNormalizationDefinition.wholeInterval, .causalWindow] {
        let configuration = try HNRConfiguration(
            method: method, sampleRate: 48_000,
            normalization: normalization)
        let recipe = SessionArchiveProfile.hnr(configuration)
        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(SessionArchiveProfile.self, from: encoded)
        precondition(decoded == recipe)
        let composition = try AnalysisScheduleProfile(
            inputFormat: PCMFormat(
                sampleRate: 48_000,
                channelCount: 1, encoding: .float64), channels: .arithmeticMean, hnr: configuration)
        let worker = try PreparedAnalysisSchedule<Double>(
            profile: composition, origin: hnrOrigin,
            mode: .finite, expectedSampleCount: Int64(hnrPCM.count))
        var frames = 0
        var finiteScalars = 0
        var exportError: (any Error)?
        func observe(_ frame: ScheduledFrame) {
            frames += 1
            do {
                let output = try frame.export(.harmonicToNoiseRatio)
                if output.result.outcome.estimate != nil { finiteScalars += 1 }
                precondition(output.result.measurement.unit == .decibelsRatio)
                precondition(output.dependencyTiming.source.sampleCount > 0)
            } catch { exportError = error }
        }
        try hnrPCM.withUnsafeBufferPointer {
            try worker.processInterleaved($0, interval: hnrSource, emit: observe)
        }
        let completion = try worker.finish(emit: observe)
        if let exportError { throw exportError }
        precondition(frames > 0 && finiteScalars > 0 && !completion.isCancelled)
        print(
            "HNR \(method.rawValue)/\(normalization.rawValue): \(frames) frames, \(finiteScalars) finite scalars"
        )
    }
}
