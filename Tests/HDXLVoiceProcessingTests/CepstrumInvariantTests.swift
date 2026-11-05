import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func cepstralHarmonicCombHasExpectedPeriodsNearBothPitchBoundaries() throws {
    for frequency in [60.5, 125.0, 499.0] {
        for missingFundamental in [false, true] {
            let rate = 10_000
            let config = try CepstrogramConfiguration(
                sourceSampleRate: rate, declaredInputBandwidthHz: 5000)
            let source = try SourceInterval(
                epoch: StreamEpoch(streamID: UUID()), startSample: 0,
                sampleCount: 2000, sampleRate: Double(rate))
            let worker = try PreparedIntervalCepstrogram<Double>(
                configuration: config, source: source)
            let highest = min(30, Int(4500 / frequency))
            let samples = (0..<2000).map { i -> Double in
                var sum = 0.0
                for k in (missingFundamental ? 2 : 1)...highest {
                    sum +=
                        0.1 / Double(k)
                        * sin(2 * .pi * frequency * Double(k * i) / Double(rate) + 0.13)
                }
                return sum
            }
            try samples.withUnsafeBufferPointer { try worker.append($0, interval: source) }
            var inspected = 0
            try worker.finish { output in
                guard output.context.frameIndex == 25 else { return }
                inspected += 1
                #expect(output.unavailability == nil)
                let values = output.stage(.powerCepstrum).values
                let expected = Double(rate) / frequency
                let low = Int((expected * 0.85).rounded(.down))
                let high = Int((expected * 1.15).rounded(.up))
                var peak = low
                for k in low...high where values[k] > values[peak] { peak = k }
                #expect(
                    abs(Double(peak) - expected) <= 2,
                    "Period peak for \(frequency) Hz, missing fundamental \(missingFundamental)")
                #expect(values[peak] > values[low] && values[peak] > values[high])
            }
            #expect(inspected == 1)
        }
    }
}

@Test func cepstralUniformBinaryGainChangesOnlyZeroQuefrencySignedOffset() throws {
    let config = try PowerCepstrumConfiguration()
    let worker = try PreparedPowerCepstrum(config)
    var state: UInt32 = 33
    let input = (0..<config.frameLength).map { i -> Double in
        state = 1_664_525 &* state &+ 1_013_904_223
        let noise = (Double(state) - 2_147_483_648) / 42_949_672_960
        return 0.25 * sin(2 * .pi * 125 * Double(i) / 10_000) + noise
    }
    let context = try cepstrumContext(count: input.count, rate: 10_000)
    var baseline: [Double] = []
    try input.withUnsafeBufferPointer {
        try worker.analyze($0, context: context) { output in
            #expect(output.unavailability == nil)
            baseline = Array(output.stage(.signedCepstrum).values)
        }
    }
    for gain in [0.125, 2.0, 8.0] {
        let scaled = input.map { $0 * gain }
        try scaled.withUnsafeBufferPointer {
            try worker.analyze($0, context: context) { output in
                #expect(output.unavailability == nil)
                let actual = output.stage(.signedCepstrum).values
                #expect(abs(actual[0] - baseline[0] - 2 * log(gain) * 10_000) < 1e-7)
                for k in 1..<actual.count { #expect(abs(actual[k] - baseline[k]) < 1e-7) }
            }
        }
    }
}

@Test func cepstralRetentionLimitsAndSerializedStatusCannotContradictValues() throws {
    let config = try CepstrogramConfiguration(
        sourceSampleRate: 10_000, declaredInputBandwidthHz: 5000)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 0,
        sampleCount: 1100, sampleRate: 10_000)
    let worker = try PreparedIntervalCepstrogram<Double>(configuration: config, source: source)
    let collector = try BoundedCepstrogram(
        configuration: config, maximumFrames: 1, maximumScalarCount: 513)
    let emptyBudget = try BoundedCepstrogram(
        configuration: config, maximumFrames: 5, maximumScalarCount: 0)
    let input = (0..<1100).map { sin(Double($0) * 0.137) * 0.25 }
    try input.withUnsafeBufferPointer { try worker.append($0, interval: source) }
    var rejected = 0
    try worker.finish { output in
        if collector.frames.isEmpty {
            do { try collector.append(output) } catch { Issue.record(error) }
        } else {
            #expect(throws: CepstrumError.capacityExceeded) { try collector.append(output) }
            rejected += 1
        }
        #expect(throws: CepstrumError.capacityExceeded) { try emptyBudget.append(output) }
        #expect(emptyBudget.frames.isEmpty && emptyBudget.scalarCount == 0)
    }
    #expect(rejected == 4 && collector.frames.count == 1 && collector.scalarCount == 513)
    let first = try #require(collector.frames.first)
    let original = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    for (field, value) in [
        ("unavailability", "silence" as Any), ("values", [] as Any), ("future", true as Any),
    ] {
        var changed = original
        changed[field] = value
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                PowerCepstrumFrame.self, from: JSONSerialization.data(withJSONObject: changed))
        }
    }
    var changed = original
    var context = try #require(changed["context"] as? [String: Any])
    context["suppliedAnalysisSampleCount"] = 100
    changed["context"] = context
    #expect(throws: ContractError.invalidValue) {
        try JSONDecoder().decode(
            PowerCepstrumFrame.self, from: JSONSerialization.data(withJSONObject: changed))
    }
}
