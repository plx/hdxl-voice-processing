import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func swipePrimeProfileRoundTripAndExplicitSupport() throws {
    let configuration = try SWIPEPrimeConfiguration(sampleRate: 16000, hopLength: 160)
    #expect(configuration.requiredSampleCount == 4096)
    #expect(configuration.algorithmicDelaySeconds == 0.128)
    #expect(configuration.supportDurationSeconds == 0.256)
    #expect(try configuration.framingConfiguration().window.sampleCount == 4096)
    #expect(try configuration.framingConfiguration().hopLength == 160)
    #expect(configuration.definition == "hdxl-swipe-prime-centered-2008")
    #expect(configuration.arithmeticPrecision == .float64)
    #expect(
        try JSONDecoder().decode(
            SWIPEPrimeConfiguration.self, from: canonicalContractJSON(configuration))
            == configuration)
    let different = try SWIPEPrimeConfiguration(sampleRate: 16000, hopLength: 80)
    #expect(try different.identity() != configuration.identity())
    let zero = try SWIPEPrimeConfiguration(
        sampleRate: 16000, hopLength: 160, silenceRMSThreshold: 0)
    let negativeZero = try SWIPEPrimeConfiguration(
        sampleRate: 16000, hopLength: 160, silenceRMSThreshold: -0.0)
    #expect(try zero.identity() == negativeZero.identity())
}

@Test func swipePrimeRejectsUnsupportedGeometryAndUnknownConventions() throws {
    for rate in [0, 3999, 192001] {
        #expect(throws: SWIPEPrimeError.invalidConfiguration) {
            try SWIPEPrimeConfiguration(sampleRate: rate, hopLength: 1)
        }
    }
    for floor in [Double.nan, .infinity, -1, 19, 700] {
        #expect(throws: SWIPEPrimeError.invalidConfiguration) {
            try SWIPEPrimeConfiguration(sampleRate: 16000, pitchFloorHz: floor, hopLength: 160)
        }
    }
    #expect(throws: SWIPEPrimeError.invalidConfiguration) {
        try SWIPEPrimeConfiguration(
            sampleRate: 16000, pitchFloorHz: 100, pitchCeilingHz: 100.01, hopLength: 1)
    }
    #expect(throws: SWIPEPrimeError.invalidConfiguration) {
        try SWIPEPrimeConfiguration(sampleRate: 16000, pitchCeilingHz: 4001, hopLength: 1)
    }
    for hop in [0, 4097] {
        #expect(throws: SWIPEPrimeError.invalidConfiguration) {
            try SWIPEPrimeConfiguration(sampleRate: 16000, hopLength: hop)
        }
    }
    for resolution in [11, 193] {
        #expect(throws: SWIPEPrimeError.invalidConfiguration) {
            try SWIPEPrimeConfiguration(
                sampleRate: 16000, hopLength: 160, candidatesPerOctave: resolution)
        }
    }
    for threshold in [Double.nan, .infinity, 0, 1] {
        #expect(throws: SWIPEPrimeError.invalidConfiguration) {
            try SWIPEPrimeConfiguration(
                sampleRate: 16000, hopLength: 160, strengthThreshold: threshold)
        }
    }
    let configuration = try SWIPEPrimeConfiguration(sampleRate: 16000, hopLength: 160)
    let object = try #require(
        JSONSerialization.jsonObject(with: canonicalContractJSON(configuration)) as? [String: Any])
    for key in object.keys {
        var missing = object
        missing.removeValue(forKey: key)
        let data = try JSONSerialization.data(withJSONObject: missing)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SWIPEPrimeConfiguration.self, from: data)
        }
    }
    for (key, value) in [
        ("arithmeticPrecision", "float32"), ("definition", "plain-swipe"),
        ("spectrumInterpolation", "linearPower"), ("normalization", "fullKernelNorm"),
        ("supportPolicy", "zeroPadBoundaries"), ("unknown", "field"),
    ] {
        var changed = object
        changed[key] = value
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SWIPEPrimeConfiguration.self, from: data)
        }
    }
}

@Test func swipePrimeWindowBoundaryAndGridEndpointsAreExplicit() throws {
    let exact = try SWIPEPrimeConfiguration(
        sampleRate: 16000, pitchFloorHz: 250, pitchCeilingHz: 500, hopLength: 160,
        candidatesPerOctave: 12)
    let layout = SWIPEPrimeLayout(configuration: exact)
    #expect(layout.requiredSampleCount == 512)
    #expect(layout.windowLengths == [256, 512])
    #expect(layout.candidateFrequenciesHz.count == 13)
    #expect(layout.candidateFrequenciesHz.first == 250 && layout.candidateFrequenciesHz.last == 500)
    #expect(layout.candidateWindows[0].lowerLength == 512)
    #expect(layout.candidateWindows[0].upperLength == 1024)
    #expect(layout.candidateWindows[0].upperWeight == 0)
    let below = try SWIPEPrimeConfiguration(
        sampleRate: 16000, pitchFloorHz: 249.999, pitchCeilingHz: 500, hopLength: 160)
    #expect(below.requiredSampleCount == 1024)
    #expect(SWIPEPrimeLayout(configuration: below).windowLengths.last == 1024)
    for ceiling in [500 * (1 - 2e-13), 500, 500 * (1 + 2e-13)] {
        let c = try SWIPEPrimeConfiguration(
            sampleRate: 16000, pitchFloorHz: 250, pitchCeilingHz: ceiling, hopLength: 160,
            candidatesPerOctave: 12)
        let grid = SWIPEPrimeLayout(configuration: c).candidateFrequenciesHz
        #expect(grid.count == 13 && grid.first == 250 && grid.last == ceiling)
        #expect(zip(grid, grid.dropFirst()).allSatisfy { $0 < $1 })
    }
}

@Test func swipePrimeMaximumGeometryStaysBounded() throws {
    let c = try SWIPEPrimeConfiguration(
        sampleRate: 192000, pitchFloorHz: 20, pitchCeilingHz: 48000,
        hopLength: 131072, candidatesPerOctave: 192)
    let layout = SWIPEPrimeLayout(configuration: c)
    #expect(c.requiredSampleCount == 131072)
    #expect(layout.windowLengths.first == 32 && layout.windowLengths.last == 131072)
    #expect(layout.candidateFrequenciesHz.count <= 2304)
    #expect(layout.erbFrequenciesHz.count < 600)
    #expect(layout.erbFrequenciesHz.first == 0)
    #expect(try #require(layout.erbFrequenciesHz.last) <= 96000)
    #expect(layout.windowLengths.allSatisfy { $0.nonzeroBitCount == 1 })
}

@Test func swipePrimeProfilesAndGeometryMatchIndependentFixtures() throws {
    struct Fixture: Decodable {
        struct Geometry: Decodable {
            struct Mixture: Decodable {
                let lowerLength, upperLength: Int
                let upperWeight: Double
            }
            let candidateFrequenciesHz, erbFrequenciesHz: [Double]
            let windowLengths: [Int]
            let requiredSampleCount: Int
            let candidateWindows: [Mixture]
        }
        let profile: SWIPEPrimeConfiguration
        let profileSHA256: String
        let geometry: Geometry
    }
    let directory = try #require(
        Bundle.module.url(forResource: "SWIPE", withExtension: nil, subdirectory: "Fixtures"))
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
    #expect(files.count == 74)
    for file in files {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        let actual = SWIPEPrimeLayout(configuration: fixture.profile)
        let expected = fixture.geometry
        #expect(try fixture.profile.identity().sha256 == fixture.profileSHA256)
        #expect(actual.requiredSampleCount == expected.requiredSampleCount)
        #expect(actual.windowLengths == expected.windowLengths)
        #expect(actual.candidateFrequenciesHz.count == expected.candidateFrequenciesHz.count)
        #expect(actual.erbFrequenciesHz.count == expected.erbFrequenciesHz.count)
        #expect(actual.candidateWindows.count == expected.candidateWindows.count)
        for (a, b) in zip(actual.candidateFrequenciesHz, expected.candidateFrequenciesHz) {
            #expect(abs(a - b) <= 2e-12 * max(1, abs(b)))
        }
        for (a, b) in zip(actual.erbFrequenciesHz, expected.erbFrequenciesHz) {
            #expect(abs(a - b) <= 2e-12 * max(1, abs(b)))
        }
        for (a, b) in zip(actual.candidateWindows, expected.candidateWindows) {
            #expect(a.lowerLength == b.lowerLength && a.upperLength == b.upperLength)
            #expect(abs(a.upperWeight - b.upperWeight) <= 2e-14)
        }
    }
}
