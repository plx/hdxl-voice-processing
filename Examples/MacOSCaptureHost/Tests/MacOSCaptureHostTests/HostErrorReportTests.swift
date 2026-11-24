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
            "bounded-lifecycle-display-completion", "independent-lifecycle-strict-delivery",
        ])
}

@Test func acceptanceDrainCountsTerminalLossWithoutSavingSamples() async throws {
    let config = try PCMTransferConfiguration(
        format: PCMFormat(sampleRate: 48000, channelCount: 1, layout: .interleaved),
        epoch: StreamEpoch(streamID: UUID()), maximumFramesPerChunk: 4, slotCount: 2)
    let transfer = PCMTransfer(configuration: config)
    let block = [Float](repeating: 0.25, count: 4)
    for start in [0, 4, 8] {
        _ = block.withUnsafeBytes {
            transfer.offerInterleaved(
                $0, frameCount: 4, sourceStartSample: Int64(start),
                configurationToken: config.captureToken)
        }
    }
    transfer.close()
    let counts = try await AcceptanceProbe.drain(transfer)
    #expect(counts.blocks == 2)
    #expect(counts.frames == 8)
    #expect(counts.knownGapFrames == 4)
    #expect(counts.unknownGaps == 0)
    var resources = CaptureResourceHistory()
    resources.observe(transfer)
    resources.observe(transfer)
    resources.observe(transfer, finishing: true)
    let next = try config.epoch.successor()
    #expect(
        CaptureResourceHistory.identifier(next) != CaptureResourceHistory.identifier(config.epoch))
    let readings = resources.readings
    #expect(readings.count == 2)
    #expect(
        readings.allSatisfy {
            $0.epoch == CaptureResourceHistory.identifier(config.epoch) && $0.queueDepthSlots == 0
        })
    #expect(readings.allSatisfy { ($0.residentBytes ?? 0) > 0 && $0.processCPUSeconds != nil })
}
