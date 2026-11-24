import Foundation
import HDXLVoiceProcessing
import SwiftUI
import Testing

@testable import HDXLVoiceProcessingVisualization

@Suite struct InspectionReplayTests {
    let context = AlgorithmInspectionTests.context

    @Test func neighboringBinary64SettingsRemainDistinct() throws {
        let a = 0.005000000000000001
        let b = a.nextUp
        let settings = try AlgorithmInspectionTests.pitch(a)
        let samples = AlgorithmInspectionTests.tone(settings.requiredSampleCount, hz: 115)
        let input = try FrozenInspectionInput(
            samples: samples, source: AlgorithmInspectionTests.source(samples.count),
            context: context)
        let original = try FrozenInspectionExperiment(input: input, recipe: .pitch(settings))
        let change = try #require(
            original.compare(.pitch(AlgorithmInspectionTests.pitch(b))).settings.only)
        #expect(change.path == "/threshold")
        #expect(change.original.flatMap(Double.init) == a)
        #expect(change.changed.flatMap(Double.init) == b)
    }

    @Test func floatPreviewAndIntervalReplayMatchProduction() throws {
        let samples = AlgorithmInspectionTests.tone(4800, hz: 120).map(Float.init)
        let source = try AlgorithmInspectionTests.source(samples.count)
        let input = try FrozenInspectionInput(
            samples: samples.map(Double.init), source: source, context: context)
        let yin = try YINConfiguration(sampleRate: 16_000, inputPrecision: .float32, hopLength: 80)
        let short = try FrozenInspectionInput(
            samples: Array(input.samples.prefix(yin.requiredSampleCount)),
            source: AlgorithmInspectionTests.source(yin.requiredSampleCount), context: context)
        let pitch = try FrozenInspectionExperiment(input: short, recipe: .pitch(yin)).original
        #expect(pitch.profile == (try yin.identity()))
        #expect(pitch.curves.allSatisfy { $0.samples.yUnit == .dimensionless })
        for method in [
            ConditioningMethod.praat7WholeInterval(interpolationDepth: 50),
            .streamingPreview(lobes: 16, cutoffFraction: 0.9),
        ] {
            let c = try CepstrogramConfiguration(
                sourceSampleRate: 16_000, inputPrecision: .float32,
                hopSeconds: 0.01, declaredInputBandwidthHz: 8000, conditioningMethod: method)
            let settings = try CPPConfiguration(fitMethod: .leastSquares)
            let recipe = try CPPSProfile(
                cepstrogram: c, settings: .init(timeWindowSeconds: 0.04, prominence: settings))
            let cpp = try FrozenInspectionExperiment(
                input: input, recipe: .cpp(cepstrogram: c, prominence: settings, frame: 3))
            let inspected = try FrozenInspectionExperiment(
                input: input, recipe: .cpps(recipe, frame: 3)
            ).original
            #expect(cpp.original.measurements.first == inspected.measurements.first)
            var expected = [CPPSFrameResult]()
            if c.previewHopLength == nil {
                let worker = try PreparedIntervalCPPS<Float>(profile: recipe, source: source)
                try samples.withUnsafeBufferPointer { try worker.append($0, interval: source) }
                _ = try worker.finish { expected.append($0.result) }
            } else {
                let worker = try PreparedPreviewCPPS<Float>(
                    profile: recipe, epoch: source.epoch, startSample: source.startSample)
                _ = try samples.withUnsafeBufferPointer {
                    try worker.process($0, interval: source) { expected.append($0.result) }
                }
                _ = try worker.finish { expected.append($0.result) }
            }
            let frame = try #require(expected.first { $0.context.frameIndex == 3 })
            #expect(inspected.measurements.last == (try frame.measurementResult()))
            for curve in inspected.curves {
                let centerOnly = ["cpps-rawPower", "cpps-preparedPower"].contains(
                    curve.samples.stage.name)
                #expect(
                    curve.samples.source
                        == (centerOnly
                            ? frame.rawCPP.context.timing.source : frame.context.timing.source))
            }
            if c.previewHopLength != nil {
                #expect(frame.rawCPP.context.timing.source != frame.context.timing.source)
            }
            let tail = try #require(expected.last)
            let final = try FrozenInspectionExperiment(
                input: input, recipe: .cpps(recipe, frame: tail.context.frameIndex))
            #expect(final.original.measurements.last == (try tail.measurementResult()))
        }
    }

    @Test func liveReconfigurationAndTrackedOctaveChoiceUseCommittedClocks() throws {
        let settings = try YINConfiguration(
            sampleRate: 16_000, pitchFloorHz: 60, pitchCeilingHz: 500,
            integrationLength: 400, hopLength: 668)
        let recipe = try YINProfile(estimator: settings, tracker: .init(continuityWeight: 10))
        let epoch = StreamEpoch(streamID: UUID())
        let processor = try PreparedYINAnalyzer<Double>(profile: recipe, epoch: epoch)
        let samples =
            AlgorithmInspectionTests.tone(668, hz: 100)
            + AlgorithmInspectionTests.tone(668, hz: 200)
        func source(_ epoch: StreamEpoch) throws -> SourceInterval {
            try .init(
                epoch: epoch, startSample: 0, sampleCount: Int64(samples.count), sampleRate: 16_000)
        }
        let initial = try source(epoch)
        let prior = try InspectionHistory(
            sampling: .sampled(every: 1, maximumFrames: 3), context: context,
            source: .init(initial), profile: recipe.identity())
        let next = try epoch.successor()
        try processor.reconfigure(to: recipe, epoch: next)
        let committed = try source(processor.epoch)
        var history = try prior.nextConfiguration(
            source: .init(committed), profile: recipe.identity())
        let newContext = history.context
        var failure: (any Error)?
        _ = try samples.withUnsafeBufferPointer { pcm in
            try processor.process(pcm, interval: committed) { out in
                do {
                    try history.capture(frame: out.raw.result.frameIndex) { limits in
                        try .pitch(out, recipe: recipe, context: newContext, limits: limits)
                    }
                } catch { failure = error }
            }
        }
        if let failure { throw failure }
        #expect(history.snapshots.count == 2)
        let decision = try #require(history.snapshots.last)
        #expect(decision.context.configurationEpoch == prior.context.configurationEpoch + 1)
        #expect(decision.window.epoch == next && decision.window.startSample == 668)
        #expect(decision.dependency == committed)
        let raw = try #require(decision.measurements.first?.outcome.estimate?.value)
        let tracked = try #require(decision.measurements.last?.outcome.estimate?.value)
        #expect(abs(raw - 200) < 1 && abs(tracked - 100) < 1)
    }

    @Test func incompleteHarmonicityRetainsItsAcquiredInterval() throws {
        let samples = [0.2, -0.2]
        let source = try AlgorithmInspectionTests.source(samples.count)
        let recipe = try HNRConfiguration(method: .autocorrelation, sampleRate: 16_000)
        let worker = try PreparedIntervalHNR<Double>(
            configuration: recipe, timing: .init(source: source, includedSampleCount: 2))
        try samples.withUnsafeBufferPointer { try worker.append($0, interval: source) }
        var result: Result<AlgorithmInspection, any Error>?
        _ = try worker.finish { output in
            result = Result { try .harmonicity(output, recipe: recipe, context: context) }
        }
        let snap = try #require(result).get()
        #expect(snap.unavailability == .insufficientData && snap.curves.isEmpty)
        #expect(
            snap.window == source
                && snap.measurements.first?.outcome == .unavailable(.insufficientData))
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
