#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import HDXLVoiceProcessing
    import Testing
    @testable import HDXLVoiceProcessingAudio

    @MainActor @Test(arguments: [false, true])
    func captureDeliveryGapRemainsVisibleAfterDisplayCoalescing(unknownExtent: Bool) async throws {
        let h = LifecycleHarness()
        let configuration = try await h.start()
        let display = try h.lifecycle.subscribeResults()
        let strict = try h.lifecycle.subscribeResults(.failOnOverflow(capacity: 32))
        try h.drivers[0].offer(Array(repeating: 0.25, count: 8))
        try await lifecycleEventually { h.frames.count == 2 }
        try h.drivers[0].offer(Array(repeating: 0.5, count: 8), at: 16, gap: unknownExtent)
        try await lifecycleEventually { h.frames.count == 4 }
        var iterator = display.makeAsyncIterator()
        let receipt = try #require(await iterator.next())
        #expect(receipt.statistics.coalesced > 0 && receipt.statistics.rejected == 0)
        #expect(receipt.value.state == .running)
        #expect(receipt.value.configuration == configuration)
        #expect(receipt.value.frames.levels == h.frames.last)
        #expect(receipt.value.loss.gapEvents == 1)
        #expect(receipt.value.loss.knownMissingFrames == (unknownExtent ? 0 : 8))
        #expect(receipt.value.loss.unknownExtentGaps == (unknownExtent ? 1 : 0))
        #expect(receipt.value.hasReportedAcquisitionLoss)
        #expect(receipt.value.resetCount == 1 && receipt.value.latestReset != nil)
        #expect(receipt.value.frames.levels?.frame.timing == h.frames.last?.frame.timing)
        _ = await h.lifecycle.finish()
        #expect(h.lifecycle.activeResultSubscriberCount == 0)
        let terminal = try #require(await iterator.next())
        #expect(terminal.value.completion?.failures.isEmpty == true)
        #expect(terminal.value.frames == CaptureResultFrames())
        #expect(terminal.value.loss == receipt.value.loss)
        #expect(try await iterator.next() == nil)
        var frames: [PCMTransferScheduledFrame] = []
        var gaps = 0
        var resets = 0
        var completions = 0
        for try await publication in strict {
            switch publication.value.event {
            case .analysis(.frame(let frame)): frames.append(frame)
            case .analysis(.gap): gaps += 1
            case .analysis(.reset): resets += 1
            case .completed: completions += 1
            default: break
            }
        }
        #expect(frames == h.frames && gaps == 1 && resets == 1 && completions == 1)
    }

    @MainActor @Test func captureDeliveryFailedStartupCarriesFinalContextBeforeError() async throws
    {
        let h = LifecycleHarness()
        let failure = CaptureLifecycleFailure(stage: .captureStart, reason: .system(code: 17))
        h.configureDriver = { $0.startFailure = failure }
        let intent = try h.lifecycle.prepareStart()
        let subscription = try h.lifecycle.subscribeResults()
        do {
            _ = try await h.start(intent: intent)
            Issue.record("Failed startup succeeded")
        } catch {}
        var iterator = subscription.makeAsyncIterator()
        let snapshot = try #require(await iterator.next()).value
        #expect(snapshot.state == .failed)
        #expect(snapshot.completion?.failures.count == 1)
        #expect(snapshot.completion?.failures.first?.stage == failure.stage)
        #expect(snapshot.completion?.failures.first?.reason == failure.reason)
        #expect(snapshot.completion?.failures.first?.epoch != nil)
        #expect(snapshot.completion?.failures == h.completions.last?.failures)
        #expect(snapshot.configuration == nil && snapshot.frames == CaptureResultFrames())
        await #expect(throws: ResultDeliveryError.upstreamFailure) { try await iterator.next() }
        #expect(try await iterator.next() == nil)
        #expect(h.lifecycle.activeResultSubscriberCount == 0)
    }

    @MainActor @Test func captureDeliveryUnavailablePitchSurvivesValidLevels() async throws {
        let h = LifecycleHarness()
        let configuration = try await h.lifecycle.start(
            intent: h.lifecycle.prepareStart(),
            request: CaptureRequest(channelSelection: .arithmeticMean, processing: .measurement),
            buffering: CaptureBuffering(maximumFramesPerChunk: 64, slotCount: 4),
            workerLimits: CaptureLifecycleWorkerLimits(sourceTileCapacity: 64),
            analysis: { format, channels in
                try AnalysisScheduleProfile(
                    inputFormat: format, channels: channels,
                    levels: LevelConfiguration(
                        sampleRate: 8000, inputPrecision: .float32, windowLength: 64,
                        hopLength: 64, accumulation: .compensatedSliding, weighting: .none),
                    pitch: YINProfile(
                        estimator: YINConfiguration(
                            sampleRate: 8000, inputPrecision: .float32, pitchFloorHz: 100,
                            pitchCeilingHz: 700, hopLength: 64)))
            })
        for block in 0..<16 {
            try h.drivers[0].offer(Array(repeating: 0, count: 64), at: Int64(block * 64))
            try await lifecycleEventually {
                h.frames.filter { $0.frame.algorithm == .levels }.count == block + 1
            }
        }
        let pitch = try #require(h.frames.last { $0.frame.algorithm == .yin })
        let level = try #require(h.frames.last { $0.frame.algorithm == .levels })
        #expect(try pitch.frame.measurementResult(.fundamentalFrequency).outcome.estimate == nil)
        #expect(try level.frame.measurementResult(.rms).outcome.estimate?.value == 0)
        let delivery = CaptureResultDelivery()
        let display = try delivery.subscribe(.newest(capacity: 1))
        delivery.accept(.configured(configuration))
        delivery.accept(.analysis(.frame(pitch)))
        delivery.accept(.analysis(.frame(level)))
        var iterator = display.makeAsyncIterator()
        let result = try #require(await iterator.next())
        #expect(result.statistics.coalesced == 2)
        #expect(result.value.frames.pitch == pitch && result.value.frames.levels == level)
        display.cancel()
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func captureDeliveryOverflowAndChurnDoNotStopAnalysis() async throws {
        let h = LifecycleHarness()
        _ = try await h.start()
        let strict = try h.lifecycle.subscribeResults(.failOnOverflow(capacity: 1))
        let display = try h.lifecycle.subscribeResults()
        for index in 0..<32 {
            let temporary = try h.lifecycle.subscribeResults()
            try h.drivers[0].offer(Array(repeating: 0.25, count: 4), at: Int64(index * 4))
            try await lifecycleEventually { h.frames.count == index + 1 }
            #expect(temporary.statistics.buffered == 1)
            temporary.cancel()
        }
        #expect(h.lifecycle.state == .running && h.frames.count == 32)
        #expect(strict.statistics.rejected == 1)
        #expect(h.lifecycle.activeResultSubscriberCount == 1)
        #expect(
            h.frames.map { $0.frame.timing.source.startSample } == (0..<32).map { Int64($0 * 4) })
        for frame in h.frames {
            let value = try frame.frame.measurementResult(.rms)
            #expect(value.outcome.estimate?.value == 0.25)
        }
        var iterator = display.makeAsyncIterator()
        let receipt = try #require(await iterator.next())
        #expect(receipt.value.frames.levels == h.frames.last)
        #expect(receipt.value.loss.gapEvents == 0)
        #expect(receipt.statistics.coalesced == 32)
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func captureDeliveryRestartUsesNewSubscriptionsAndFreshState() async throws {
        let h = LifecycleHarness()
        let firstConfiguration = try await h.start()
        let first = try h.lifecycle.subscribeResults()
        try h.drivers[0].offer(Array(repeating: 0.5, count: 4))
        try await lifecycleEventually { h.frames.count == 1 }
        _ = await h.lifecycle.finish()
        let firstAccepted = first.statistics.accepted
        let intent = try h.lifecycle.prepareStart()
        #expect(h.lifecycle.latestResultSnapshot.state == .permissionPending)
        #expect(h.lifecycle.latestResultSnapshot.configuration == nil)
        let second = try h.lifecycle.subscribeResults()
        let secondConfiguration = try await h.start(intent: intent)
        #expect(
            secondConfiguration.capture.epoch == (try firstConfiguration.capture.epoch.successor()))
        var iterator = second.makeAsyncIterator()
        let receipt = try #require(await iterator.next())
        #expect(receipt.value.configuration == secondConfiguration)
        #expect(receipt.value.frames == CaptureResultFrames())
        #expect(receipt.value.loss.gapEvents == 0 && receipt.value.completion == nil)
        #expect(first.statistics.accepted == firstAccepted)
        #expect(first.termination == .finished)
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func captureDeliveryOwnerDisposalTerminatesWaitingSubscription() async throws {
        var owner: CaptureLifecycle? = CaptureLifecycle()
        weak let weakOwner = owner
        let subscription = try #require(owner).subscribeResults()
        owner = nil
        #expect(weakOwner == nil)
        var iterator = subscription.makeAsyncIterator()
        await #expect(throws: ResultDeliveryError.publisherReleased) { try await iterator.next() }
        #expect(try await iterator.next() == nil)
    }

    @MainActor @Test func captureDeliveryCalibrationFaultSurvivesNewLevelResults() async throws {
        let h = LifecycleHarness()
        let configuration = try await h.start()
        try h.drivers[0].offer(Array(repeating: 0.25, count: 4))
        try await lifecycleEventually { h.frames.count == 1 }
        let delivery = CaptureResultDelivery()
        let subscription = try delivery.subscribe(.newest(capacity: 1))
        delivery.accept(.configured(configuration))
        delivery.accept(
            .calibrationConfiguration(.incompatible(changedFields: [.route], unknownFields: [])))
        delivery.accept(.calibrationRevalidationRequired(configuration.capture.epoch, .route))
        delivery.accept(.analysis(.frame(try #require(h.frames.first))))
        var iterator = subscription.makeAsyncIterator()
        let snapshot = try #require(await iterator.next()).value
        #expect(snapshot.calibrationRevalidation == .route)
        #expect(
            snapshot.calibrationComparison
                == .incompatible(changedFields: [.route], unknownFields: []))
        #expect(snapshot.frames.levels == h.frames.first)
        subscription.cancel()
        _ = await h.lifecycle.finish()
    }
#endif
