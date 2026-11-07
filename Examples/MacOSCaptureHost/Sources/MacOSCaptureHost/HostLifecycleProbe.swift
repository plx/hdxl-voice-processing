import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

/// Public coordinator smoke path; the invalidated intent cannot create a native driver.
enum HostLifecycleProbe {
    @MainActor static func run() async throws -> [String] {
        let owner = CaptureLifecycle()
        let intent = try owner.prepareStart()
        owner.stop()
        do {
            _ = try await owner.start(
                intent: intent,
                request: CaptureRequest(
                    channelSelection: .arithmeticMean, processing: .measurement),
                buffering: CaptureBuffering(), workerLimits: CaptureLifecycleWorkerLimits(),
                analysis: { _, _ in throw AnalysisScheduleError.invalidState })
            throw AnalysisScheduleError.unexpectedInput
        } catch let failure as CaptureLifecycleFailure {
            guard failure.reason == .invalidStartIntent else { throw failure }
        }
        let first = await owner.finish()
        let second = await owner.finish()
        guard first == second, first.failures.isEmpty, owner.state == .stopped else {
            throw AnalysisScheduleError.invalidState
        }
        return ["late-lifecycle-intent-rejected", "idempotent-lifecycle-finish"]
    }
}
