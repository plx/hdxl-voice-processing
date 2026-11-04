import Foundation
import HDXLVoiceProcessing
import Testing

struct LevelReferenceFixture: Decodable {
    struct CoefficientSet: Decodable {
        struct Stage: Decodable {
            let b: [Double]
            let a: [Double]
        }
        struct Response: Decodable {
            let frequencyHz: Double
            let magnitude: Double
            let phaseRadians: Double?
            let groupDelaySeconds: Double?
        }
        let sampleRate: Int
        let stages: [Stage]
        let responses: [Response]
    }
    struct Case: Decodable {
        struct Window: Decodable {
            let startSample: Int
            let sampleCount: Int
            let unweightedNormalizedMeanSquare: Double
            let weightedNormalizedMeanSquare: Double
        }
        let name: String
        let sampleRate: Int
        let inputPrecision: AnalysisPrecision
        let input: [Double]
        let inputSHA256: String
        let referenceScale: Double
        let selectedOutputIndices: [Int]
        let normalizedFilteredSamples: [Double]
        let windows: [Window]
    }
    let nativeComparisonBudgets: [String: Double]
    let coefficientSets: [CoefficientSet]
    let cases: [Case]

    static func load() throws -> Self {
        let url = try #require(
            Bundle.module.url(
                forResource: "k-weighting", withExtension: "json", subdirectory: "Fixtures/Levels"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@Test func kWeightingMatchesIndependentCoefficientsAndComplexResponse() throws {
    let fixture = try LevelReferenceFixture.load()
    #expect(fixture.coefficientSets.count == 10)
    #expect(fixture.cases.count == 240)
    var largestCoefficientError = 0.0
    var largestGainError = 0.0
    var largestDelayError = 0.0
    for reference in fixture.coefficientSets {
        let native = try KWeightingCoefficients(sampleRate: reference.sampleRate)
        for (stage, expected) in zip([native.shelf, native.highpass], reference.stages) {
            let values = [stage.b0, stage.b1, stage.b2, 1, stage.a1, stage.a2]
            for (actual, wanted) in zip(values, expected.b + expected.a) {
                let error = abs(actual - wanted)
                largestCoefficientError = max(largestCoefficientError, error)
                #expect(error <= fixture.nativeComparisonBudgets["coefficientAbsolute"]!)
            }
        }
        for expected in reference.responses {
            let actual = try native.response(at: expected.frequencyHz)
            let gainError = abs(actual.magnitude - expected.magnitude)
            largestGainError = max(largestGainError, gainError)
            #expect(gainError <= fixture.nativeComparisonBudgets["responseMagnitudeAbsolute"]!)
            if let phase = expected.phaseRadians, let delay = expected.groupDelaySeconds {
                let phaseDifference = try #require(actual.phaseRadians) - phase
                #expect(
                    abs(atan2(sin(phaseDifference), cos(phaseDifference)))
                        <= fixture.nativeComparisonBudgets["responsePhaseAbsoluteRadians"]!)
                let delayError = abs(try #require(actual.groupDelaySeconds) - delay)
                largestDelayError = max(largestDelayError, delayError)
                #expect(
                    delayError <= fixture.nativeComparisonBudgets[
                        "responseGroupDelayAbsoluteSeconds"]!)
            } else {
                #expect(actual.magnitude == 0)
                #expect(actual.phaseRadians == nil)
                #expect(actual.groupDelaySeconds == nil)
            }
        }
        let nearDC = try native.response(at: 1e-7)
        #expect(nearDC.magnitude > 0)
        #expect(nearDC.groupDelaySeconds?.isFinite == true)
        let nyquist = try native.response(at: Double(reference.sampleRate) / 2)
        #expect(nyquist.magnitude.isFinite && nyquist.magnitude > 1)
        #expect(nyquist.groupDelaySeconds?.isFinite == true)
    }
    print(
        "K reference maximum errors: coefficient=\(largestCoefficientError), gain=\(largestGainError), delaySeconds=\(largestDelayError)"
    )
}

@Test func levelProfilesAreExplicitAndStrictlyDecoded() throws {
    func profile(
        rate: Int = 48_000, input: AnalysisPrecision = .float32,
        window: Int = 19_200, hop: Int = 4800,
        weighting: LevelWeighting = .bs1770Revision5(warmupSampleCount: 4800)
    ) throws -> LevelConfiguration {
        try LevelConfiguration(
            sampleRate: rate, inputPrecision: input, windowLength: window, hopLength: hop,
            accumulation: .compensatedSliding, weighting: weighting)
    }
    let original = try profile()
    #expect(original.arithmeticPrecision == .float64)
    #expect(original.inputPrecision == .float32)
    #expect(original.pcmReference == .unitPeak)
    #expect(original.windowDurationSeconds == 0.4)
    #expect(original.energyUnit == .normalizedSquaredAmplitude)
    #expect(original.logLevelUnit == .decibelsFullScale)
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(LevelConfiguration.self, from: data) == original)
    #expect(try original.identity() != profile(input: .float64).identity())
    #expect(try original.identity() != profile(weighting: .none).identity())
    #expect(
        try original.identity()
            != profile(weighting: .bs1770Revision5(warmupSampleCount: 0)).identity())
    let unweighted = try profile(rate: 4000, weighting: .none)
    #expect(unweighted.kWeighting == nil)
    #expect(
        try JSONDecoder().decode(LevelConfiguration.self, from: JSONEncoder().encode(unweighted))
            == unweighted)
    for rate in [3999, 192_001, Int.max] {
        #expect(throws: ContractError.invalidConfiguration) { try profile(rate: rate) }
    }
    #expect(throws: ContractError.invalidConfiguration) { try profile(rate: 15_999) }
    #expect(throws: ContractError.invalidConfiguration) { try profile(window: 0) }
    #expect(throws: ContractError.invalidConfiguration) { try profile(window: 262_145) }
    #expect(throws: ContractError.invalidConfiguration) { try profile(hop: 0) }
    #expect(throws: ContractError.invalidConfiguration) {
        try profile(weighting: .bs1770Revision5(warmupSampleCount: -1))
    }
    #expect(throws: ContractError.invalidConfiguration) {
        try profile(weighting: .bs1770Revision5(warmupSampleCount: 480_001))
    }
    let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for (key, value) in [
        ("schemaVersion", 2 as Any), ("arithmeticPrecision", "float32" as Any),
        ("pcmReference", "fullScaleSine" as Any), ("channelPolicy", "downmix" as Any),
        ("energyUnit", "decibelsSPL" as Any), ("kWeighting", NSNull() as Any),
        ("extra", true as Any),
    ] {
        var changed = encoded
        changed[key] = value
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                LevelConfiguration.self, from: JSONSerialization.data(withJSONObject: changed))
        }
    }
    var changed = encoded
    changed.removeValue(forKey: "kWeighting")
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            LevelConfiguration.self, from: JSONSerialization.data(withJSONObject: changed))
    }
    let k = try KWeightingCoefficients(sampleRate: 48_000)
    #expect(k.shelf.b0 == 1.53512485958697)
    #expect(k.highpass.b0 == 1 && k.highpass.b1 == -2 && k.highpass.b2 == 1)
    for frequency in [-1.0, .infinity, .nan, 24_001] {
        #expect(throws: ContractError.invalidValue) { try k.response(at: frequency) }
    }
    var coefficientJSON = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(k)) as? [String: Any])
    coefficientJSON["sampleRate"] = 44_100
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            KWeightingCoefficients.self,
            from: JSONSerialization.data(withJSONObject: coefficientJSON))
    }
}
