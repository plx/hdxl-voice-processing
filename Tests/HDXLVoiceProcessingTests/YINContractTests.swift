import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func yinProfilesRoundTripAndSeparateTrackerIdentity() throws {
    let c = try YINConfiguration(sampleRate: 16000, hopLength: 160)
    #expect(c.requiredSampleCount == 641)
    #expect(c.integrationLength == 320 && c.maximumEvaluatedLag == 321)
    #expect(c.algorithmicDelaySeconds == 641.0 / 32000)
    #expect(try c.framingConfiguration().window.sampleCount == 641)
    let p = YINProfile(estimator: c)
    let tracked = YINProfile(estimator: c, tracker: try YINTrackerConfiguration())
    #expect(try p.identity() != tracked.identity())
    #expect(try p.estimator.identity() == tracked.estimator.identity())
    #expect(try JSONDecoder().decode(YINProfile.self, from: canonicalContractJSON(p)) == p)
    #expect(
        try JSONDecoder().decode(YINProfile.self, from: canonicalContractJSON(tracked)) == tracked)
    let zero = try YINTrackerConfiguration(continuityWeight: 0)
    let negativeZero = try YINTrackerConfiguration(continuityWeight: -0.0)
    #expect(try zero.identity() == negativeZero.identity())
    #expect(throws: YINError.invalidConfiguration) {
        try YINConfiguration(
            sampleRate: 16000, pitchFloorHz: 60, pitchCeilingHz: 60.1, hopLength: 160)
    }
    #expect(throws: YINError.invalidConfiguration) {
        try YINConfiguration(sampleRate: 16000, integrationLength: 319, hopLength: 160)
    }
    #expect(throws: YINError.invalidConfiguration) {
        try YINConfiguration(sampleRate: 16000, hopLength: 642)
    }
    #expect(throws: YINError.precisionMismatch) { try PreparedYIN<Float>(c) }
    #expect(throws: YINError.invalidConfiguration) {
        try YINTrackerConfiguration(continuityWeight: .nan)
    }
    var encoded = try #require(
        JSONSerialization.jsonObject(with: canonicalContractJSON(c)) as? [String: Any])
    for (key, value) in [
        ("arithmeticPrecision", "float32"), ("definition", "yin"),
        ("interpolation", "cmndOnly"), ("neighboringTimeRefinement", "enabled"),
        ("unknown", "field"),
    ] {
        var corrupt = encoded
        corrupt[key] = value
        let data = try JSONSerialization.data(withJSONObject: corrupt)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(YINConfiguration.self, from: data)
        }
    }
    encoded["rangeBoundaryToleranceSamples"] = 0.1
    let invalid = try JSONSerialization.data(withJSONObject: encoded)
    #expect(throws: YINError.invalidConfiguration) {
        try JSONDecoder().decode(YINConfiguration.self, from: invalid)
    }
    let missingTracker = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1,
        "estimator": JSONSerialization.jsonObject(with: canonicalContractJSON(c)),
    ])
    #expect(throws: YINError.invalidConfiguration) {
        try JSONDecoder().decode(YINProfile.self, from: missingTracker)
    }
}

@Test func yinClosedFormFramesKeepAnchorsAndOwnedExports() throws {
    let c = try YINConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let worker = try PreparedYIN<Double>(c)
    let cycle: [Double] = [1, 0, -1, 0]
    let input = Array(repeating: cycle, count: 5).flatMap { $0 }.prefix(17)
    let epoch = StreamEpoch(streamID: UUID())
    let source = try SourceInterval(
        epoch: epoch, startSample: Int64.max - 17, sampleCount: 17, sampleRate: 4000)
    let timing = try AnalysisTiming(
        source: source, includedSampleCount: 17, sourceStartSeconds: 123.5,
        hostStartNanoseconds: 1_000_000_000, completedHostNanoseconds: 2_000_000_000,
        effectiveDelaySeconds: 0.25)
    var owned: [YINCandidate] = []
    var snapshots: [IntermediateSnapshot] = []
    var measurement: MeasurementResult?
    try input.withUnsafeBufferPointer { samples in
        try worker.analyze(samples, timing: timing, frameIndex: 9) { output in
            #expect(output.result.timing == timing)
            #expect(output.result.frameIndex == 9)
            #expect(output.result.status == .voiced)
            #expect(output.result.observation?.frequencyHz == 1000)
            let exact: [Double] = [0, 8, 16, 8, 0, 8, 16, 8, 0, 8]
            #expect(output.values(.scaledSquaredDifference).count == exact.count)
            for (actual, expected) in zip(output.values(.scaledSquaredDifference), exact) {
                #expect(abs(actual - expected) <= 2e-10 * 8 + 1e-12 * abs(expected))
            }
            #expect(throws: YINError.reentrantCall) {
                try worker.analyze(samples, timing: timing) { _ in }
            }
            #expect(throws: ContractError.intermediateBudgetExceeded) {
                try output.exportCandidates(maximumCount: 1)
            }
            #expect(throws: ContractError.intermediateBudgetExceeded) {
                try output.export(
                    stages: Set(YINIntermediate.allCases),
                    policy: IntermediateOutputPolicy(maximumScalarCount: 19))
            }
            do {
                owned = try output.exportCandidates(maximumCount: 2)
                snapshots = try output.export(
                    stages: Set(YINIntermediate.allCases),
                    policy: IntermediateOutputPolicy(maximumScalarCount: 20))
                measurement = try output.result.measurementResult()
            } catch { Issue.record(error) }
        }
    }
    let shortSource = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: 16, sampleRate: 4000)
    let shortTiming = try AnalysisTiming(source: shortSource, includedSampleCount: 16)
    try Array(input.prefix(16)).withUnsafeBufferPointer { samples in
        try worker.analyze(samples, timing: shortTiming) { output in
            #expect(
                output.result.status == .unavailable
                    && output.result.unavailability == .insufficientData)
            #expect(output.candidates.isEmpty)
            #expect(output.values(.scaledSquaredDifference).isEmpty)
            #expect(output.values(.cumulativeMeanNormalizedDifference).isEmpty)
            #expect(output.result.normalizationPeak == nil && output.result.rms == nil)
        }
    }
    try [Double](repeating: 0, count: 17).withUnsafeBufferPointer { samples in
        try worker.analyze(samples, timing: timing) { output in
            #expect(output.result.status == .unvoiced)
            #expect(output.values(.scaledSquaredDifference)[1] == 0)
        }
    }
    #expect(owned.map(\.integerLag) == [4, 8])
    #expect(snapshots.count == 2 && snapshots[0].values.count == 10)
    #expect(abs(snapshots[0].values[1] - 8) < 1e-8)
    let result = try #require(measurement)
    #expect(result.measurement.kind == .fundamentalFrequency && result.measurement.unit == .hertz)
    #expect(
        try JSONDecoder().decode(MeasurementResult.self, from: result.canonicalJSON()) == result)
    #expect(result.timing.sourceStartSeconds == 123.5)
}

@Test func yinInvalidInputDoesNotPoisonNextFrameAndUncertainExportIsQualified() throws {
    let c = try YINConfiguration(
        sampleRate: 4000, pitchFloorHz: 500, pitchCeilingHz: 1000, hopLength: 4)
    let worker = try PreparedYIN<Double>(c)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 0, sampleCount: 17, sampleRate: 4000)
    let timing = try AnalysisTiming(source: source, includedSampleCount: 17)
    var invalid = [Double](repeating: 0, count: 17)
    invalid[16] = .infinity
    #expect(throws: YINError.invalidInput) {
        try invalid.withUnsafeBufferPointer {
            try worker.analyze($0, timing: timing) { _ in Issue.record("Invalid PCM emitted") }
        }
    }
    #expect(worker.executionStatistics.analyzedFrameCount == 0)
    try [Double](repeating: 0, count: 17).withUnsafeBufferPointer {
        try worker.analyze($0, timing: timing) { output in
            #expect(output.result.status == .unvoiced && output.result.unavailability == .silence)
            #expect(output.result.observation == nil)
            do {
                #expect(try output.result.measurementResult().outcome == .unavailable(.silence))
            } catch { Issue.record(error) }
        }
    }
    let noise = [
        0.7, -0.2, 0.8, 0.1, -0.6, 0.4, 0.9, -0.3, 0.5, -0.9, -0.1, 0.6, 0.2, -0.4, 0.3, -0.8, -0.5,
    ]
    try noise.withUnsafeBufferPointer {
        try worker.analyze($0, timing: timing) { output in
            #expect(output.result.status == .uncertain)
            do {
                let result = try output.result.measurementResult()
                #expect(result.outcome.estimate?.warnings == [.lowConfidence])
                #expect(result.outcome.estimate?.value ?? 0 > 0)
            } catch { Issue.record(error) }
        }
    }
}
