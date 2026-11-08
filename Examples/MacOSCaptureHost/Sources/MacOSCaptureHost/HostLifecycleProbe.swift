import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

/// Public coordinator smoke path; the invalidated intent cannot create a native driver.
enum HostLifecycleProbe {
    @MainActor static func run() async throws -> [String] {
        let owner = CaptureLifecycle()
        let intent = try owner.prepareStart()
        let display = try owner.subscribeResults(.newest(capacity: 1))
        let strict = try owner.subscribeResults(.failOnOverflow(capacity: 8))
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
        var displayIterator = display.makeAsyncIterator()
        guard let snapshot = try await displayIterator.next(),
            snapshot.value.state == .stopped, snapshot.value.completion == first,
            snapshot.value.configuration == nil, snapshot.statistics.coalesced == 2,
            try await displayIterator.next() == nil
        else { throw AnalysisScheduleError.invalidState }
        var strictCount = 0
        var completions = 0
        for try await receipt in strict {
            strictCount += 1
            if case .completed = receipt.value.event { completions += 1 }
        }
        guard strictCount == 3, completions == 1, strict.statistics.coalesced == 0,
            strict.statistics.rejected == 0, owner.activeResultSubscriberCount == 0
        else { throw AnalysisScheduleError.invalidState }
        return [
            "late-lifecycle-intent-rejected", "idempotent-lifecycle-finish",
            "bounded-lifecycle-display-completion", "independent-lifecycle-strict-delivery",
        ]
    }
}
