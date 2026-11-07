#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Dispatch
    import Foundation
    import HDXLVoiceProcessing
    import Testing
    @testable import HDXLVoiceProcessingAudio

    @MainActor final class LifecycleDriverDouble: CaptureLifecycleDriver {
        var signal: (@MainActor @Sendable (CaptureLifecycleSignal) -> Void)?
        var input: CaptureLifecycleInput?
        var holdStart = false
        var holdFinish = false
        var startGate: CheckedContinuation<Void, Never>?
        var finishGate: CheckedContinuation<Void, Never>?
        var starts = 0
        var stops = 0
        var finishes = 0
        var startFailure: CaptureLifecycleFailure?
        var finishFailure: CaptureLifecycleFailure?
        var encoding = PCMEncoding.float32
        var route = "synthetic-a"
        var channels = 1
        var sampleRate = 8000.0
        init(signal: @escaping @MainActor @Sendable (CaptureLifecycleSignal) -> Void) {
            self.signal = signal
        }
        func start(
            request: CaptureRequest, buffering: CaptureBuffering, epoch: StreamEpoch,
            lease: IOSCaptureHostLease?
        ) async throws -> CaptureLifecycleInput {
            starts += 1
            if let startFailure { throw startFailure }
            let format = try PCMFormat(
                sampleRate: sampleRate, channelCount: channels, encoding: encoding)
            let observation = try CaptureConfigurationObservation(
                epoch: epoch, request: request, effectiveFormat: format,
                input: CaptureInputIdentity(routeIdentifier: .observed(route)),
                processing: CaptureProcessingObservation())
            let value = CaptureLifecycleInput(
                observation: observation, audioSession: nil,
                transfer: PCMTransfer(
                    configuration: try PCMTransferConfiguration(
                        format: format, epoch: epoch,
                        maximumFramesPerChunk: buffering.maximumFramesPerChunk,
                        slotCount: buffering.slotCount)))
            input = value
            if holdStart { await withCheckedContinuation { startGate = $0 } }
            return value  // Deliberately ignores cancellation, like a suspended external operation.
        }
        func stop() {
            stops += 1
            input?.transfer.close()
        }
        func finish() async throws {
            finishes += 1
            if holdFinish { await withCheckedContinuation { finishGate = $0 } }
            defer {
                input = nil
                signal = nil
            }
            if let finishFailure { throw finishFailure }
        }
        func offer(
            _ values: [Float], at start: Int64 = 0, gap: Bool = false,
            hostTime: UInt64? = nil
        ) throws {
            let input = try #require(input)
            let result = values.withUnsafeBytes {
                input.transfer.offerInterleaved(
                    $0, frameCount: UInt32(values.count / channels), sourceStartSample: start,
                    configurationToken: input.transfer.configuration.captureToken,
                    hostStartNanoseconds: hostTime,
                    sourceDiscontinuity: gap)
            }
            if case .accepted = result {
            } else {
                Issue.record("Synthetic offer rejected: \(result)")
            }
        }
    }

    private func lifecycleProfile(
        _ format: PCMFormat, _ channels: PCMChannelSelection, window: Int = 4
    ) throws -> AnalysisScheduleProfile {
        try AnalysisScheduleProfile(
            inputFormat: format, channels: channels,
            levels: LevelConfiguration(
                sampleRate: Int(format.sampleRate),
                inputPrecision: format.encoding == .float32 ? .float32 : .float64,
                windowLength: window, hopLength: window, accumulation: .compensatedSliding,
                weighting: .none))
    }

    @MainActor final class LifecycleHarness {
        var events: [CaptureLifecycleEvent] = []
        var drivers: [LifecycleDriverDouble] = []
        var configureDriver: ((LifecycleDriverDouble) -> Void)?
        var eventHook: ((CaptureLifecycleEvent) -> Void)?
        let workerFactory: @Sendable () -> any CaptureLifecycleWorking
        let diagnosticsMode: RuntimeDiagnosticMode
        init(
            worker: (any CaptureLifecycleWorking)? = nil,
            diagnostics: RuntimeDiagnosticMode = .disabled
        ) {
            diagnosticsMode = diagnostics
            workerFactory = { worker ?? CaptureAnalysisWorker(diagnostics: diagnostics) }
        }
        lazy var lifecycle = CaptureLifecycle(
            makeDriver: { [unowned self] signal in
                let driver = LifecycleDriverDouble(signal: signal)
                configureDriver?(driver)
                drivers.append(driver)
                return driver
            }, makeWorker: workerFactory, diagnostics: diagnosticsMode,
            onEvent: { [unowned self] event in
                events.append(event)
                eventHook?(event)
            })
        func start(window: Int = 4, limits: Int = 256, intent: CaptureLifecycleStartIntent? = nil)
            async throws -> CaptureLifecycleConfiguration
        {
            try await lifecycle.start(
                intent: intent ?? lifecycle.prepareStart(),
                request: CaptureRequest(
                    channelSelection: .arithmeticMean, processing: .measurement),
                buffering: CaptureBuffering(maximumFramesPerChunk: 64, slotCount: 4),
                workerLimits: CaptureLifecycleWorkerLimits(
                    maximumResultEvents: limits, sourceTileCapacity: 4),
                analysis: { try lifecycleProfile($0, $1, window: window) })
        }
        var frames: [PCMTransferScheduledFrame] {
            events.compactMap {
                if case .analysis(.frame(let frame)) = $0 { return frame }
                return nil
            }
        }
        var completions: [CaptureLifecycleCompletion] {
            events.compactMap {
                if case .completed(let report) = $0 { return report }
                return nil
            }
        }
    }

    @MainActor func lifecycleEventually(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Lifecycle condition did not become true")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor @Test(arguments: RuntimeDiagnosticMode.allCases)
    func lifecycleFullRecipeMatchesMemoryAcrossReconfiguration(mode: RuntimeDiagnosticMode)
        async throws
    {
        let h = LifecycleHarness(diagnostics: mode)
        h.configureDriver = { driver in
            driver.sampleRate = 44100
            driver.channels = 2
        }
        var previous: CaptureLifecycleConfiguration?
        var nextIntent = try h.lifecycle.prepareStart()
        for selection in [
            PCMChannelSelection.arithmeticMean, try PCMChannelSelection(channelIndex: 1),
        ] {
            let display = try h.lifecycle.subscribeResults()
            let strict = try h.lifecycle.subscribeResults(.failOnOverflow(capacity: 4096))
            let configuration = try await h.lifecycle.start(
                intent: nextIntent,
                request: CaptureRequest(channelSelection: selection, processing: .measurement),
                buffering: CaptureBuffering(maximumFramesPerChunk: 300, slotCount: 4),
                workerLimits: CaptureLifecycleWorkerLimits(sourceTileCapacity: 128),
                analysis: { format, channels in
                    try AnalysisScheduleProfile(
                        inputFormat: format, channels: channels,
                        levels: LevelConfiguration(
                            sampleRate: 44100, inputPrecision: .float32,
                            windowLength: 800, hopLength: 441,
                            accumulation: .compensatedSliding, weighting: .none),
                        pitch: YINProfile(
                            estimator: YINConfiguration(
                                sampleRate: 44100, inputPrecision: .float32,
                                pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 441)),
                        cpps: CPPSProfile(
                            cepstrogram: CepstrogramConfiguration(
                                sourceSampleRate: 44100, inputPrecision: .float32,
                                hopSeconds: 0.01, declaredInputBandwidthHz: 22050,
                                conditioningMethod: .streamingPreview(lobes: 8, cutoffFraction: 0.9)
                            ),
                            settings: CPPSConfiguration(
                                timeWindowSeconds: 0.02,
                                prominence: CPPConfiguration(fitMethod: .leastSquares))))
                })
            if let previous {
                #expect(configuration.capture.epoch == (try previous.capture.epoch.successor()))
                #expect(configuration.analysisIdentity != previous.analysisIdentity)
            }
            let epoch = configuration.capture.epoch
            let direct = try PreparedAnalysisSchedule<Float>(
                profile: configuration.analysis,
                origin: AnalysisScheduleOrigin(
                    source: SourceInterval(
                        epoch: epoch, startSample: 0, sampleCount: 0, sampleRate: 44100),
                    continuityEpoch: configuration.initialAnalysisContinuityEpoch),
                mode: .continuous, sourceTileCapacity: 128)
            let driver = try #require(h.drivers.last)
            weak let transfer = try #require(driver.input?.transfer)
            var expected: [ScheduledFrame] = []
            for offset in stride(from: 0, to: 9000, by: 300) {
                let input: [Float] = (offset..<(offset + 300)).flatMap { index in
                    let value = Float(0.2 * sin(2 * .pi * 125 * Double(index) / 44100))
                    return [value, value * 0.5]
                }
                _ = try input.withUnsafeBufferPointer {
                    try direct.processInterleaved(
                        $0,
                        interval: SourceInterval(
                            epoch: epoch, startSample: Int64(offset), sampleCount: 300,
                            sampleRate: 44100)
                    ) { expected.append($0) }
                }
                try await lifecycleEventually { (transfer?.snapshot().depth ?? 4) < 4 }
                try driver.offer(input, at: Int64(offset))
            }
            try await lifecycleEventually {
                h.frames.filter { $0.frame.timing.source.epoch == epoch }.count == expected.count
            }
            let actual = h.frames.filter { $0.frame.timing.source.epoch == epoch }
            #expect(actual.map(\.frame) == expected)
            #expect(actual.allSatisfy { $0.channelMap == [0, 1] })
            #expect(expected.contains { if case .levels = $0.value { true } else { false } })
            #expect(expected.contains { if case .pitch = $0.value { true } else { false } })
            #expect(
                expected.contains {
                    if case .cpps(let result) = $0.value {
                        result.observation != nil
                    } else {
                        false
                    }
                })
            #expect(transfer?.snapshot().overflowChunks == 0)
            var displayIterator = display.makeAsyncIterator()
            let displayResult = try #require(await displayIterator.next())
            #expect(displayResult.statistics.coalesced > 0)
            #expect(displayResult.value.configuration == configuration)
            #expect(displayResult.value.runtime.mode == mode)
            if mode == .disabled {
                #expect(displayResult.value.runtime.processing.samples == 0)
            } else {
                #expect(displayResult.value.runtime.processing.samples > 0)
                #expect(displayResult.value.runtime.workerToPublication.samples > 0)
                #expect(
                    displayResult.value.runtime.captureBlockStartToWorker.unavailableSamples > 0)
            }
            #expect(
                displayResult.value.frames.levels == actual.last { $0.frame.algorithm == .levels })
            #expect(displayResult.value.frames.pitch == actual.last { $0.frame.algorithm == .yin })
            #expect(displayResult.value.frames.cpps == actual.last { $0.frame.algorithm == .cpps })
            nextIntent = try await h.lifecycle.prepareReconfiguration()
            var subscribedFrames: [ScheduledFrame] = []
            var subscribedCompletions = 0
            for try await receipt in strict {
                switch receipt.value.event {
                case .analysis(.frame(let frame)): subscribedFrames.append(frame.frame)
                case .completed: subscribedCompletions += 1
                default: break
                }
            }
            #expect(subscribedFrames == expected)
            #expect(subscribedCompletions == 1 && strict.statistics.rejected == 0)
            #expect(transfer == nil && driver.signal == nil)
            #expect(h.completions.last?.failures.isEmpty == true)
            previous = configuration
        }
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func lifecycleConstructionAndLatePermissionHaveNoCaptureEffects() async throws
    {
        let h = LifecycleHarness()
        #expect(h.lifecycle.state == .idle && h.drivers.isEmpty)
        let intent = try h.lifecycle.prepareStart()
        #expect(h.lifecycle.state == .permissionPending && h.drivers.isEmpty)
        h.lifecycle.stop()
        do {
            _ = try await h.start(intent: intent)
            Issue.record("Late permission revived capture")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .invalidStartIntent)
        }
        #expect(h.drivers.isEmpty && h.completions.count == 1)
        let report = await h.lifecycle.finish()
        #expect(report.failures.isEmpty && h.completions.count == 1)
    }

    @MainActor @Test func lifecycleIntentsAreOwnerBoundSingleUseAndConflictsAreExplicit()
        async throws
    {
        let a = LifecycleHarness()
        let b = LifecycleHarness()
        let token = try a.lifecycle.prepareStart()
        do {
            _ = try await b.start(intent: token)
            Issue.record("Foreign intent accepted")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .invalidStartIntent)
        }
        _ = try await a.start(intent: token)
        do {
            _ = try a.lifecycle.prepareStart()
            Issue.record("Running start accepted")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .conflictingOperation)
        }
        _ = await a.lifecycle.finish()
        do {
            _ = try await a.start(intent: token)
            Issue.record("Reused intent accepted")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .invalidStartIntent)
        }
    }

    @MainActor @Test func lifecycleRealPCMUsesFreshEpochAndHistoryAfterReconfiguration()
        async throws
    {
        let h = LifecycleHarness()
        let first = try await h.start()
        try h.drivers[0].offer(Array(repeating: 0.25, count: 8))
        try await lifecycleEventually { h.frames.count == 2 }
        let intent = try await h.lifecycle.prepareReconfiguration()
        let second = try await h.start(window: 8, intent: intent)
        #expect(second.capture.epoch == (try first.capture.epoch.successor()))
        #expect(second.analysisIdentity != first.analysisIdentity)
        try h.drivers[1].offer(Array(repeating: 0.5, count: 8))
        try await lifecycleEventually { h.frames.count == 3 }
        let frame = try #require(h.frames.last?.frame)
        #expect(
            frame.timing.source.epoch == second.capture.epoch
                && frame.timing.source.startSample == 0)
        if case .levels(let level) = frame.value {
            #expect(abs((try #require(level.unweighted.meanSquare.estimate)).value - 0.25) < 1e-12)
        } else {
            Issue.record("Wrong algorithm")
        }
        let boundary = try #require(
            h.events.firstIndex {
                if case .discontinuity = $0 { return true }
                return false
            })
        let newFrame = try #require(
            h.events.firstIndex {
                if case .analysis(.frame(let f)) = $0 {
                    return f.frame.timing.source.epoch == second.capture.epoch
                }
                return false
            })
        #expect(boundary < newFrame)
        _ = await h.lifecycle.finish()
        #expect(
            h.completions.count == 2 && h.drivers.allSatisfy { $0.input == nil && $0.signal == nil }
        )
    }

    @MainActor @Test func lifecycleStopWaitsForDelayedStartupAndConcurrentFinishIsStable()
        async throws
    {
        let h = LifecycleHarness()
        h.configureDriver = { $0.holdStart = true }
        let start = Task { try await h.start() }
        try await lifecycleEventually { h.drivers.first?.startGate != nil }
        weak let transfer = h.drivers[0].input?.transfer
        h.lifecycle.stop()
        let f1 = Task { await h.lifecycle.finish() }
        let f2 = Task { await h.lifecycle.finish() }
        #expect(h.lifecycle.state == .stopping && h.drivers[0].finishes == 0)
        h.drivers[0].startGate?.resume()
        h.drivers[0].startGate = nil
        do {
            _ = try await start.value
            Issue.record("Stopped startup succeeded")
        } catch {}
        let a = await f1.value
        let b = await f2.value
        #expect(a == b && a.failures.isEmpty && h.completions.count == 1)
        #expect(transfer == nil && h.drivers[0].finishes == 1)
    }

    @MainActor @Test func lifecycleStopDuringReconfigurationCannotResume() async throws {
        let h = LifecycleHarness()
        h.configureDriver = { $0.holdFinish = true }
        _ = try await h.start()
        let restarting = Task { try await h.lifecycle.prepareReconfiguration() }
        try await lifecycleEventually { h.drivers[0].finishGate != nil }
        h.lifecycle.stop()
        h.drivers[0].finishGate?.resume()
        h.drivers[0].finishGate = nil
        do {
            _ = try await restarting.value
            Issue.record("Stop lost to reconfiguration")
        } catch let failure as CaptureLifecycleFailure { #expect(failure.reason == .cancelled) }
        #expect(h.lifecycle.state == .stopped && h.drivers.count == 1)
    }

    @MainActor @Test func lifecycleRouteAndMediaEventsRequireFreshHostActionAndRejectOldSignals()
        async throws
    {
        for change in [
            CaptureLifecycleChange.route, .interruption, .mediaServicesLost, .mediaServicesReset,
            .engineConfiguration, .sessionConfiguration, .hostOwnership, .enteredBackground,
        ] {
            let h = LifecycleHarness()
            let first = try await h.start()
            let stale = h.drivers[0].signal
            stale?(.changed(change))
            try await lifecycleEventually { h.lifecycle.state == .interrupted }
            #expect(
                h.drivers.count == 1 && h.completions.count == 1
                    && h.completions[0].change == change)
            let second = try await h.start()
            stale?(.changed(.route))
            let expected = try first.capture.epoch.successor()
            #expect(h.lifecycle.state == .running && second.capture.epoch == expected)
            _ = await h.lifecycle.finish()
        }
    }

    @MainActor @Test func lifecycleRouteDuringStartupDoesNotPublishConfiguration() async throws {
        let h = LifecycleHarness()
        h.configureDriver = { $0.holdStart = true }
        let start = Task { try await h.start() }
        try await lifecycleEventually { h.drivers.first?.startGate != nil }
        h.drivers[0].signal?(.changed(.route))
        h.drivers[0].startGate?.resume()
        h.drivers[0].startGate = nil
        do {
            _ = try await start.value
            Issue.record("Changed startup succeeded")
        } catch {}
        #expect(h.lifecycle.state == .interrupted && h.frames.isEmpty)
        #expect(
            !h.events.contains {
                if case .configured = $0 { return true }
                return false
            })
        #expect(h.completions.count == 1 && h.completions[0].change == .route)
    }

    @MainActor @Test func lifecyclePreparationAndCleanupFailuresRemainTypedAndReleaseResources()
        async throws
    {
        let h = LifecycleHarness()
        h.configureDriver = {
            $0.finishFailure = CaptureLifecycleFailure(stage: .shutdown, reason: .system(code: 42))
        }
        do {
            _ = try await h.lifecycle.start(
                intent: h.lifecycle.prepareStart(),
                request: CaptureRequest(
                    channelSelection: .arithmeticMean, processing: .measurement),
                buffering: CaptureBuffering(), workerLimits: CaptureLifecycleWorkerLimits(),
                analysis: { _, _ in throw AnalysisScheduleError.invalidConfiguration })
            Issue.record("Invalid analysis accepted")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .analysis(.invalidConfiguration))
        }
        #expect(h.lifecycle.state == .failed && h.completions.count == 1)
        #expect(
            h.completions[0].failures.map(\.reason) == [
                .analysis(.invalidConfiguration), .system(code: 42),
            ])
        #expect(h.drivers[0].input == nil && h.drivers[0].signal == nil)
    }

    @MainActor @Test func lifecycleResultCapacityFailsExplicitlyWithoutPublishingPartialBatch()
        async throws
    {
        let h = LifecycleHarness()
        _ = try await h.start(window: 1, limits: 2)
        try h.drivers[0].offer(Array(repeating: 0.2, count: 16))
        try await lifecycleEventually { h.lifecycle.state == .failed }
        #expect(h.frames.isEmpty && h.completions.count == 1)
        #expect(h.completions[0].failures.first?.reason == .resultCapacityExceeded)
    }

    @MainActor @Test func lifecyclePCMGapPrecedesResetAndNewFrames() async throws {
        let h = LifecycleHarness()
        _ = try await h.start()
        try h.drivers[0].offer(Array(repeating: 0.25, count: 8))
        try await lifecycleEventually { h.frames.count == 2 }
        try h.drivers[0].offer(Array(repeating: 0.5, count: 8), at: 16, gap: true)
        try await lifecycleEventually { h.frames.count == 4 }
        let gap = try #require(
            h.events.firstIndex {
                if case .analysis(.gap) = $0 { return true }
                return false
            })
        let reset = try #require(
            h.events.firstIndex {
                if case .analysis(.reset) = $0 { return true }
                return false
            })
        let frame = try #require(
            h.events.firstIndex {
                if case .analysis(.frame(let f)) = $0 {
                    return f.frame.timing.source.startSample == 16
                }
                return false
            })
        #expect(gap < reset && reset < frame)
        #expect(
            h.frames[0].frame.origin.continuityEpoch != h.frames[2].frame.origin.continuityEpoch)
        #expect(h.frames[0].frame.timing.source.epoch == h.frames[2].frame.timing.source.epoch)
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func lifecycleStopFromConfiguredHandlerPreventsWorkerPublication() async throws
    {
        let h = LifecycleHarness()
        h.eventHook = { [unowned h] event in if case .configured = event { h.lifecycle.stop() } }
        do {
            _ = try await h.start()
            Issue.record("Reentrant stop ignored")
        } catch let failure as CaptureLifecycleFailure { #expect(failure.reason == .cancelled) }
        #expect(h.frames.isEmpty && h.lifecycle.state == .stopped && h.completions.count == 1)
    }

    @MainActor @Test func lifecycleCallerCancellationFromPublicationRetiresStartup() async throws {
        for cancelFromRunning in [false, true] {
            let h = LifecycleHarness()
            var starting: Task<CaptureLifecycleConfiguration, any Error>?
            h.eventHook = { event in
                switch event {
                case .configured where !cancelFromRunning: starting?.cancel()
                case .state(.running, _) where cancelFromRunning: starting?.cancel()
                default: break
                }
            }
            starting = Task { try await h.start() }
            do {
                _ = try await starting!.value
                Issue.record("Caller cancellation during publication returned success")
            } catch let failure as CaptureLifecycleFailure {
                #expect(failure.reason == .cancelled)
            }
            #expect(h.lifecycle.state == .stopped && h.completions.count == 1)
            #expect(h.drivers[0].input == nil && h.drivers[0].signal == nil)
            #expect(h.frames.isEmpty)
            _ = await h.lifecycle.finish()
        }
    }

    @MainActor @Test func lifecycleAnalysisIdentityCannotAliasGapRegionAfterRestart() async throws {
        let h = LifecycleHarness()
        let first = try await h.start()
        try h.drivers[0].offer(Array(repeating: 0.25, count: 8))
        try await lifecycleEventually { h.frames.count == 2 }
        try h.drivers[0].offer(Array(repeating: 0.5, count: 8), at: 16, gap: true)
        try await lifecycleEventually { h.frames.count == 4 }
        let old = h.frames[2].frame
        _ = await h.lifecycle.finish()
        let second = try await h.start()
        try h.drivers[1].offer(Array(repeating: 0.5, count: 8))
        try await lifecycleEventually { h.frames.count == 6 }
        let new = h.frames[4].frame
        #expect(new.origin.continuityEpoch == second.initialAnalysisContinuityEpoch)
        #expect(
            first.initialAnalysisContinuityEpoch.streamID
                != second.initialAnalysisContinuityEpoch.streamID)
        #expect(second.capture.epoch == (try first.capture.epoch.successor()))
        #expect(old.origin.continuityEpoch != new.origin.continuityEpoch)
        if case .levels(let before) = old.value, case .levels(let after) = new.value {
            #expect(before.source != after.source)
            #expect(throws: AnalysisScheduleError.unexpectedInput) {
                try new.origin.sourceInterval(for: before.source)
            }
        } else {
            Issue.record("Expected level results")
        }
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func lifecycleCallerTaskCancellationStopsSuspendedStart() async throws {
        let h = LifecycleHarness()
        h.configureDriver = { $0.holdStart = true }
        let start = Task { try await h.start() }
        try await lifecycleEventually { h.drivers.first?.startGate != nil }
        start.cancel()
        try await lifecycleEventually { h.lifecycle.state == .stopping }
        h.drivers[0].startGate?.resume()
        h.drivers[0].startGate = nil
        do {
            _ = try await start.value
            Issue.record("Cancelled caller started capture")
        } catch {}
        #expect(
            h.lifecycle.state == .stopped && h.drivers[0].input == nil && h.completions.count == 1)
    }
    private actor LifecycleWorkerDouble: CaptureLifecycleWorking {
        let inner = CaptureAnalysisWorker()
        var gate: CheckedContinuation<Void, Never>?
        var closed = false
        let failAfterRelease: Bool
        init(failAfterRelease: Bool = false) { self.failAfterRelease = failAfterRelease }
        var waiting: Bool { gate != nil }
        func prepare(
            input: CaptureLifecycleInput, analysis: CaptureLifecycleAnalysis,
            limits: CaptureLifecycleWorkerLimits
        ) async throws -> CaptureLifecycleConfiguration {
            try await inner.prepare(input: input, analysis: analysis, limits: limits)
        }
        func next() async throws -> CaptureLifecycleBatch {
            let batch = try await inner.next()
            if !batch.events.isEmpty {
                await withCheckedContinuation { gate = $0 }
                if failAfterRelease { throw AnalysisScheduleError.invalidInput }
            }
            return batch
        }
        func release() {
            gate?.resume()
            gate = nil
        }
        func close() async {
            closed = true
            await inner.close()
        }
    }

    @MainActor private func lifecycleEventuallyAsync(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("Async lifecycle condition did not become true")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor @Test func lifecycleLateWorkerBatchIsRejectedAndFinishWaitsForWorker() async throws {
        let worker = LifecycleWorkerDouble()
        let h = LifecycleHarness(worker: worker)
        _ = try await h.start()
        try h.drivers[0].offer(Array(repeating: 0.25, count: 8))
        try await lifecycleEventuallyAsync { await worker.waiting }
        h.lifecycle.stop()
        let finish = Task { await h.lifecycle.finish() }
        #expect(h.lifecycle.state == .stopping && h.frames.isEmpty)
        do {
            _ = try h.lifecycle.prepareStart()
            Issue.record("Started before worker retirement")
        } catch let error as CaptureLifecycleFailure {
            #expect(error.reason == .conflictingOperation)
        }
        await worker.release()
        let report = await finish.value
        #expect(report.failures.isEmpty && h.frames.isEmpty)
        #expect(await worker.closed)
    }

    @MainActor @Test func lifecycleDeinitializationRetiresCaptureWorkerAndTransport() async throws {
        let driver = LifecycleDriverDouble(signal: { _ in })
        var lifecycle: CaptureLifecycle? = CaptureLifecycle(makeDriver: { signal in
            driver.signal = signal
            return driver
        })
        weak let owner = lifecycle
        _ = try await lifecycle!.start(
            intent: lifecycle!.prepareStart(),
            request: CaptureRequest(channelSelection: .arithmeticMean, processing: .measurement),
            buffering: CaptureBuffering(maximumFramesPerChunk: 64, slotCount: 4),
            workerLimits: CaptureLifecycleWorkerLimits(sourceTileCapacity: 4),
            analysis: { try lifecycleProfile($0, $1) })
        weak let transfer = driver.input?.transfer
        lifecycle = nil
        #expect(owner == nil)
        try await lifecycleEventually {
            driver.finishes == 1 && driver.input == nil && driver.signal == nil && transfer == nil
        }
    }

    @MainActor @Test func lifecycleRepeatedConcurrentStopsCompleteOncePerOperation() async throws {
        let h = LifecycleHarness()
        var previous: StreamEpoch?
        for _ in 0..<30 {
            let configuration = try await h.start()
            if let previous { #expect(configuration.capture.epoch == (try previous.successor())) }
            previous = configuration.capture.epoch
            let reports = await withTaskGroup(of: CaptureLifecycleCompletion.self) { group in
                for _ in 0..<8 { group.addTask { await h.lifecycle.finish() } }
                var result: [CaptureLifecycleCompletion] = []
                for await value in group { result.append(value) }
                return result
            }
            #expect(
                reports.count == 8 && Set(reports).count == 1
                    && reports.allSatisfy { $0.failures.isEmpty })
        }
        #expect(
            h.completions.count == 30
                && h.drivers.allSatisfy { $0.input == nil && $0.finishes == 1 })
    }

    @MainActor @Test
    func lifecycleFailedPreparationDoesNotSkipPublishedEpochAndCalibrationIsImmutable() async throws
    {
        let h = LifecycleHarness()
        let first = try await h.start()
        let calibration = CaptureCalibrationContext(observation: first.capture)
        _ = await h.lifecycle.finish()
        do {
            _ = try await h.lifecycle.start(
                intent: h.lifecycle.prepareStart(),
                request: CaptureRequest(
                    channelSelection: .arithmeticMean, processing: .measurement),
                buffering: CaptureBuffering(), workerLimits: CaptureLifecycleWorkerLimits(),
                analysis: { _, _ in throw AnalysisScheduleError.invalidConfiguration })
            Issue.record("Preparation should fail")
        } catch {}
        h.configureDriver = { $0.route = "synthetic-b" }
        let recovered = try await h.lifecycle.start(
            intent: h.lifecycle.prepareStart(),
            request: CaptureRequest(channelSelection: .arithmeticMean, processing: .measurement),
            buffering: CaptureBuffering(), workerLimits: CaptureLifecycleWorkerLimits(),
            calibration: calibration, analysis: { try lifecycleProfile($0, $1, window: 8) })
        #expect(recovered.capture.epoch == (try first.capture.epoch.successor()))
        #expect(
            h.events.contains {
                if case .calibrationConfiguration(.incompatible(let changed, _)) = $0 {
                    return changed.contains(.route)
                }
                return false
            })
        #expect(calibration.input.routeIdentifier == .observed("synthetic-a"))
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func lifecycleDoublePrecisionAndExplicitChannelSelectionReachRealWorker()
        async throws
    {
        let h = LifecycleHarness()
        h.configureDriver = {
            $0.encoding = .float64
            $0.channels = 2
        }
        let channel = try PCMChannelSelection(channelIndex: 1)
        let configuration = try await h.lifecycle.start(
            intent: h.lifecycle.prepareStart(),
            request: CaptureRequest(channelSelection: channel, processing: .measurement),
            buffering: CaptureBuffering(maximumFramesPerChunk: 64, slotCount: 4),
            workerLimits: CaptureLifecycleWorkerLimits(sourceTileCapacity: 4),
            analysis: { try lifecycleProfile($0, $1) })
        let input = try #require(h.drivers[0].input)
        let values: [Double] = (0..<8).flatMap { _ in [0.25, 0.75] }
        let offered = values.withUnsafeBytes {
            input.transfer.offerInterleaved(
                $0, frameCount: 8, sourceStartSample: 0,
                configurationToken: input.transfer.configuration.captureToken)
        }
        #expect(offered == .accepted(sequence: 0))
        try await lifecycleEventually { h.frames.count == 2 }
        #expect(
            configuration.analysis.channels == channel
                && configuration.analysis.inputPrecision == .float64)
        for frame in h.frames {
            #expect(frame.channelMap == [0, 1])
            if case .levels(let value) = frame.frame.value {
                #expect(value.unweighted.meanSquare.estimate?.value == 0.5625)
            } else {
                Issue.record("Unexpected algorithm")
            }
        }
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func lifecycleNativeFailureIsTypedAndDoesNotPublishConfiguration() async throws
    {
        let h = LifecycleHarness()
        h.configureDriver = {
            $0.startFailure = CaptureLifecycleFailure(
                stage: .captureStart, reason: .capture(.permissionDenied))
        }
        do {
            _ = try await h.start()
            Issue.record("Denied startup succeeded")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .capture(.permissionDenied))
        }
        #expect(h.lifecycle.state == .failed && h.completions.count == 1)
        #expect(
            h.completions[0].failures.count == 1 && h.drivers[0].input == nil
                && h.drivers[0].signal == nil)
    }

    @MainActor @Test func lifecycleBackgroundInvalidatesPendingIntentAndExplicitStopRemainsVisible()
        async throws
    {
        let h = LifecycleHarness()
        let intent = try h.lifecycle.prepareStart()
        h.lifecycle.enteredBackground()
        #expect(h.lifecycle.state == .interrupted)
        h.lifecycle.stop()
        #expect(h.lifecycle.state == .stopped)
        do {
            _ = try await h.start(intent: intent)
            Issue.record("Background intent revived")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .invalidStartIntent)
        }
        #expect(h.drivers.isEmpty && h.completions.count == 1)
    }

    @MainActor @Test func lifecycleFailedCleanupDoesNotGrantReconfigurationIntent() async throws {
        let h = LifecycleHarness()
        h.configureDriver = {
            $0.finishFailure = CaptureLifecycleFailure(stage: .shutdown, reason: .system(code: 7))
        }
        _ = try await h.start()
        do {
            _ = try await h.lifecycle.prepareReconfiguration()
            Issue.record("Cleanup failure ignored")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .system(code: 7))
        }
        #expect(h.lifecycle.state == .failed && h.drivers.count == 1)
    }
    @MainActor @Test func lifecycleRecoveryIntentCannotOverrideLaterUserStop() async throws {
        let h = LifecycleHarness()
        _ = try await h.start()
        h.drivers[0].signal?(.changed(.interruption))
        try await lifecycleEventually { h.lifecycle.state == .interrupted }
        let recovery = try #require(h.completions.last?.recoveryIntent)
        h.lifecycle.stop()
        do {
            _ = try h.lifecycle.prepareResume(recovery)
            Issue.record("Delayed resumption overrode Stop")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .invalidStartIntent)
        }
        #expect(h.lifecycle.state == .stopped && h.drivers.count == 1)
        _ = try await h.start()  // A new explicit host action is still allowed.
        _ = await h.lifecycle.finish()
    }

    @MainActor @Test func lifecycleRecoveryIntentIsOwnerBoundAndConsumedByResume() async throws {
        let h = LifecycleHarness()
        let other = LifecycleHarness()
        let first = try await h.start()
        h.drivers[0].signal?(.changed(.interruption))
        try await lifecycleEventually { h.lifecycle.state == .interrupted }
        let recovery = try #require(h.completions.last?.recoveryIntent)
        do {
            _ = try other.lifecycle.prepareResume(recovery)
            Issue.record("Foreign recovery accepted")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .invalidStartIntent)
        }
        let intent = try h.lifecycle.prepareResume(recovery)
        let second = try await h.start(intent: intent)
        #expect(second.capture.epoch == (try first.capture.epoch.successor()))
        _ = await h.lifecycle.finish()
        do {
            _ = try h.lifecycle.prepareResume(recovery)
            Issue.record("Recovery token reused")
        } catch let failure as CaptureLifecycleFailure {
            #expect(failure.reason == .invalidStartIntent)
        }
    }

    @MainActor @Test func lifecycleStopDuringInterruptedCleanupRemovesRecoveryPermission()
        async throws
    {
        let h = LifecycleHarness()
        h.configureDriver = { $0.holdFinish = true }
        _ = try await h.start()
        h.drivers[0].signal?(.changed(.interruption))
        try await lifecycleEventually { h.drivers[0].finishGate != nil }
        h.lifecycle.stop()
        h.drivers[0].finishGate?.resume()
        h.drivers[0].finishGate = nil
        let completion = await h.lifecycle.finish()
        #expect(completion.recoveryIntent == nil && h.lifecycle.state == .stopped)
    }
    @MainActor @Test func lifecycleLateWorkerFaultSurvivesExplicitCancellation() async throws {
        let worker = LifecycleWorkerDouble(failAfterRelease: true)
        let h = LifecycleHarness(worker: worker)
        _ = try await h.start()
        try h.drivers[0].offer(Array(repeating: 0.25, count: 8))
        try await lifecycleEventuallyAsync { await worker.waiting }
        h.lifecycle.stop()
        let finish = Task { await h.lifecycle.finish() }
        await worker.release()
        let completion = await finish.value
        #expect(completion.failures.first?.reason == .analysis(.invalidInput))
        #expect(h.lifecycle.state == .failed && h.frames.isEmpty)
    }

    @MainActor @Test func lifecycleRouteChangedWhileStoppedRequestsCalibrationRevalidation()
        async throws
    {
        let h = LifecycleHarness()
        let first = try await h.start()
        _ = await h.lifecycle.finish()
        h.configureDriver = { $0.route = "changed-while-stopped" }
        let second = try await h.start()
        #expect(first.analysisIdentity == second.analysisIdentity)
        #expect(
            h.events.contains {
                if case .calibrationRevalidationRequired(first.capture.epoch, .route) = $0 {
                    return true
                }
                return false
            })
        _ = await h.lifecycle.finish()
    }
    private struct LifecycleResourceTrial: Encodable {
        let encoding: String
        let channels: Int
        let maximumFramesPerChunk: Int
        let slotCount: Int
        let trial: Int
        let sampleRate = 8000
        let sourceTileCapacity = 4
        let maximumResultEvents = 256
        let profileSHA256: String
        let captureStorageBytes: Int
        let initialStartNanoseconds: UInt64
        let interruptionRetirementNanoseconds: UInt64
        let resumeStartNanoseconds: UInt64
        let explicitStopRetirementNanoseconds: UInt64
        let retiredTransfers: Int
        let releasedObservers: Int
        let completedOperations: Int
        let deliveredFrames: Int
        let failures: Int
        let epochAdvance: Int
    }

    @MainActor private func lifecycleOfferConstant(_ driver: LifecycleDriverDouble, frames: Int)
        throws
    {
        let input = try #require(driver.input)
        let result: PCMTransferOfferResult
        if driver.encoding == .float32 {
            result = Array(repeating: Float(0.25), count: frames * driver.channels).withUnsafeBytes
            {
                input.transfer.offerInterleaved(
                    $0, frameCount: UInt32(frames), sourceStartSample: 0,
                    configurationToken: input.transfer.configuration.captureToken)
            }
        } else {
            result = Array(repeating: Double(0.25), count: frames * driver.channels).withUnsafeBytes
            {
                input.transfer.offerInterleaved(
                    $0, frameCount: UInt32(frames), sourceStartSample: 0,
                    configurationToken: input.transfer.configuration.captureToken)
            }
        }
        try #require(result == .accepted(sequence: 0))
    }

    /// Functional assertions are gates; measured durations have no universal threshold.
    /// The release evidence wrapper retains these raw synthetic control/worker trials.
    @MainActor @Test func lifecycleResourceTrials() async throws {
        var trials: [LifecycleResourceTrial] = []
        for encoding in [PCMEncoding.float32, .float64] {
            for channels in [1, 2] {
                for (maximumFrames, slots) in [(64, 4), (8192, 16)] {
                    for trial in 0..<10 {
                        let h = LifecycleHarness()
                        h.configureDriver = {
                            $0.encoding = encoding
                            $0.channels = channels
                        }
                        let buffering = try CaptureBuffering(
                            maximumFramesPerChunk: UInt32(maximumFrames), slotCount: slots)
                        let request = try CaptureRequest(
                            channelSelection: .arithmeticMean, processing: .measurement)
                        let limits = try CaptureLifecycleWorkerLimits(sourceTileCapacity: 4)
                        let started = DispatchTime.now().uptimeNanoseconds
                        let first = try await h.lifecycle.start(
                            intent: h.lifecycle.prepareStart(), request: request,
                            buffering: buffering, workerLimits: limits,
                            analysis: { try lifecycleProfile($0, $1) })
                        let initialStart = DispatchTime.now().uptimeNanoseconds - started
                        weak let oldTransfer = h.drivers[0].input?.transfer
                        let storageBytes = try #require(
                            h.drivers[0].input?.transfer.configuration.pcmStorageBytes)
                        try lifecycleOfferConstant(h.drivers[0], frames: 32)
                        try await lifecycleEventually { h.frames.count == 8 }
                        let interrupted = DispatchTime.now().uptimeNanoseconds
                        h.drivers[0].signal?(.changed(.interruption))
                        try await lifecycleEventually {
                            h.lifecycle.state == .interrupted && oldTransfer == nil
                        }
                        let interruptionRetirement =
                            DispatchTime.now().uptimeNanoseconds - interrupted
                        let recovery = try #require(h.completions.first?.recoveryIntent)
                        let resumed = DispatchTime.now().uptimeNanoseconds
                        let second = try await h.lifecycle.start(
                            intent: h.lifecycle.prepareResume(recovery), request: request,
                            buffering: buffering, workerLimits: limits,
                            analysis: { try lifecycleProfile($0, $1) })
                        let resumeStart = DispatchTime.now().uptimeNanoseconds - resumed
                        weak let newTransfer = h.drivers[1].input?.transfer
                        try lifecycleOfferConstant(h.drivers[1], frames: 32)
                        try await lifecycleEventually { h.frames.count == 16 }
                        let stopped = DispatchTime.now().uptimeNanoseconds
                        let completion = await h.lifecycle.finish()
                        let explicitStopRetirement = DispatchTime.now().uptimeNanoseconds - stopped
                        try #require(oldTransfer == nil && newTransfer == nil)
                        try #require(
                            h.drivers.allSatisfy {
                                $0.signal == nil && $0.input == nil && $0.finishes == 1
                            })
                        try #require(
                            h.completions.count == 2
                                && h.completions.allSatisfy { $0.failures.isEmpty })
                        try #require(completion.recoveryIntent == nil)
                        let expectedEpoch = try first.capture.epoch.successor()
                        try #require(second.capture.epoch == expectedEpoch)
                        try #require(first.analysisIdentity == second.analysisIdentity)
                        for frame in h.frames {
                            guard case .levels(let value) = frame.frame.value else {
                                throw AnalysisScheduleError.unexpectedInput
                            }
                            try #require(value.unweighted.meanSquare.estimate?.value == 0.0625)
                        }
                        trials.append(
                            LifecycleResourceTrial(
                                encoding: encoding.rawValue, channels: channels,
                                maximumFramesPerChunk: maximumFrames, slotCount: slots,
                                trial: trial,
                                profileSHA256: first.analysisIdentity.sha256,
                                captureStorageBytes: storageBytes,
                                initialStartNanoseconds: initialStart,
                                interruptionRetirementNanoseconds: interruptionRetirement,
                                resumeStartNanoseconds: resumeStart,
                                explicitStopRetirementNanoseconds: explicitStopRetirement,
                                retiredTransfers: 2, releasedObservers: 2, completedOperations: 2,
                                deliveredFrames: h.frames.count, failures: 0, epochAdvance: 1))
                    }
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(trials)
        print("LIFECYCLE_RESOURCE_TRIALS " + String(decoding: data, as: UTF8.self))
    }
#endif
