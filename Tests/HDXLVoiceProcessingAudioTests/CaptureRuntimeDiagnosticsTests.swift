#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Dispatch
    import HDXLVoiceProcessing
    import Testing
    @testable import HDXLVoiceProcessingAudio

    @MainActor @Test func captureRuntimeUsesSeparateSourceProcessingAndPublicationClocks()
        async throws
    {
        let h = LifecycleHarness(diagnostics: .detailed)
        _ = try await h.start()
        let anchor = DispatchTime.now().uptimeNanoseconds
        try h.drivers[0].offer(Array(repeating: 0.25, count: 8), hostTime: anchor)
        try await lifecycleEventually { h.frames.count == 2 }
        let runtime = h.lifecycle.latestResultSnapshot.runtime
        let worker = try #require(runtime.latestWorker)
        let dequeued = try #require(worker.firstBlockDequeuedHostNanoseconds)
        let started = try #require(worker.workerStartedHostNanoseconds)
        let finished = try #require(worker.workerFinishedHostNanoseconds)
        let published = try #require(runtime.latestFirstPublicationHostNanoseconds)
        #expect(
            anchor <= dequeued && started <= dequeued && dequeued <= finished
                && finished <= published)
        #expect(runtime.captureBlockStartToWorker.lastNanoseconds == dequeued - anchor)
        #expect(runtime.processing.lastNanoseconds == finished - started)
        #expect(runtime.workerToPublication.lastNanoseconds == published - finished)
        #expect(worker.consumedSourceFrames == 8 && worker.dequeuedBlocks == 1)
        #expect(worker.emittedResults == 2)
        #expect(runtime.capture?.highWaterSlots == 1 && runtime.capture?.droppedFrames == 0)
        _ = await h.lifecycle.finish()
        #expect(h.lifecycle.latestResultSnapshot.runtime.capture?.isClosed == true)
    }

    @MainActor @Test func captureRuntimeFinalCountersRetainLossBeforeWorkerGapPublication()
        async throws
    {
        let h = LifecycleHarness()
        _ = try await h.start()
        let subscriber = try h.lifecycle.subscribeResults()
        let transfer = try #require(h.drivers[0].input?.transfer)
        let samples = Array(repeating: Float(0.25), count: 4)
        for index in 0..<100 {
            _ = samples.withUnsafeBytes {
                transfer.offerInterleaved(
                    $0, frameCount: 4, sourceStartSample: Int64(index * 4),
                    configurationToken: transfer.configuration.captureToken)
            }
        }
        h.lifecycle.stop()
        _ = await h.lifecycle.finish()
        var iterator = subscriber.makeAsyncIterator()
        let snapshot = try #require(await iterator.next()).value
        #expect(snapshot.runtime.capture?.overflowChunks ?? 0 > 0)
        #expect(snapshot.runtime.capture?.droppedFrames ?? 0 > 0)
        #expect(snapshot.runtime.capture?.isClosed == true)
        #expect(snapshot.hasReportedAcquisitionLoss)
        #expect(snapshot.runtime.mode == .disabled && snapshot.runtime.processing.samples == 0)
        #expect(try await iterator.next() == nil)
    }

    @Test func captureRuntimeRejectsUnknownAndReversedClockDifferences() {
        #expect(CaptureWorkerObservation.difference(nil, 0) == nil)
        #expect(CaptureWorkerObservation.difference(1, nil) == nil)
        #expect(CaptureWorkerObservation.difference(1, 2) == nil)
        #expect(CaptureWorkerObservation.difference(1, 1) == 0)
        #expect(CaptureWorkerObservation.difference(.max, 0) == .max)
    }

    @MainActor @Test func captureRuntimeCancelledSuspendedStartRetainsFinalLoss() async throws {
        let h = LifecycleHarness()
        h.configureDriver = { $0.holdStart = true }
        let subscription = try h.lifecycle.subscribeResults()
        let startup = Task { @MainActor in try await h.start() }
        try await lifecycleEventually { h.drivers.first?.startGate != nil }
        let driver = try #require(h.drivers.first)
        var transfer: PCMTransfer? = try #require(driver.input).transfer
        weak let retiredTransfer = transfer
        let samples = Array(repeating: Float(0.25), count: 4)
        for block in 0..<10 {
            let current = try #require(transfer)
            _ = samples.withUnsafeBytes {
                current.offerInterleaved(
                    $0, frameCount: 4, sourceStartSample: Int64(block * 4),
                    configurationToken: current.configuration.captureToken)
            }
        }
        #expect(transfer?.snapshot().droppedFrames == 24)
        h.lifecycle.stop()
        driver.startGate?.resume()
        driver.startGate = nil
        do {
            _ = try await startup.value
            Issue.record("Cancelled suspended startup succeeded")
        } catch {}
        _ = await h.lifecycle.finish()
        var iterator = subscription.makeAsyncIterator()
        let snapshot = try #require(await iterator.next()).value
        let capture = try #require(snapshot.runtime.capture)
        #expect(capture.isClosed && capture.acceptedChunks == 4 && capture.overflowChunks == 6)
        #expect(capture.droppedFrames == 24 && snapshot.hasReportedAcquisitionLoss)
        #expect(snapshot.configuration == nil && snapshot.frames == CaptureResultFrames())
        #expect(snapshot.loss.gapEvents == 0 && snapshot.runtime.workerTurns == 0)
        #expect(snapshot.completion != nil && snapshot.state == .stopped)
        #expect(try await iterator.next() == nil)
        #expect(h.lifecycle.activeResultSubscriberCount == 0)
        transfer = nil
        #expect(retiredTransfer == nil)
    }
#endif
