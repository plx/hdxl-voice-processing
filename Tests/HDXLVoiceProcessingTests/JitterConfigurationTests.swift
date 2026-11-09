import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func jitterProfilesSeparateApplicabilityAndEveryNumericalSetting() throws {
    let sustained = try JitterConfiguration(sampleRate: 16000)
    let variants = try [
        JitterConfiguration(sampleRate: 48000),
        JitterConfiguration(sampleRate: 16000, inputPrecision: .float32),
        JitterConfiguration(sampleRate: 16000, minimumPeriodSeconds: 0.0002),
        JitterConfiguration(sampleRate: 16000, maximumPeriodSeconds: 0.03),
        JitterConfiguration(sampleRate: 16000, maximumAdjacentPeriodFactor: 1.5),
        JitterConfiguration(
            sampleRate: 16000, applicability: .exploratoryRolling, rollingWindowSampleCount: 16000),
        JitterConfiguration(
            sampleRate: 16000, applicability: .exploratoryRolling, rollingWindowSampleCount: 48000),
    ]
    let identities = try ([sustained] + variants).map { try $0.identity() }
    #expect(Set(identities).count == identities.count)
    #expect(sustained.rollingWindowDurationSeconds == nil)
    #expect(variants[5].rollingWindowDurationSeconds == 1)
    for profile in [sustained] + variants {
        let data = try canonicalContractJSON(profile)
        #expect(try JSONDecoder().decode(JitterConfiguration.self, from: data) == profile)
    }
}

@Test func jitterConfigurationRejectsInvalidRangesAndMislabeledRollingProfiles() throws {
    for rate in [0, 3999, 192001, Int.max] {
        #expect(throws: JitterError.invalidConfiguration) { try JitterConfiguration(sampleRate: rate) }
    }
    for factor in [0.99, 10.01, Double.nan, Double.infinity] {
        #expect(throws: JitterError.invalidConfiguration) {
            try JitterConfiguration(sampleRate: 16000, maximumAdjacentPeriodFactor: factor)
        }
    }
    for floor in [0, -1, 0.02, Double.nan, Double.infinity] {
        #expect(throws: JitterError.invalidConfiguration) {
            try JitterConfiguration(sampleRate: 16000, minimumPeriodSeconds: floor)
        }
    }
    for ceiling in [0, 0.0001, 0.1001, Double.nan, Double.infinity] {
        #expect(throws: JitterError.invalidConfiguration) {
            try JitterConfiguration(sampleRate: 16000, maximumPeriodSeconds: ceiling)
        }
    }
    #expect(throws: JitterError.invalidConfiguration) {
        try JitterConfiguration(sampleRate: 16000, rollingWindowSampleCount: 16000)
    }
    for size in [nil, 0, -1, JitterConfiguration.maximumRollingWindowSampleCount + 1] as [Int?] {
        #expect(throws: JitterError.invalidConfiguration) {
            try JitterConfiguration(
                sampleRate: 16000, applicability: .exploratoryRolling, rollingWindowSampleCount: size)
        }
    }
}

@Test func jitterProfileDecodingRejectsUnknownAndChangedDefinitions() throws {
    let profile = try JitterConfiguration(sampleRate: 16000)
    let data = try canonicalContractJSON(profile)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for (key, value) in [
        ("unknown", 1), ("schemaVersion", 2), ("arithmeticPrecision", "float32"),
        ("definition", "other"), ("denominatorDefinition", "survivorsOnly"),
        ("neighborhoodDefinition", "stitchRejectedPeriods"),
        ("applicability", "exploratoryRolling"), ("rollingWindowSampleCount", 16000),
    ] as [(String, Any)] {
        var changed = object
        changed[key] = value
        let encoded = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(JitterConfiguration.self, from: encoded)
        }
    }
}

@Test func jitterVariantsHaveDistinctUnitsAndNeighborhoodRequirements() {
    #expect(JitterVariant.allCases.count == 5)
    for variant in JitterVariant.allCases {
        #expect(variant.measurementKind.accepts(variant.unit))
        #expect(variant.unit == (variant == .absolute ? .seconds : .fraction))
    }
    #expect(JitterVariant.local.minimumConsecutivePeriodCount == 2)
    #expect(JitterVariant.absolute.minimumConsecutivePeriodCount == 2)
    #expect(JitterVariant.rap.minimumConsecutivePeriodCount == 3)
    #expect(JitterVariant.ddp.minimumConsecutivePeriodCount == 3)
    #expect(JitterVariant.ppq5.minimumConsecutivePeriodCount == 5)
}
