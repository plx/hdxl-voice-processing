import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func cppObservation(
    _ db: [Double], frame: PowerCepstrumConfiguration,
    settings: CPPConfiguration
) throws -> CPPObservation {
    let worker = try PreparedCPP(CPPProfile(frame: frame, settings: settings))
    let context = try cepstrumContext(count: frame.frameLength, rate: frame.sampleRate)
    let power = db.map { pow(10, $0 / 10) }
    var result: CPPObservation?
    try power.withUnsafeBufferPointer {
        try worker.analyzePowerCepstrum($0, context: context) { output in
            #expect(output.result.unavailability == nil)
            result = output.result.observation
        }
    }
    return try #require(result)
}

@Test func cppSelectionMatchesSortedOrderStatisticsForTiesAndAdversarialOrders() {
    var state: UInt64 = 35
    for count in Array(1...33) + [65, 128, 257, 1024, 4096] {
        let random = (0..<count).map { _ -> Double in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Double(Int(state >> 32) % 53 - 26)
        }
        for source in [
            random, random.sorted(), random.sorted(by: >),
            [Double](repeating: -3, count: count),
            (0..<count).map { Double(min($0, count - $0)) },
        ] {
            let sorted = source.sorted()
            let middle = count / 2
            let expected =
                count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            var working = source
            let actual = working.withUnsafeMutableBufferPointer {
                CPPSelection.median($0, count: count)
            }
            #expect(actual == expected)
        }
    }
}

@Test func cppStraightBackgroundsAndIndependentParabolicPeakHaveKnownProminence() throws {
    let frame = try PowerCepstrumConfiguration()
    for method in CPPFitMethod.allCases {
        let settings = try CPPConfiguration(
            fitStartSeconds: 0.02, fitEndSeconds: 0.03, fitMethod: method)
        let line = (0..<frame.binCount).map { 20 - 100 * Double($0) * 0.0001 }
        let linear = try cppObservation(line, frame: frame, settings: settings)
        #expect(abs(linear.slopeDBPerSecond + 100) < 1e-8)
        #expect(abs(linear.interceptDB - 20) < 1e-10)
        #expect(abs(linear.prominenceDB) < 1e-10)
        #expect(linear.residualRMSDB < 1e-10)

        var peak = [Double](repeating: 20, count: frame.binCount)
        peak[79] = 28
        peak[80] = 31
        peak[81] = 30
        let observation = try cppObservation(peak, frame: frame, settings: settings)
        #expect(abs(observation.peakQuefrencySeconds - 0.008025) < 1e-14)
        #expect(abs(observation.peakDB - 31.125) < 1e-12)
        #expect(abs(observation.backgroundDB - 20) < 1e-12)
        #expect(abs(observation.prominenceDB - 11.125) < 1e-12)
        #expect(!observation.usedBidirectionalTieRule)
    }
}

@Test func cppRegressionMethodsMatchFourPointClosedFormWithAnOutlier() throws {
    let frame = try PowerCepstrumConfiguration(sampleRate: 4000, pitchFloorHz: 1000)
    var bins = (0..<frame.binCount).map { 3 + 2 * Double($0) }
    bins[4] += 20
    let expected: [(CPPFitMethod, Double, Double)] = [
        (.leastSquares, 32_000, -7),
        (.siegelRepeatedMedian, 8_000, 3),
        (.praat7002Robust, 8_000, 3),
        (.completeTheilSen, (16.0 / 3) * 4000, -2),
    ]
    for (method, slope, intercept) in expected {
        let settings = try CPPConfiguration(
            fitStartSeconds: 0.00025, fitEndSeconds: 0.001, fitMethod: method)
        let observation = try cppObservation(bins, frame: frame, settings: settings)
        #expect(abs(observation.slopeDBPerSecond - slope) < 1e-7)
        #expect(abs(observation.interceptDB - intercept) < 1e-11)
        #expect(
            abs(observation.prominenceDB - (observation.peakDB - observation.backgroundDB)) < 1e-12)
    }
}

@Test func cppZeroPowerIsFiniteAndUnavailableUpstreamRemainsUnavailable() throws {
    let frame = try PowerCepstrumConfiguration()
    let profile = CPPProfile(frame: frame, settings: try CPPConfiguration.murtonRecipePraat7())
    let worker = try PreparedCPP(profile)
    let context = try cepstrumContext(count: frame.frameLength, rate: frame.sampleRate)
    try [Double](repeating: 0, count: frame.binCount).withUnsafeBufferPointer { input in
        try worker.analyzePowerCepstrum(input, context: context) { output in
            #expect(output.result.observation?.prominenceDB == 0)
            #expect(output.result.observation?.peakDB == -300)
            #expect(output.result.unavailability == nil)
        }
    }
    let upstream = try PreparedPowerCepstrum(frame)
    try [Double](repeating: 0, count: frame.frameLength).withUnsafeBufferPointer { input in
        try upstream.analyze(input, context: context) { cepstrum in
            do {
                try worker.analyze(cepstrum) { output in
                    #expect(output.result.unavailability == .silence)
                    #expect(output.result.observation == nil)
                    for stage in CPPIntermediate.allCases { #expect(output.values(stage).isEmpty) }
                }
            } catch { Issue.record(error) }
        }
    }
}

@Test func cppPinnedRobustAndCompleteSiegelKeepTheirDifferentMathematicalDefinitions() throws {
    let frame = try PowerCepstrumConfiguration(sampleRate: 4000, pitchFloorHz: 1000)
    // Five fit samples y=k² at x=k/4000, k=1...5. Their pointwise slope
    // medians in bin units are 4.5,5.5,6,6.5,7.5: full median6, first-four5.75.
    let values = (0..<frame.binCount).map { Double($0 * $0) }
    for (method, slope, intercept) in [
        (CPPFitMethod.siegelRepeatedMedian, 24_000.0, -8.0),
        (.praat7002Robust, 23_000.0, -7.0),
    ] {
        let settings = try CPPConfiguration(
            fitStartSeconds: 0.00025, fitEndSeconds: 0.00125,
            fitMethod: method)
        let actual = try cppObservation(values, frame: frame, settings: settings)
        #expect(abs(actual.slopeDBPerSecond - slope) < 1e-7)
        #expect(abs(actual.interceptDB - intercept) < 1e-11)
    }
}

@Test func cppRangeResolutionAndPreparationHaveExplicitLimits() throws {
    let frame = try PowerCepstrumConfiguration()
    let auto = try CPPLayout(
        profile: CPPProfile(frame: frame, settings: CPPConfiguration.murtonRecipePraat7()))
    #expect(auto.firstFitBin == 1 && auto.lastFitBin == 512 && auto.fitPointCount == 512)
    #expect(auto.fitStartSeconds == 0 && auto.fitEndSeconds == 0.0512)
    let explicit = try CPPLayout(
        profile: CPPProfile(
            frame: frame,
            settings: CPPConfiguration(fitEndSeconds: 1, fitMethod: .leastSquares)))
    #expect(explicit.firstFitBin == 10 && explicit.lastFitBin == 512)
    let small = try CPPLayout(
        profile: CPPProfile(
            frame: frame,
            settings: CPPConfiguration(fitStartSeconds: 0.001, fitEndSeconds: 0.0011)))
    #expect(small.unavailability == .insufficientData)
    let outside = try CPPLayout(
        profile: CPPProfile(
            frame: frame,
            settings: CPPConfiguration(pitchFloorHz: 1, pitchCeilingHz: 2)))
    #expect(outside.unavailability == .unsupportedRange)
    let largeFrame = try PowerCepstrumConfiguration(sampleRate: 192_000, pitchFloorHz: 60)
    #expect(throws: CPPError.capacityExceeded) {
        try PreparedCPP(CPPProfile(frame: largeFrame, settings: CPPConfiguration()))
    }
    let linear = try PreparedCPP(
        CPPProfile(
            frame: largeFrame,
            settings: CPPConfiguration(fitMethod: .leastSquares)))
    #expect(linear.layout.fitPointCount > CPPConfiguration.maximumRobustFitPoints)
}

@Test func cppRejectsInvalidInputBeforeMutationAndPreservesBorrowDuringReentry() throws {
    let frame = try PowerCepstrumConfiguration()
    let worker = try PreparedCPP(
        CPPProfile(frame: frame, settings: CPPConfiguration(fitMethod: .leastSquares)))
    let context = try cepstrumContext(count: frame.frameLength, rate: frame.sampleRate)
    let valid = [Double](repeating: 100, count: frame.binCount)
    for invalid in [-1.0, .nan, .infinity] {
        var values = valid
        values[42] = invalid
        #expect(throws: CPPError.invalidInput) {
            try values.withUnsafeBufferPointer {
                try worker.analyzePowerCepstrum($0, context: context) { _ in
                    Issue.record("Invalid input emitted")
                }
            }
        }
    }
    try valid.withUnsafeBufferPointer { input in
        try worker.analyzePowerCepstrum(input, context: context) { output in
            let before = Array(output.values(.cepstralDB))
            #expect(throws: CPPError.reentrantCall) {
                try worker.analyzePowerCepstrum(input, context: context) { _ in
                    Issue.record("Reentry emitted")
                }
            }
            #expect(Array(output.values(.cepstralDB)) == before)
            #expect(output.result.observation?.prominenceDB == 0)
            do {
                let result = try output.result.measurementResult()
                #expect(
                    result.measurement.kind == .cpp && result.measurement.unit == .decibelsRatio)
                #expect(result.timing == context.timing)
                #expect(
                    try JSONDecoder().decode(
                        MeasurementResult.self, from: JSONEncoder().encode(result)) == result)
            } catch { Issue.record(error) }
        }
    }
}
