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
#endif
