import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func cppProfileIdentityPinsEverySettingAndRejectsContradictorySerialization() throws {
    let frame = try PowerCepstrumConfiguration()
    let base = try CPPConfiguration.murtonRecipePraat7()
    let original = CPPProfile(frame: frame, settings: base)
    let alternate = [
        try CPPConfiguration(
            pitchFloorHz: 61, pitchCeilingHz: 330, fitEndSeconds: 0, fitMethod: .praat7002Robust),
        try CPPConfiguration(pitchCeilingHz: 331, fitEndSeconds: 0, fitMethod: .praat7002Robust),
        try CPPConfiguration(
            pitchCeilingHz: 330, interpolation: .none, fitEndSeconds: 0, fitMethod: .praat7002Robust
        ),
        try CPPConfiguration(
            pitchCeilingHz: 330, fitStartSeconds: 0.002, fitEndSeconds: 0,
            fitMethod: .praat7002Robust),
        try CPPConfiguration(pitchCeilingHz: 330, fitEndSeconds: 0.05, fitMethod: .praat7002Robust),
        try CPPConfiguration(
            pitchCeilingHz: 330, fitEndSeconds: 0, fitMethod: .siegelRepeatedMedian),
        try CPPConfiguration(pitchCeilingHz: 330, fitEndSeconds: 0, fitMethod: .leastSquares),
        try CPPConfiguration(pitchCeilingHz: 330, fitEndSeconds: 0, fitMethod: .completeTheilSen),
    ]
    for settings in alternate {
        #expect(try CPPProfile(frame: frame, settings: settings).identity() != original.identity())
    }
    let pipeline = try CepstrogramConfiguration(
        sourceSampleRate: 48_000, declaredInputBandwidthHz: 24_000)
    for profile in [original, CPPProfile(cepstrogram: pipeline, settings: base)] {
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(CPPProfile.self, from: data) == profile)
        let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["schemaVersion", "frame", "cepstrogram", "settings"] {
            var changed = encoded
            changed.removeValue(forKey: key)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(
                    CPPProfile.self, from: JSONSerialization.data(withJSONObject: changed))
            }
        }
        var future = encoded
        future["futureSetting"] = 42
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CPPProfile.self, from: JSONSerialization.data(withJSONObject: future))
        }
    }
    let complete = try CPPProfile(
        frame: frame, settings: CPPConfiguration(fitMethod: .completeTheilSen)
    ).identity()
    #expect(complete.identifier.name == "complete-theil-sen-cpp-praat7-peak")
    #expect(try original.identity().identifier.name == "praat-7.0.02-straight-cpp")
    for value in [Double.nan, .infinity, -1, 0, 20_001] {
        #expect(throws: CPPError.invalidConfiguration) { try CPPConfiguration(pitchFloorHz: value) }
    }
    #expect(throws: CPPError.invalidConfiguration) {
        try CPPConfiguration(pitchFloorHz: 330, pitchCeilingHz: 60)
    }
    #expect(throws: CPPError.invalidConfiguration) {
        try CPPConfiguration(fitStartSeconds: 0.05, fitEndSeconds: 0.001)
    }
}

@Test func cppNarrowSearchAndInsufficientFitHaveDistinctOutcomes() throws {
    let frame = try PowerCepstrumConfiguration()
    let context = try cepstrumContext(count: frame.frameLength, rate: frame.sampleRate)
    var values = [Double](repeating: 100, count: frame.binCount)
    values[80] = 10
    values[81] = 100
    let narrow = try CPPConfiguration(
        pitchFloorHz: 1 / 0.00804, pitchCeilingHz: 1 / 0.00802,
        fitStartSeconds: 0.02, fitEndSeconds: 0.03, fitMethod: .leastSquares)
    let insufficient = try CPPConfiguration(fitStartSeconds: 0.001, fitEndSeconds: 0.0011)
    let outside = try CPPConfiguration(pitchFloorHz: 1, pitchCeilingHz: 2)
    for settings in [narrow, insufficient, outside] {
        let worker = try PreparedCPP(CPPProfile(frame: frame, settings: settings))
        try values.withUnsafeBufferPointer { input in
            try worker.analyzePowerCepstrum(input, context: context) { output in
                if settings == narrow {
                    #expect(abs((output.result.observation?.peakDB ?? 0) - 14) < 1e-10)
                    #expect(
                        abs((output.result.observation?.peakQuefrencySeconds ?? 0) - 0.00804)
                            < 1e-14)
                    #expect(output.result.observation?.peakIsAtSearchBoundary == true)
                } else {
                    #expect(output.result.observation == nil)
                    #expect(
                        output.result.unavailability
                            == (settings == insufficient ? .insufficientData : .unsupportedRange))
                    #expect(output.values(.cepstralDB).isEmpty)
                }
            }
        }
    }
}

@Test func cppOwnedExportsHaveExplicitBudgetsAndLeaveInputUntouched() throws {
    let frame = try PowerCepstrumConfiguration()
    let worker = try PreparedCPP(
        CPPProfile(frame: frame, settings: CPPConfiguration(fitMethod: .leastSquares)))
    let context = try cepstrumContext(count: frame.frameLength, rate: frame.sampleRate)
    let input = (0..<frame.binCount).map { 1 + Double($0 % 7) }
    var saved: [IntermediateSnapshot] = []
    try input.withUnsafeBufferPointer { pointer in
        try worker.analyzePowerCepstrum(pointer, context: context) { output in
            #expect(Array(pointer) == input)
            #expect(throws: ContractError.intermediateBudgetExceeded) {
                try output.export(
                    stages: Set(CPPIntermediate.allCases),
                    policy: IntermediateOutputPolicy(maximumScalarCount: frame.binCount * 3 - 1))
            }
            do {
                saved = try output.export(
                    stages: Set(CPPIntermediate.allCases),
                    policy: IntermediateOutputPolicy(maximumScalarCount: frame.binCount * 3))
            } catch { Issue.record(error) }
        }
    }
    #expect(
        saved.count == 3
            && saved.allSatisfy {
                $0.source == context.timing.source && $0.values.count == frame.binCount
            })
    let before = saved
    try [Double](repeating: 0, count: frame.binCount).withUnsafeBufferPointer {
        try worker.analyzePowerCepstrum($0, context: context) { _ in }
    }
    #expect(saved == before)
}
