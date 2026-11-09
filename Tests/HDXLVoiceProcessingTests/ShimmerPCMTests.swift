import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func shimmerPCMWorker<Sample: BinaryFloatingPoint & Sendable>(
    _ type: Sample.Type, rolling: Bool = false
) throws -> PreparedPCMShimmer<Sample> {
    let precision: AnalysisPrecision = type == Float.self ? .float32 : .float64
    return try PreparedPCMShimmer(
        configuration: ShimmerConfiguration(
            sampleRate: 4000, inputPrecision: precision,
            applicability: rolling ? .exploratoryRolling : .sustainedPhonation,
            rollingWindowSampleCount: rolling ? 160 : nil),
        pulseConfiguration: PulseConfiguration(
            sampleRate: 4000, inputPrecision: precision, pitchCeilingHz: 1000,
            support: rolling ? .independentlyAnchoredBlock : .completeInterval),
        maximumSampleCount: 400, maximumF0FrameCount: 20, maximumTrackingAttempts: 1024)
}

private func checkShimmerPCMGain<Sample: BinaryFloatingPoint & Sendable>(_ type: Sample.Type) throws
{
    let worker = try shimmerPCMWorker(type)
    let original = pulseCycleTrain()
    let contour = try pulseContour(count: original.count)
    let timing = try pulseTiming(count: original.count)
    var baseline: ShimmerAnalysisResult?
    for gain in [1.0, -1.0, 0.125, -0.125] {
        let samples = original.map { Sample($0 * gain) }
        try samples.withUnsafeBufferPointer { input in
            try worker.analyze(input, contour: contour, timing: timing) { output in
                let result = output.result
                #expect(result.coverage.acceptedAmplitudeCount > 35)
                #expect(result.coverage.acceptedAPQ11NeighborhoodCount > 20)
                #expect(result.inputProvenance.kind == .acousticPulses)
                #expect(
                    result.inputProvenance.amplitudeSourceProfile == output.pulses.result.profile)
                #expect(result.inputProvenance.f0ContourIdentity == (try contour.identity()))
                #expect(result.dependencyTiming == output.pulses.result.timing)
                for variant in ShimmerVariant.allCases {
                    let value = try #require(result.estimate(variant).value)
                    #expect(value >= 0 && value < 1e-6)
                    if let baseline {
                        #expect(
                            abs(value - (try #require(baseline.estimate(variant).value))) < 1e-12)
                    }
                }
                if let apq3 = result.apq3.value { #expect(result.dda.value == 3 * apq3) }
                if baseline == nil { baseline = result }
                let snapshot = try output.snapshotAmplitudes(maximumCount: 1024)
                #expect(snapshot.count == output.pulses.landmarks.count)
                for record in snapshot where record.rejections.isEmpty {
                    #expect(
                        record.amplitude
                            == output.pulses.amplitudes[Int(record.sequenceIndex)].rmsAmplitude)
                }
            }
        }
    }
}

@Test func shimmerPCMUsesSharedRMSExtractionAndPreservesGainAndPolarity() throws {
    try checkShimmerPCMGain(Float.self)
    try checkShimmerPCMGain(Double.self)
}

@Test func shimmerPCMQueryRequiresNeighboringPulsesAndCarriesExploratoryMetadata() throws {
    let worker = try shimmerPCMWorker(Double.self, rolling: true)
    let samples = pulseCycleTrain()
    let contour = try pulseContour(count: samples.count)
    let timing = try pulseTiming(count: samples.count)
    try samples.withUnsafeBufferPointer { input in
        try worker.analyze(input, contour: contour, timing: timing) { output in
            let query = output.result.query
            #expect(query.startSeconds == 0.1 - 0.04 && query.endSeconds == 0.1)
            #expect(output.result.coverage.acceptedAmplitudeCount > 8)
            #expect(output.result.coverage.acceptedAmplitudeCount < 22)
            for record in output.amplitudes where record.rejections.isEmpty {
                let i = Int(record.sequenceIndex)
                #expect(output.pulses.landmarks[i - 1].timeSeconds >= query.startSeconds)
                #expect(output.pulses.landmarks[i + 1].timeSeconds <= query.endSeconds)
            }
            let scalar = try output.result.measurementResult(.local)
            #expect(
                try #require(scalar.outcome.estimate).warnings.contains(.exploratoryApplicability))
        }
    }
}

@Test func shimmerPCMRejectsProfileMismatchAndInvalidClippedPCMWithoutPublishing() throws {
    #expect(throws: ShimmerError.invalidConfiguration) {
        try PreparedPCMShimmer<Double>(
            configuration: ShimmerConfiguration(sampleRate: 4000),
            pulseConfiguration: PulseConfiguration(
                sampleRate: 4000, maximumAdjacentPeriodFactor: 2),
            maximumSampleCount: 400, maximumF0FrameCount: 20, maximumTrackingAttempts: 1024)
    }
    #expect(throws: ShimmerError.invalidConfiguration) {
        try PreparedPCMShimmer<Double>(
            configuration: ShimmerConfiguration(sampleRate: 4000),
            pulseConfiguration: PulseConfiguration(
                sampleRate: 4000, support: .independentlyAnchoredBlock),
            maximumSampleCount: 400, maximumF0FrameCount: 20, maximumTrackingAttempts: 1024)
    }
    let worker = try shimmerPCMWorker(Double.self)
    let samples = pulseCycleTrain()
    let contour = try pulseContour(count: samples.count)
    let timing = try pulseTiming(count: samples.count)
    for badValue in [Double.nan, .infinity, 1.5, -1.5] {
        var invalid = samples
        invalid[399] = badValue
        var emitted = false
        #expect(throws: PulseError.invalidInput) {
            try invalid.withUnsafeBufferPointer {
                try worker.analyze($0, contour: contour, timing: timing) { _ in emitted = true }
            }
        }
        #expect(!emitted)
    }
    enum ConsumerFailure: Error { case intentional }
    try samples.withUnsafeBufferPointer { input in
        #expect(throws: ConsumerFailure.self) {
            try worker.analyze(input, contour: contour, timing: timing) { _ in
                #expect(throws: ShimmerError.reentrantCall) { try worker.reset() }
                #expect(throws: ShimmerError.reentrantCall) {
                    try worker.analyze(input, contour: contour, timing: timing)
                }
                throw ConsumerFailure.intentional
            }
        }
        let recovered = try worker.analyze(input, contour: contour, timing: timing)
        #expect(recovered.local.status == .available)
    }
}
