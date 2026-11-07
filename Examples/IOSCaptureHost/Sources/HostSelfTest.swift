import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

struct HostSelfTestResult: Encodable {
    let schemaVersion = 1
    let status: String
    let checks: [String]
    let evidence =
        "synthetic iOS host execution; no permission request, session activation or microphone capture"
}

/// Runs before any host permission/session logic. The invalidated intent must fail
/// before the adapter queries authorization or constructs its native backend.
enum HostSelfTest {
    @MainActor static func run() async throws -> HostSelfTestResult {
        var checks: [String] = []
        let owner = IOSMicrophoneCapture()
        let intent = owner.prepareStart()
        owner.stop()
        do {
            _ = try await owner.start(
                intent: intent,
                request: CaptureRequest(
                    channelSelection: .arithmeticMean, processing: .measurement),
                buffering: CaptureBuffering(), lease: IOSCaptureHostLease(activity: .unknown))
            throw HostProbeError.failed
        } catch let failure as IOSCaptureFailure {
            guard failure.reason == .invalidStartIntent,
                HostErrorReport.message(for: failure) == "Stopped before capture started."
            else { throw HostProbeError.failed }
        }
        try await owner.finish()
        checks.append("late-start-intent-rejected")
        let privateError = NSError(
            domain: "SYNTHETIC-PRIVATE-ROUTE", code: 29,
            userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC-PRIVATE-DESCRIPTION"])
        guard HostErrorReport.message(for: privateError) == "Operation failed." else {
            throw HostProbeError.failed
        }
        checks.append("private-error-redacted")
        guard
            HostErrorReport.message(for: CaptureIntegrationError.permissionDenied)
                == "Microphone permission was denied. Review access in Settings.",
            HostErrorReport.message(for: CaptureIntegrationError.permissionRestricted)
                == "Microphone access is restricted."
        else { throw HostProbeError.failed }
        checks.append("permission-states-distinct")
        let configuration = try PCMTransferConfiguration(
            format: PCMFormat(sampleRate: 48000, channelCount: 1, layout: .interleaved),
            epoch: StreamEpoch(streamID: UUID()), maximumFramesPerChunk: 4, slotCount: 2)
        let transfer = PCMTransfer(configuration: configuration)
        let samples: [Float] = [0.125, -0.25, 0.5, -1]
        let offered = samples.withUnsafeBytes {
            transfer.offerInterleaved(
                $0, frameCount: 4, sourceStartSample: 0,
                configurationToken: configuration.captureToken)
        }
        guard offered == .accepted(sequence: 0) else { throw HostProbeError.failed }
        var matches = false
        let read = transfer.withNext { event in
            if case .block(let block) = event {
                matches =
                    block.frameCount == 4 && block.sourceStartSample == 0
                    && Array(block.bytes.bindMemory(to: Float.self)) == samples
            }
        }
        guard read == .delivered, matches else { throw HostProbeError.failed }
        checks.append("bounded-pcm-samples-preserved")
        guard
            samples.withUnsafeBytes({
                transfer.offerInterleaved(
                    $0, frameCount: 4, sourceStartSample: 4,
                    configurationToken: configuration.captureToken)
            }) == .accepted(sequence: 1)
        else { throw HostProbeError.failed }
        transfer.close()
        guard try await HostPCMConsumer.drain(transfer) == 4 else { throw HostProbeError.failed }
        checks.append("closed-transfer-drained")
        let gapTransfer = PCMTransfer(configuration: configuration)
        let oversized = samples.withUnsafeBytes {
            gapTransfer.offerInterleaved(
                $0, frameCount: 5, sourceStartSample: 0,
                configurationToken: configuration.captureToken)
        }
        guard oversized == .droppedOversized else { throw HostProbeError.failed }
        gapTransfer.close()
        do {
            _ = try await HostPCMConsumer.drain(gapTransfer)
            throw HostProbeError.failed
        } catch HostProbeError.gap {}
        checks.append("worker-rejects-gap")
        return HostSelfTestResult(status: "passed", checks: checks)
    }
}
