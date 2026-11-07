import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingAudio
@testable import MacOSCaptureHost

@Test func captureRecoveryIdentifiersDoNotEscapeHostDiagnostics() throws {
    let request = try CaptureRequest(channelSelection: .arithmeticMean, processing: .measurement)
    let observation = try CaptureConfigurationObservation(
        epoch: StreamEpoch(streamID: UUID()), request: request,
        effectiveFormat: PCMFormat(sampleRate: 48000, channelCount: 2),
        input: CaptureInputIdentity(
            deviceIdentifier: .observed("SYNTHETIC-PRIVATE-DEVICE-UID"),
            routeIdentifier: .observed("SYNTHETIC-PRIVATE-ROUTE")),
        processing: CaptureProcessingObservation())
    let failure = MacOSCaptureFailure(
        reason: .callback(.formatChanged), request: request,
        observation: observation)
    #expect(HostErrorReport.message(for: failure) == "capture callback failed")
    #expect(
        failure.observation?.input.deviceIdentifier == .observed("SYNTHETIC-PRIVATE-DEVICE-UID"))
}

@Test func systemErrorDomainsAndDescriptionsAreNotRendered() throws {
    let request = try CaptureRequest(channelSelection: .arithmeticMean, processing: .measurement)
    let start = MacOSCaptureFailure(
        reason: .engineStart(domain: "SYNTHETIC-PRIVATE-DOMAIN", code: 28),
        request: request, observation: nil)
    let install = MacOSCaptureFailure(
        reason: .tapInstallation(domain: "SYNTHETIC-PRIVATE-DOMAIN", code: 29),
        request: request, observation: nil)
    #expect(HostErrorReport.message(for: start) == "engine start failed (code 28)")
    #expect(HostErrorReport.message(for: install) == "tap installation failed (code 29)")
    let other = NSError(
        domain: "SYNTHETIC-PRIVATE-DOMAIN", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC-PRIVATE-DESCRIPTION"])
    #expect(HostErrorReport.message(for: other) == "operation failed")
}

@Test @MainActor func publicLifecycleIntentAndFinishSmokeNeedsNoMicrophone() async throws {
    #expect(
        try await HostLifecycleProbe.run() == [
            "late-lifecycle-intent-rejected", "idempotent-lifecycle-finish",
        ])
}
