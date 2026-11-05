import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func ltsfDefaultGeometryMatchesPinnedReferenceProbe() throws {
    let c = try LTSFConfiguration(sampleRate: 16_000, declaredInputBandwidthHz: 8000)
    let source = try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: 100,
        sampleCount: 16_000, sampleRate: 16_000)
    let layout = try LTSFIntervalLayout(configuration: c, source: source)
    #expect(layout.spectral.frameLength == 318)
    #expect(layout.spectral.fftLength == 1024)
    #expect(layout.spectral.frequencyBinCount == 384)
    #expect(layout.spectral.frequencyStepHz == 15.625)
    #expect(layout.spectral.firstFlatnessBin == 3)
    #expect(layout.spectral.effectiveMinimumFrequencyHz == 46.875)
    #expect(layout.spectral.lastFlatnessBin == 383)
    #expect(layout.spectral.effectiveMaximumFrequencyHz == 5984.375)
    #expect(layout.frameCount == 99)
    #expect(abs(try #require(layout.firstCenterSeconds) - 0.01000000000000002) < 1e-16)
    #expect(layout.unavailability == nil)
    #expect(try layout.firstSampleOffset(frameIndex: 0) == 1)
    #expect(try layout.sourceBoundary(relativeSeconds: 0.2) == 3300)
    #expect(try layout.sourceBoundary(relativeSeconds: 0.7000000000000001) == 11_300)
    #expect(layout.maximumEffectiveDelaySeconds == 1)
}

@Test func ltsfContractsExcludePinnedReferenceAnomaliesAndPreserveIdentity() throws {
    let c = try LTSFConfiguration(sampleRate: 16_000, declaredInputBandwidthHz: 8000)
    let noEnergy = try LTSFConfiguration(
        sampleRate: 16_000, declaredInputBandwidthHz: 8000,
        relativeIntensityThresholdDB: nil)
    #expect(try c.identity() != noEnergy.identity())
    for profile in [c, noEnergy] {
        let bytes = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(LTSFConfiguration.self, from: bytes) == profile)
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json.removeValue(forKey: "relativeIntensityThresholdDB")
        #expect(throws: MaskError.invalidConfiguration) {
            try JSONDecoder().decode(
                LTSFConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let provenance = try profile.provenance()
        #expect(provenance.kind == .spectralFlatnessSpeechActivity)
        #expect(provenance.parameters["hysteresis"] == .text("none-fixed-threshold"))
        #expect(
            provenance.parameters["configurationSHA256"] == .text(try profile.identity().sha256))
    }
    #expect(throws: MaskError.invalidConfiguration) {
        try LTSFConfiguration(
            sampleRate: 16_000, declaredInputBandwidthHz: 8000, minimumFrequencyHz: 1)
    }
    #expect(throws: MaskError.invalidConfiguration) {
        try LTSFConfiguration(sampleRate: 16_000, declaredInputBandwidthHz: 3000)
    }
    #expect(throws: MaskError.invalidConfiguration) {
        try LTSFConfiguration(
            sampleRate: 16_000, declaredInputBandwidthHz: 8000, relativeIntensityThresholdDB: -50)
    }
    for count in [0, 1, 319, 960] {
        let short = try SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: 0,
            sampleCount: Int64(count), sampleRate: 16_000)
        #expect(
            try LTSFIntervalLayout(configuration: c, source: short).unavailability
                == .insufficientData)
    }
    let clipped = try LTSFSpectralGeometry(
        configuration: LTSFConfiguration(sampleRate: 8000, declaredInputBandwidthHz: 4000))
    #expect(clipped.effectiveMaximumFrequencyHz < 4000)
}

@Test func sampledLinearMeanHasAnalyticFractionalAndEndpointWeights() throws {
    // Width five sample steps: integrating seven triangular basis functions
    // yields these weights. A five-point arithmetic average cannot match them.
    let expected = [1.0, 7, 8, 8, 8, 7, 1].map { $0 / 40 }
    for impulse in 0..<7 {
        let mean = sampledLinearMean(
            count: 7, lower: 0.5, upper: 5.5,
            domainLower: -0.5, domainUpper: 6.5
        ) { $0 == impulse ? 1 : 0 }
        #expect(abs(try #require(mean) - expected[impulse]) < 1e-15)
    }
    let triangle = [0.0, 2, 0]
    #expect(
        abs(
            try #require(
                sampledLinearMean(
                    count: 3, lower: -4, upper: 9,
                    domainLower: -0.5, domainUpper: 2.5
                ) { triangle[$0] }) - 2.0 / 3) < 1e-15)
    // No sample centers in this range: mean of the two interpolated endpoints.
    #expect(
        abs(
            try #require(
                sampledLinearMean(
                    count: 3, lower: 0.2, upper: 0.4,
                    domainLower: -0.5, domainUpper: 2.5
                ) { triangle[$0] }) - 0.6) < 1e-15)
    #expect(
        sampledLinearMean(
            count: 1, lower: -3, upper: 3,
            domainLower: -0.5, domainUpper: 0.5
        ) { _ in 7 } == 7)
    let impulse = [1.0, 0, 0]
    #expect(
        sampledLinearMean(
            count: 3, lower: -1, upper: 1,
            domainLower: 0, domainUpper: 2
        ) { impulse[$0] } == 0.5)
    #expect(
        sampledLinearMean(
            count: 3, lower: 4, upper: 5,
            domainLower: 0, domainUpper: 2
        ) { impulse[$0] } == nil)
}
