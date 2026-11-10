import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func swipeFrameTiming(_ count: Int, rate: Int = 4000, start: Int64 = 0) throws
    -> AnalysisTiming
{
    try AnalysisTiming(
        source: SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: start,
            sampleCount: Int64(count), sampleRate: Double(rate)),
        includedSampleCount: Int64(count))
}

@Test func swipePrimeHarmonicValleysAndPeriodRefinementHaveIndependentAnchors() throws {
    let harmonics = [1, 2, 3, 5, 7, 11, 13]
    for (ratio, expected) in [
        (0.0, 0.0), (0.5, -0.5), (1, 1), (1.5, -1), (2, 1),
        (2.5, -1), (3, 1), (3.5, -0.5), (4, 0), (4.5, -0.5),
        (5, 1), (6, 0), (7, 1), (9, 0), (11, 1),
    ] {
        let actual = harmonics.reduce(0.0) {
            $0 + SWIPEPrimeNumerics.harmonicLobe(ratio: ratio, harmonic: $1)
        }
        #expect(abs(actual - expected) < 1e-14)
    }
    for ratio in [0.25, 0.75, 1.25, 1.75] {
        #expect(SWIPEPrimeNumerics.harmonicLobe(ratio: ratio, harmonic: 1) == 0)
    }
    let frequencies = [100.0, 125, 160]
    let strengths: [Double?] = frequencies.map { 1 - 20 * pow(125 / $0 - 1.03, 2) }
    strengths.withUnsafeBufferPointer {
        let result = SWIPEPrimeNumerics.refine(
            frequencies: frequencies, strengths: $0, selected: 1, threshold: 0.2)
        #expect(result.isRefined && result.isThresholdQualified)
        #expect(abs(result.frequencyHz - 125 / 1.03) < 1e-12)
        #expect(abs(result.pitchStrength - 1) < 1e-14)
    }
    for values: [Double?] in [[1, 1, 0.5], [0.5, 1, 1], [1, 0, 1], [nil, 1, 0.5]] {
        values.withUnsafeBufferPointer {
            let result = SWIPEPrimeNumerics.refine(
                frequencies: frequencies, strengths: $0, selected: 1, threshold: 0.2)
            #expect(
                !result.isRefined && result.frequencyHz == 125 && result.pitchStrength == values[1])
        }
    }
}

@Test func swipePrimeMissingZeroConstantAndBoundaryEnergyStayDistinct() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 100, pitchCeilingHz: 500, hopLength: 40)
    let worker = try PreparedSWIPEPrime<Double>(c)
    let bytes = worker.executionStatistics.preparedBufferBytes
    let n = c.requiredSampleCount
    let tone = (0..<n).map { 0.5 * sin(2 * .pi * 250 * Double($0) / 4000) }
    let timing = try swipeFrameTiming(n)
    try tone.withUnsafeBufferPointer {
        try worker.analyze($0, timing: timing) { #expect($0.result.status == .voiced) }
    }
    for (value, reason) in [(0.0, UnavailabilityReason.silence), (0.5, .lowConfidence)] {
        let samples = Array(repeating: value, count: n)
        try samples.withUnsafeBufferPointer { input in
            try worker.analyze(input, timing: timing) { output in
                #expect(output.result.status == .unvoiced && output.result.qualityReason == reason)
                #expect(output.result.observation == nil && output.result.rms == value)
                #expect(
                    output.candidateStrengths.count == worker.layout.candidateFrequenciesHz.count)
                if value == 0 {
                    #expect(output.candidateStrengths.allSatisfy { $0 == nil })
                    #expect(output.windows.allSatisfy { $0.magnitude.allSatisfy { $0 == 0 } })
                } else {
                    #expect(output.candidateStrengths.allSatisfy { $0 != nil })
                }
            }
        }
    }
    let impulse = [1.0] + Array(repeating: 0.0, count: n - 1)
    try impulse.withUnsafeBufferPointer { input in
        try worker.analyze(input, timing: timing) { output in
            #expect(
                output.result.status == .unavailable
                    && output.result.qualityReason == .analysisFailure)
            #expect(
                abs((output.result.rms ?? 0) - 1 / sqrt(Double(n))) <= (1 / sqrt(Double(n))).ulp)
            #expect(
                output.result.observation == nil
                    && output.candidateStrengths.allSatisfy { $0 == nil })
        }
    }
    for count in [0, 1, n - 1] {
        let samples = Array(tone.prefix(count))
        let partialTiming = try swipeFrameTiming(count)
        try samples.withUnsafeBufferPointer { input in
            try worker.analyze(input, timing: partialTiming) { output in
                #expect(
                    output.result.status == .unavailable
                        && output.result.unavailability == .insufficientData)
                #expect(output.result.rms == nil && output.result.normalizationPeak == nil)
                #expect(output.windows.isEmpty && output.candidateStrengths.isEmpty)
            }
        }
    }
    #expect(worker.executionStatistics.analyzedFrameCount == 4)
    #expect(worker.executionStatistics.preparedBufferBytes == bytes)
}

@Test func swipePrimeBorrowRejectsReentryInvalidPCMAndMismatchedSupport() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 100, pitchCeilingHz: 500, hopLength: 40)
    let worker = try PreparedSWIPEPrime<Double>(c)
    #expect(throws: SWIPEPrimeError.precisionMismatch) { try PreparedSWIPEPrime<Float>(c) }
    let n = c.requiredSampleCount
    let timing = try swipeFrameTiming(c.requiredSampleCount)
    let tone = (0..<n).map { sin(2 * .pi * 250 * Double($0) / 4000) }
    for invalid in [Double.nan, .infinity, -.infinity] {
        var bad = tone
        bad[n / 2] = invalid
        #expect(throws: SWIPEPrimeError.invalidInput) {
            try bad.withUnsafeBufferPointer {
                try worker.analyze($0, timing: timing) { _ in
                    Issue.record("Invalid PCM emitted output")
                }
            }
        }
    }
    let tooLong = tone + [0]
    let longTiming = try swipeFrameTiming(n + 1)
    #expect(throws: SWIPEPrimeError.invalidBufferSize) {
        try tooLong.withUnsafeBufferPointer { try worker.analyze($0, timing: longTiming) { _ in } }
    }
    let missingCoverage = try AnalysisTiming(
        source: timing.source, includedSampleCount: Int64(n - 1))
    let wrongRate = try swipeFrameTiming(n, rate: 8000)
    for context in [missingCoverage, wrongRate] {
        #expect(throws: SWIPEPrimeError.unexpectedContext) {
            try tone.withUnsafeBufferPointer { try worker.analyze($0, timing: context) { _ in } }
        }
    }
    #expect(worker.executionStatistics.analyzedFrameCount == 0)
    try tone.withUnsafeBufferPointer { input in
        try worker.analyze(input, timing: timing) { output in
            #expect(output.result.status == .voiced)
            #expect(throws: SWIPEPrimeError.reentrantCall) {
                try worker.analyze(input, timing: timing) { _ in }
            }
        }
    }
    #expect(worker.executionStatistics.analyzedFrameCount == 1)
}

@Test func swipePrimeOwnedExportsHaveAnExactAggregateBudgetAndOutliveTheBorrow() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 100, pitchCeilingHz: 500, hopLength: 40)
    let worker = try PreparedSWIPEPrime<Double>(c)
    let n = c.requiredSampleCount
    let timing = try swipeFrameTiming(c.requiredSampleCount)
    let tone = (0..<n).map { sin(2 * .pi * 250 * Double($0) / 4000) }
    var owned: SWIPEPrimeIntermediateSnapshot?
    var callbackError: (any Error)?
    try tone.withUnsafeBufferPointer { input in
        try worker.analyze(input, timing: timing) { output in
            do {
                let count =
                    output.candidateFrequenciesHz.count + output.erbFrequenciesHz.count
                    + output.candidateStrengths.count
                    + output.windows.reduce(0) {
                        $0 + $1.magnitude.count + $1.loudness.count + $1.candidateIndices.count
                            + $1.candidateStrengths.count
                    }
                    + output.erbFrequenciesHz.count
                #expect(throws: ContractError.intermediateBudgetExceeded) {
                    try output.exportIntermediates(
                        policy: IntermediateOutputPolicy(maximumScalarCount: count - 1),
                        kernelCandidateIndices: [0])
                }
                owned = try output.exportIntermediates(
                    policy: IntermediateOutputPolicy(maximumScalarCount: count),
                    kernelCandidateIndices: [0])
                #expect(throws: ContractError.intermediateBudgetExceeded) {
                    try output.exportCandidates(maximumCount: output.candidateStrengths.count - 1)
                }
                #expect(
                    try output.exportCandidates(maximumCount: output.candidateStrengths.count).count
                        == output.candidateStrengths.count)
                #expect(throws: ContractError.invalidValue) {
                    try output.kernel(candidateIndex: -1)
                }
                #expect(throws: ContractError.invalidValue) {
                    try output.kernel(candidateIndex: output.candidateStrengths.count)
                }
            } catch { callbackError = error }
        }
    }
    if let callbackError { throw callbackError }
    let snapshot = try #require(owned)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(snapshot)
    #expect(!encoded.isEmpty)
    let zeros = Array(repeating: 0.0, count: n)
    try zeros.withUnsafeBufferPointer {
        try worker.analyze($0, timing: timing) { #expect($0.result.status == .unvoiced) }
    }
    #expect(snapshot.result.status == .voiced && snapshot.windows[0].magnitude.contains { $0 > 0 })
    #expect(try encoder.encode(snapshot) == encoded)
}

@Test func swipePrimePreservesClockAnchorsAndUncertainStrengthWithoutGenericConfidence() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 4000, pitchFloorHz: 100, pitchCeilingHz: 500, hopLength: 40,
        strengthThreshold: 0.99)
    let worker = try PreparedSWIPEPrime<Double>(c)
    let n = c.requiredSampleCount
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: Int64.max - Int64(n),
        sampleCount: Int64(n), sampleRate: 4000)
    let timing = try AnalysisTiming(
        source: source, includedSampleCount: Int64(n), sourceStartSeconds: 123.5,
        hostStartNanoseconds: 1_000_000_000, completedHostNanoseconds: 2_000_000_000,
        effectiveDelaySeconds: 5)
    let tone = (0..<n).map { sin(2 * .pi * 250 * Double($0) / 4000) }
    var callbackError: (any Error)?
    try tone.withUnsafeBufferPointer { input in
        try worker.analyze(input, timing: timing, frameIndex: 91) { output in
            #expect(output.result.timing == timing && output.result.frameIndex == 91)
            #expect(
                output.result.status == .uncertain && output.result.qualityReason == .lowConfidence)
            #expect(output.result.observation != nil && output.result.unavailability == nil)
            do {
                let measurement = try output.result.measurementResult()
                if case .available(let estimate) = measurement.outcome {
                    #expect(estimate.confidence == nil && estimate.warnings == [.lowConfidence])
                } else {
                    Issue.record("Uncertain numeric estimate became unavailable")
                }
            } catch { callbackError = error }
        }
    }
    if let callbackError { throw callbackError }
}
