import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func shimmerProfilesIdentifyAllNumericalSettingsAndApplicability() throws {
    let original = try ShimmerConfiguration(sampleRate: 16000)
    let profiles = try [
        original,
        ShimmerConfiguration(sampleRate: 48000),
        ShimmerConfiguration(sampleRate: 16000, inputPrecision: .float32),
        ShimmerConfiguration(sampleRate: 16000, minimumPeriodSeconds: 0.0002),
        ShimmerConfiguration(sampleRate: 16000, maximumPeriodSeconds: 0.03),
        ShimmerConfiguration(sampleRate: 16000, maximumAdjacentPeriodFactor: 1.5),
        ShimmerConfiguration(sampleRate: 16000, maximumAmplitudeFactor: 2),
        ShimmerConfiguration(
            sampleRate: 16000, applicability: .exploratoryRolling, rollingWindowSampleCount: 16000),
        ShimmerConfiguration(
            sampleRate: 16000, applicability: .exploratoryRolling, rollingWindowSampleCount: 48000),
    ]
    #expect(Set(try profiles.map { try $0.identity() }).count == profiles.count)
    #expect(original.rollingWindowDurationSeconds == nil)
    #expect(profiles[7].rollingWindowDurationSeconds == 1)
    for profile in profiles {
        #expect(
            try JSONDecoder().decode(
                ShimmerConfiguration.self, from: canonicalContractJSON(profile)) == profile)
    }
    let object = try #require(
        JSONSerialization.jsonObject(with: canonicalContractJSON(original)) as? [String: Any])
    for (key, value) in [
        ("extra", 1), ("schemaVersion", 2), ("arithmeticPrecision", "float32"),
        ("definition", "other"), ("amplitudeDefinition", "peakToPeak"),
        ("denominatorDefinition", "allValues"), ("neighborhoodDefinition", "reconnectGaps"),
        ("dbDefinition", "dbfsFrames"), ("applicability", "exploratoryRolling"),
        ("rollingWindowSampleCount", 16000),
    ] as [(String, Any)] {
        var changed = object
        changed[key] = value
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                ShimmerConfiguration.self, from: JSONSerialization.data(withJSONObject: changed))
        }
    }
}

@Test func shimmerConfigurationRejectsInvalidSettingsAndMislabeledRollingWindows() throws {
    for rate in [0, 3999, 192001, Int.max] {
        #expect(throws: ShimmerError.invalidConfiguration) {
            try ShimmerConfiguration(sampleRate: rate)
        }
    }
    for factor in [0.99, 10.01, Double.nan, .infinity] {
        #expect(throws: ShimmerError.invalidConfiguration) {
            try ShimmerConfiguration(sampleRate: 16000, maximumAmplitudeFactor: factor)
        }
        #expect(throws: ShimmerError.invalidConfiguration) {
            try ShimmerConfiguration(sampleRate: 16000, maximumAdjacentPeriodFactor: factor)
        }
    }
    for floor in [0, -1, 0.02, Double.nan, .infinity] {
        #expect(throws: ShimmerError.invalidConfiguration) {
            try ShimmerConfiguration(sampleRate: 16000, minimumPeriodSeconds: floor)
        }
    }
    for ceiling in [0, 0.0001, 0.1001, Double.nan, .infinity] {
        #expect(throws: ShimmerError.invalidConfiguration) {
            try ShimmerConfiguration(sampleRate: 16000, maximumPeriodSeconds: ceiling)
        }
    }
    #expect(throws: ShimmerError.invalidConfiguration) {
        try ShimmerConfiguration(sampleRate: 16000, rollingWindowSampleCount: 16000)
    }
    for size in [nil, 0, -1, ShimmerConfiguration.maximumRollingWindowSampleCount + 1] as [Int?] {
        #expect(throws: ShimmerError.invalidConfiguration) {
            try ShimmerConfiguration(
                sampleRate: 16000, applicability: .exploratoryRolling,
                rollingWindowSampleCount: size)
        }
    }
}

@Test func shimmerVariantsDeclareCorrectUnitsAndMinimumNeighborhoods() {
    #expect(ShimmerVariant.allCases.count == 6)
    for variant in ShimmerVariant.allCases {
        #expect(variant.measurementKind.accepts(variant.unit))
        #expect(variant.unit == (variant == .db ? .decibelsRatio : .fraction))
    }
    #expect(ShimmerVariant.local.minimumConsecutiveAmplitudeCount == 2)
    #expect(ShimmerVariant.db.minimumConsecutiveAmplitudeCount == 2)
    #expect(ShimmerVariant.apq3.minimumConsecutiveAmplitudeCount == 3)
    #expect(ShimmerVariant.apq5.minimumConsecutiveAmplitudeCount == 5)
    #expect(ShimmerVariant.apq11.minimumConsecutiveAmplitudeCount == 11)
    #expect(ShimmerVariant.dda.minimumConsecutiveAmplitudeCount == 3)
}
