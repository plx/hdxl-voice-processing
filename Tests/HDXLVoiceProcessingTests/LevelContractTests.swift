import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func levelResultsRoundTripAndRejectContradictoryMetadata() throws {
    for weighting in [LevelWeighting.none, .bs1770Revision5(warmupSampleCount: 4)] {
        let config = try levelConfiguration(window: 8, hop: 4, weighting: weighting)
        let values = try captureLevels([Double](repeating: 0.25, count: 20), configuration: config)
            .windows
        for value in values {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(LevelWindowResult.self, from: data) == value)
            let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for (key, replacement) in [
                ("schemaVersion", 2 as Any), ("epochOriginSample", -1 as Any),
                ("frameIndex", UInt64.max as Any),
                ("future", true as Any),
                ("unweighted", ["status": "unavailable", "reason": "silence"] as Any),
            ] {
                var changed = original
                changed[key] = replacement
                #expect(throws: (any Error).self) {
                    try JSONDecoder().decode(
                        LevelWindowResult.self,
                        from: JSONSerialization.data(withJSONObject: changed))
                }
            }
            // Limited arithmetic can legitimately coincide with warm-up or a partial window.
            if weighting == .none || value.weighted?.energy != nil {
                var changed = original
                changed["weightedPrecisionLimited"] = true
                #expect(throws: (any Error).self) {
                    try JSONDecoder().decode(
                        LevelWindowResult.self,
                        from: JSONSerialization.data(withJSONObject: changed))
                }
            }
            for key in ["weighted", "weightedTiming", "filterHistorySource", "profile"] {
                var changed = original
                changed.removeValue(forKey: key)
                #expect(throws: (any Error).self) {
                    try JSONDecoder().decode(
                        LevelWindowResult.self,
                        from: JSONSerialization.data(withJSONObject: changed))
                }
            }
            var changed = original
            var timing = try #require(changed["unweightedTiming"] as? [String: Any])
            timing["effectiveDelaySeconds"] = 42
            changed["unweightedTiming"] = timing
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(
                    LevelWindowResult.self, from: JSONSerialization.data(withJSONObject: changed))
            }
            changed = original
            var profile = try #require(changed["profile"] as? [String: Any])
            profile["sha256"] = String(repeating: "0", count: 64)
            changed["profile"] = profile
            #expect(throws: ContractError.invalidFingerprint) {
                try JSONDecoder().decode(
                    LevelWindowResult.self, from: JSONSerialization.data(withJSONObject: changed))
            }
        }
    }
    let diagnostic = try [0.0, -1.0, 2.0].withUnsafeBufferPointer {
        try LevelInputDiagnostics.inspect($0)
    }
    let original = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any])
    for (key, replacement) in [
        ("sampleCount", Int.max as Any), ("finitePeakMagnitude", 0.0 as Any),
        ("overFullScaleSampleCount", 0 as Any), ("nanSampleCount", -1 as Any),
    ] {
        // A very large count alone is valid; pair it with an overflowing nonfinite count sum.
        var changed = original
        changed[key] = replacement
        if key == "sampleCount" {
            changed["nanSampleCount"] = Int.max
            changed["positiveInfinitySampleCount"] = Int.max
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                LevelInputDiagnostics.self, from: JSONSerialization.data(withJSONObject: changed))
        }
    }
}

@Test func levelSharedResultsPreserveUnitsWarningsAndMissingValues() throws {
    let config = try levelConfiguration(window: 4, hop: 4)
    let value = try #require(
        captureLevels([0.0, -1.0, 0.5, 2.0], configuration: config).windows.first)
    #expect(value.input.atFullScaleSampleCount == 1 && value.input.overFullScaleSampleCount == 1)
    for (kind, unit, expected) in [
        (MeasurementKind.peakAmplitude, MeasurementUnit.normalizedAmplitude, 2.0),
        (.meanSquare, .normalizedSquaredAmplitude, 1.3125),
        (.rms, .normalizedAmplitude, sqrt(1.3125)),
        (.levelDBFS, .decibelsFullScale, 10 * log10(1.3125)),
        (.clippingFraction, .fraction, 0.5), (.clippingFraction, .percent, 50),
        (.crestFactor, .dimensionless, 2 / sqrt(1.3125)),
        (.crestFactor, .decibelsRatio, 20 * log10(2 / sqrt(1.3125))),
    ] {
        let scalar = try value.measurementResult(kind: kind, unit: unit)
        #expect(abs(try #require(scalar.outcome.estimate?.value) - expected) < 1e-13)
        #expect(scalar.outcome.estimate?.warnings == [.clipping])
        #expect(scalar.profile == value.profile && scalar.timing.source == value.source)
        #expect(
            try JSONDecoder().decode(MeasurementResult.self, from: JSONEncoder().encode(scalar))
                == scalar)
    }
    #expect(throws: ContractError.invalidUnit) {
        try value.measurementResult(kind: .levelDBFS, unit: .decibelsSPL)
    }
    #expect(throws: ContractError.invalidValue) {
        try value.measurementResult(kind: .calibratedSPL, unit: .decibelsSPL)
    }
    let unweighted = try #require(
        captureLevels(
            [0.0, 0, 0, 0], configuration: levelConfiguration(window: 4, hop: 4, weighting: .none)
        ).windows.first)
    #expect(
        try unweighted.measurementResult(kind: .kWeightedEnergy, unit: .normalizedSquaredAmplitude)
            .outcome == .unavailable(.inapplicableTask))
    #expect(
        try unweighted.measurementResult(kind: .levelDBFS, unit: .decibelsFullScale).outcome
            == .unavailable(.silence))
    let partial = try #require(captureLevels([0.2], configuration: config).windows.first)
    #expect(
        try partial.measurementResult(kind: .rms, unit: .normalizedAmplitude).outcome
            == .unavailable(.insufficientData))
    #expect(
        try partial.measurementResult(kind: .kWeightedEnergy, unit: .normalizedSquaredAmplitude)
            .outcome == .unavailable(.insufficientData))
}
