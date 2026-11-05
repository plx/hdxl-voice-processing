import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func cppsRecipeIdentityAndResourceBounds() throws {
    let profile = try CPPSProfile.murtonRecipePraat7(
        sourceSampleRate: 16_000, declaredInputBandwidthHz: 8000)
    let layout = try CPPSLayout(profile: profile)
    #expect(layout.lookaheadFrames == 3)
    #expect(layout.lookaheadSeconds == 0.006)
    #expect(layout.ringFrameCapacity == 7)
    #expect(layout.prominence.firstFitBin == 1)
    #expect(layout.prominence.lastFitBin == 512)
    #expect(
        try JSONDecoder().decode(CPPSProfile.self, from: canonicalContractJSON(profile)) == profile)
    let comparison = CPPSProfile(
        cepstrogram: profile.cepstrogram,
        settings: try CPPSConfiguration(
            quefrencyWindowSeconds: 0.005, prominence: .murtonRecipePraat7()))
    #expect(try comparison.identity() != profile.identity())
    let tolerance = CPPSProfile(
        cepstrogram: profile.cepstrogram,
        settings: try CPPSConfiguration(pitchTolerance: 0.9, prominence: .murtonRecipePraat7()))
    #expect(try tolerance.identity() != profile.identity())
    #expect(throws: CPPSError.invalidConfiguration) {
        try CPPSConfiguration(timeWindowSeconds: .nan, prominence: .murtonRecipePraat7())
    }
    let tinyHop = try CepstrogramConfiguration(
        sourceSampleRate: 10_000, hopSeconds: 0.0001, declaredInputBandwidthHz: 5000)
    #expect(throws: CPPSError.capacityExceeded) {
        try CPPSLayout(
            profile: CPPSProfile(
                cepstrogram: tinyHop,
                settings: CPPSConfiguration(timeWindowSeconds: 1, prominence: .murtonRecipePraat7())
            ))
    }
}
