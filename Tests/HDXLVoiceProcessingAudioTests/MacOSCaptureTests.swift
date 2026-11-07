#if os(macOS)
    import AVFAudio
    import Foundation
    import HDXLVoiceProcessing
    import Testing

    @testable import HDXLVoiceProcessingAudio

    private func nativeCaptureBuffer(
        frames: UInt32, channels: UInt32 = 2, interleaved: Bool = false,
        double: Bool = false, rate: Double = 48000
    ) throws -> AVReadOnlyAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(
                commonFormat: double ? .pcmFormatFloat64 : .pcmFormatFloat32,
                sampleRate: rate, channels: channels, interleaved: interleaved))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        buffer.withUnsafeAudioBufferList { list in
            let values = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            for plane in values.indices {
                let count = Int(frames) * (interleaved ? Int(channels) : 1)
                for index in 0..<count {
                    let channel = interleaved ? index % Int(channels) : plane
                    let frame = interleaved ? index / Int(channels) : index
                    let value = Double(channel + 1) * 0.125 + Double(frame) * 0.001
                    if double {
                        values[plane].mData!.storeBytes(
                            of: value, toByteOffset: index * 8, as: Double.self)
                    } else {
                        values[plane].mData!.storeBytes(
                            of: Float(value), toByteOffset: index * 4, as: Float.self)
                    }
                }
            }
        }
        // Transfer sole ownership; the SDK copying initializer loses data in some formats.
        return AVReadOnlyAudioPCMBuffer(unsafeRetaining: buffer)
    }

    private func captureTime(sample: Int64? = nil, host: UInt64? = nil, rate: Double = 48000)
        -> AVAudioTime
    {
        var timestamp = AudioTimeStamp()
        if let sample {
            timestamp.mSampleTime = Double(sample)
            timestamp.mFlags.insert(.sampleTimeValid)
        }
        if let host {
            timestamp.mHostTime = host
            timestamp.mFlags.insert(.hostTimeValid)
        }
        return AVAudioTime(audioTimeStamp: &timestamp, sampleRate: rate)
    }

    private func captureTransfer(
        double: Bool = false, interleaved: Bool = false,
        maximum: UInt32 = 32, slots: Int = 16
    ) throws -> PCMTransfer {
        PCMTransfer(
            configuration: try PCMTransferConfiguration(
                format: PCMFormat(
                    sampleRate: 48000, channelCount: 2,
                    encoding: double ? .float64 : .float32,
                    layout: interleaved ? .interleaved : .planar),
                epoch: StreamEpoch(streamID: UUID()), maximumFramesPerChunk: maximum,
                slotCount: slots))
    }

    private struct CapturedBlock {
        let start: Int64
        let count: UInt32
        let device: Int64?
        let host: UInt64?
        let samples: [Double]
    }

    private func drainCapture(_ transfer: PCMTransfer) -> (
        blocks: [CapturedBlock], gaps: [PCMTransferGap]
    ) {
        var blocks: [CapturedBlock] = []
        var gaps: [PCMTransferGap] = []
        while transfer.withNext({ event in
            switch event {
            case .gap(let gap): gaps.append(gap)
            case .block(let block):
                let width = transfer.configuration.bytesPerSample
                let samples = stride(from: 0, to: block.bytes.count, by: width).map {
                    width == 8
                        ? block.bytes.loadUnaligned(fromByteOffset: $0, as: Double.self)
                        : Double(block.bytes.loadUnaligned(fromByteOffset: $0, as: Float.self))
                }
                blocks.append(
                    CapturedBlock(
                        start: block.sourceStartSample, count: block.frameCount,
                        device: block.deviceSampleTime, host: block.hostStartNanoseconds,
                        samples: samples))
            }
        }) == .delivered {}
        return (blocks, gaps)
    }

    @Test func macCaptureTapPreservesNativeChannelsAndVariableBuffers() throws {
        for double in [false, true] {
            for interleaved in [false, true] {
                let transfer = try captureTransfer(double: double, interleaved: interleaved)
                let tap = PreparedCaptureTap(transfer: transfer)
                var position: Int64 = -10
                for size: UInt32 in [1, 7, 3, 0, 19] {
                    // The temporary native buffer is released before draining the owned copy.
                    tap.accept(
                        try nativeCaptureBuffer(
                            frames: size, interleaved: interleaved, double: double),
                        at: captureTime(sample: position, host: 123))
                    position += Int64(size)
                }
                #expect(tap.failure == nil)
                let output = drainCapture(transfer)
                #expect(output.gaps.isEmpty)
                #expect(output.blocks.map(\.count) == [1, 7, 3, 19])
                #expect(output.blocks.map(\.start) == [0, 1, 8, 11])
                #expect(output.blocks.map(\.device) == [-10, -9, -2, 1])
                #expect(output.blocks.allSatisfy { $0.host != nil })
                for block in output.blocks {
                    for channel in 0..<2 {
                        for frame in 0..<Int(block.count) {
                            let offset =
                                interleaved
                                ? frame * 2 + channel : channel * Int(block.count) + frame
                            let expected = Double(channel + 1) * 0.125 + Double(frame) * 0.001
                            #expect(
                                block.samples[offset]
                                    == (double ? expected : Double(Float(expected))))
                        }
                    }
                }
            }
        }
    }

    @Test func macCaptureTapUnknownTimingAndClockTransitionsAreExplicit() throws {
        let transfer = try captureTransfer()
        let tap = PreparedCaptureTap(transfer: transfer)
        let buffer = try nativeCaptureBuffer(frames: 3)
        for sample: Int64? in [nil, nil, 100, 110, 90, nil] {
            tap.accept(buffer, at: captureTime(sample: sample))
        }
        let result = drainCapture(transfer)
        #expect(result.blocks.map(\.device) == [nil, nil, 100, 110, 90, nil])
        #expect(result.blocks.map(\.start) == [0, 3, 6, 16, 19, 22])
        #expect(result.blocks.allSatisfy { $0.host == nil })
        #expect(result.gaps.count == 4)
        #expect(result.gaps.allSatisfy { $0.reasons.contains(.sourceDiscontinuity) })
        #expect(result.gaps[1].missingSource?.startSample == 9)
        #expect(result.gaps[1].missingSource?.endSample == 16)
    }

    @Test func macCaptureTapOverflowAndOversizedBuffersRemainVisible() throws {
        let transfer = try captureTransfer(maximum: 4, slots: 2)
        let tap = PreparedCaptureTap(transfer: transfer)
        for (sample, count): (Int64, UInt32) in [(0, 2), (2, 3), (5, 1), (6, 5)] {
            tap.accept(try nativeCaptureBuffer(frames: count), at: captureTime(sample: sample))
        }
        transfer.close()
        let result = drainCapture(transfer)
        #expect(result.blocks.map(\.count) == [2, 3])
        #expect(result.gaps.count == 1)
        #expect(result.gaps[0].reasons == [.capacity, .oversized])
        #expect(result.gaps[0].missingSource?.frameCount == 6)
        #expect(transfer.snapshot().droppedFrames == 6)
        #expect(tap.failure == nil)
    }

    @Test func macCaptureTapFormatChangesFailClosedBeforeCopying() throws {
        let transfer = try captureTransfer()
        let tap = PreparedCaptureTap(transfer: transfer)
        tap.accept(try nativeCaptureBuffer(frames: 3, rate: 44100), at: captureTime())
        #expect(tap.failure == .formatChanged)
        #expect(transfer.snapshot().isClosed)
        #expect(drainCapture(transfer).blocks.isEmpty)
    }

    @Test func macCaptureTapOverlappingAdmissionAndCounterOverflowFailClosed() throws {
        let buffer = try nativeCaptureBuffer(frames: 3)
        let transfer = try captureTransfer()
        let tap = PreparedCaptureTap(transfer: transfer)
        tap.withHeldAdmissionForTesting { tap.accept(buffer, at: captureTime()) }
        #expect(tap.failure == .overlappingCallback)
        #expect(transfer.snapshot().acceptedChunks == 0)
        #expect(transfer.snapshot().isClosed)
        let overflow = try captureTransfer()
        let overflowingTap = PreparedCaptureTap(transfer: overflow, initialSourceSample: .max - 1)
        overflowingTap.accept(buffer, at: captureTime())
        #expect(overflowingTap.failure == .clockOverflow)
        #expect(overflow.snapshot().acceptedChunks == 0)
        #expect(overflow.snapshot().isClosed)
    }

    @MainActor private final class MacAuthorization: MicrophoneAuthorizationProviding {
        var value: MicrophoneAuthorization = .authorized
        var queries = 0
        func microphoneAuthorization() -> MicrophoneAuthorization {
            queries += 1
            return value
        }
    }

    @MainActor private final class MacEngineDouble: MacOSCaptureEngine {
        var operations: [String] = []
        var configurationError: CaptureIntegrationError?
        var installError = false
        var startError = false
        var tap: PreparedCaptureTap?
        var changed: (@MainActor @Sendable () -> Void)?
        func configure(request: CaptureRequest) throws -> MacOSCaptureEngineConfiguration {
            operations.append("configure")
            if let configurationError { throw configurationError }
            return try MacOSCaptureEngineConfiguration(
                format: PCMFormat(sampleRate: 48000, channelCount: 2, layout: .planar),
                input: CaptureInputIdentity(deviceIdentifier: .observed("synthetic-input")),
                processing: CaptureProcessingObservation(engineVoiceProcessing: .observed(false)))
        }
        func observeConfigurationChanges(_ handler: @escaping @MainActor @Sendable () -> Void) {
            operations.append("observe")
            changed = handler
        }
        func installTap(_ tap: PreparedCaptureTap, requestedFrames: UInt32) throws {
            operations.append("install")
            if installError { throw NSError(domain: "SyntheticTap", code: 17) }
            self.tap = tap
        }
        func start() throws {
            operations.append("start")
            if startError { throw NSError(domain: "SyntheticEngine", code: 19) }
        }
        func stop() {
            operations.append("stop")
            tap = nil
            changed = nil
        }
    }

    private func macRequest(channels: PCMChannelSelection = .arithmeticMean) throws
        -> CaptureRequest
    {
        try CaptureRequest(channelSelection: channels, processing: .measurement)
    }

    @Test @MainActor func macCaptureConstructionAndDeniedStartsDoNotConstructEngine() throws {
        let auth = MacAuthorization()
        var constructed = 0
        let capture = MacOSMicrophoneCapture(
            authorization: auth,
            makeEngine: {
                constructed += 1
                return MacEngineDouble()
            })
        #expect(auth.queries == 0)
        #expect(constructed == 0)
        for (value, expected): (MicrophoneAuthorization, CaptureIntegrationError) in [
            (.denied, .permissionDenied), (.restricted, .permissionRestricted),
            (.undetermined, .permissionUndetermined), (.unavailable, .authorizationUnavailable),
        ] {
            auth.value = value
            do {
                try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
                Issue.record("Expected authorization rejection")
            } catch let error as MacOSCaptureFailure {
                #expect(error.reason == .integration(expected))
                #expect(error.observation == nil)
            }
        }
        #expect(constructed == 0)
        #expect(auth.queries == 4)
    }

    @Test @MainActor func macCaptureRepeatedStartStopUsesFreshEpochAndClosesOldStorage() throws {
        let auth = MacAuthorization()
        var engines: [MacEngineDouble] = []
        var events: [String] = []
        let capture = MacOSMicrophoneCapture(
            authorization: auth,
            makeEngine: {
                let engine = MacEngineDouble()
                engines.append(engine)
                return engine
            },
            onEvent: {
                switch $0 {
                case .started: events.append("started")
                case .stopped: events.append("stopped")
                default: events.append("other")
                }
            })
        var epochs: Set<StreamEpoch> = []
        for _ in 0..<10 {
            let session = try capture.start(
                request: macRequest(), buffering: MacOSCaptureBuffering())
            #expect(session.observation.input.deviceIdentifier == .observed("synthetic-input"))
            #expect(session.observation.effectiveFormat.channelCount == 2)
            #expect(epochs.insert(session.observation.epoch).inserted)
            #expect(throws: MacOSCaptureFailure.self) {
                try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
            }
            capture.stop()
            capture.stop()
            #expect(session.transfer.snapshot().isClosed)
            #expect(capture.session == nil)
        }
        #expect(auth.queries == 10)
        #expect(engines.count == 10)
        #expect(events.count == 20)
        #expect(
            engines.allSatisfy {
                $0.operations == ["configure", "observe", "install", "start", "stop"]
            })
    }

    @Test @MainActor func macCaptureFailurePreservesAttemptAndCleansPartialSetup() throws {
        for step in 0..<3 {
            let engine = MacEngineDouble()
            if step == 0 { engine.configurationError = .inputUnavailable }
            if step == 1 { engine.installError = true }
            if step == 2 { engine.startError = true }
            var failures: [MacOSCaptureFailure] = []
            let capture = MacOSMicrophoneCapture(
                authorization: MacAuthorization(), makeEngine: { engine },
                onEvent: { if case .failed(let failure) = $0 { failures.append(failure) } })
            let request = try macRequest()
            do {
                try capture.start(request: request, buffering: MacOSCaptureBuffering())
                Issue.record("Expected failed setup")
            } catch let failure as MacOSCaptureFailure {
                #expect(failure.request == request)
                #expect(failures == [failure])
                switch step {
                case 0: #expect(failure.reason == .integration(.inputUnavailable))
                case 1:
                    #expect(failure.reason == .tapInstallation(domain: "SyntheticTap", code: 17))
                default:
                    #expect(failure.reason == .engineStart(domain: "SyntheticEngine", code: 19))
                }
                #expect((failure.observation != nil) == (step != 0))
            }
            #expect(engine.operations.last == "stop")
            #expect(engine.tap == nil)
            #expect(capture.session == nil)
        }
    }

    @Test @MainActor func macCaptureConfigurationNotificationAndStaleGeneration() throws {
        let engine = MacEngineDouble()
        var changes = 0
        let capture = MacOSMicrophoneCapture(
            authorization: MacAuthorization(), makeEngine: { engine },
            onEvent: { if case .configurationChanged = $0 { changes += 1 } })
        let first = try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
        let oldNotification = try #require(engine.changed)
        oldNotification()
        #expect(first.transfer.snapshot().isClosed)
        #expect(capture.session == nil)
        #expect(changes == 1)
        let second = try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
        oldNotification()
        #expect(capture.session?.observation.epoch == second.observation.epoch)
        #expect(!second.transfer.snapshot().isClosed)
        capture.stop()
    }

    @Test @MainActor func macCaptureCallbackFailureDeliveredOnlyByControlOwner() throws {
        let engine = MacEngineDouble()
        var failures: [MacOSCaptureFailure] = []
        let capture = MacOSMicrophoneCapture(
            authorization: MacAuthorization(), makeEngine: { engine },
            onEvent: { if case .failed(let value) = $0 { failures.append(value) } })
        let session = try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
        engine.tap?.accept(try nativeCaptureBuffer(frames: 2, channels: 1), at: captureTime())
        #expect(failures.isEmpty)
        capture.poll()
        capture.poll()
        #expect(failures.count == 1)
        #expect(failures[0].reason == .callback(.formatChanged))
        #expect(failures[0].observation == session.observation)
        #expect(capture.session == nil)
    }

    @Test @MainActor func macCaptureSessionEnforcesExplicitWorkerChannelPolicy() throws {
        let engine = MacEngineDouble()
        let capture = MacOSMicrophoneCapture(
            authorization: MacAuthorization(), makeEngine: { engine })
        let session = try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
        let level = try LevelConfiguration(
            sampleRate: 48000, inputPrecision: .float32,
            windowLength: 4, hopLength: 4, accumulation: .compensatedSliding, weighting: .none)
        let profile = try AnalysisScheduleProfile(
            inputFormat: session.observation.effectiveFormat,
            channels: .arithmeticMean, levels: level)
        let worker: PreparedPCMTransferSchedule<Float> = try session.makeSchedule(profile: profile)
        engine.tap?.accept(try nativeCaptureBuffer(frames: 8), at: captureTime())
        capture.stop()
        var frameCount = 0
        let result = try worker.drain { if case .frame = $0 { frameCount += 1 } }
        #expect(result.reachedEnd)
        #expect(result.consumedSourceSamples == 8)
        #expect(frameCount == 2)
        let wrong = try AnalysisScheduleProfile(
            inputFormat: profile.inputFormat,
            channels: .init(channelIndex: 0), levels: level)
        #expect(throws: AnalysisScheduleError.invalidConfiguration) {
            let _: PreparedPCMTransferSchedule<Float> = try session.makeSchedule(profile: wrong)
        }
    }

    @Test @MainActor func macCaptureDeinitClosesTransferAndStopsEngine() throws {
        let engine = MacEngineDouble()
        var capture: MacOSMicrophoneCapture? = MacOSMicrophoneCapture(
            authorization: MacAuthorization(), makeEngine: { engine })
        let session = try #require(capture).start(
            request: macRequest(), buffering: MacOSCaptureBuffering())
        capture = nil
        #expect(engine.operations.last == "stop")
        #expect(session.transfer.snapshot().isClosed)
    }

    @Test @MainActor func macCaptureRetainsRetiredTapUntilCallbackReferenceReturns() async throws {
        let engine = MacEngineDouble()
        let capture = MacOSMicrophoneCapture(
            authorization: MacAuthorization(), makeEngine: { engine })
        try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
        // Model an invocation retaining its closure after native tap removal.
        var outstanding = engine.tap
        #expect(outstanding != nil)
        weak let retired = outstanding
        capture.stop()
        try await Task.sleep(for: .milliseconds(25))
        #expect(retired != nil)
        outstanding?.accept(try nativeCaptureBuffer(frames: 3), at: captureTime())
        #expect(outstanding?.transfer.snapshot().acceptedChunks == 0)
        outstanding = nil
        for _ in 0..<100 {
            if retired == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(retired == nil)
    }
    @Test @MainActor func macCaptureStopPreservesFailureBeforePollingTimer() async throws {
        let engine = MacEngineDouble()
        var failures: [MacOSCaptureFailure] = []
        var stopped = false
        let capture = MacOSMicrophoneCapture(
            authorization: MacAuthorization(), makeEngine: { engine },
            onEvent: {
                if case .failed(let failure) = $0 { failures.append(failure) }
                if case .stopped = $0 { stopped = true }
            })
        let session = try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
        engine.tap?.accept(try nativeCaptureBuffer(frames: 3, channels: 1), at: captureTime())
        #expect(session.transfer.withNext { _ in } == .finished)
        #expect(failures.isEmpty)
        capture.stop()  // Models the recording deadline beating the 50 ms control timer.
        #expect(failures.count == 1)
        #expect(!stopped)
        do {
            try await capture.finish()
            Issue.record("A failed capture must not permit a completed recording receipt")
        } catch let failure as MacOSCaptureFailure {
            #expect(failure.reason == .callback(.formatChanged))
            #expect(failure.observation == session.observation)
        }
        #expect(failures.count == 1)
    }

    @Test @MainActor func macCaptureFinishWaitsForLateFaultPublication() async throws {
        let engine = MacEngineDouble()
        var failures: [MacOSCaptureFailure] = []
        let capture = MacOSMicrophoneCapture(
            authorization: MacAuthorization(), makeEngine: { engine },
            onEvent: { if case .failed(let failure) = $0 { failures.append(failure) } })
        let session = try capture.start(request: macRequest(), buffering: MacOSCaptureBuffering())
        var outstanding = engine.tap
        #expect(outstanding != nil)
        capture.stop()
        var completed = false
        let finishing = Task { @MainActor in
            defer { completed = true }
            try await capture.finish()
        }
        try await Task.sleep(for: .milliseconds(25))
        #expect(!completed)
        outstanding?.publishFailureForTesting(.invalidBuffer)
        outstanding = nil
        do {
            try await finishing.value
            Issue.record("A late callback fault must reject success")
        } catch let failure as MacOSCaptureFailure {
            #expect(failure.reason == .callback(.invalidBuffer))
            #expect(failure.observation == session.observation)
        }
        #expect(failures.count == 1)
        #expect(completed)
    }
#endif
