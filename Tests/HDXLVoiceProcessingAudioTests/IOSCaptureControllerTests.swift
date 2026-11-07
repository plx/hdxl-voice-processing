#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Foundation
    import HDXLVoiceProcessing
    import Testing
    @testable import HDXLVoiceProcessingAudio

    @MainActor private final class IOSAuthorizationDouble: MicrophoneAuthorizationProviding {
        var status: MicrophoneAuthorization = .authorized
        var queries = 0
        func microphoneAuthorization() -> MicrophoneAuthorization {
            queries += 1
            return status
        }
    }

    @MainActor private final class IOSBackendDouble: IOSCaptureBackend {
        var calls: [String] = []
        var handler: (@MainActor @Sendable (IOSCaptureBackendEvent) -> Void)?
        var installed: PreparedCaptureTap?
        var retainedCallback: PreparedCaptureTap?
        var configurationStillMatches = true
        var sessionIsKnownInactive = false
        var suspendActivation = false
        var activation: CheckedContinuation<Bool, any Error>?
        var activationSucceeds = true
        var suspendDeactivation = false
        var deactivation: CheckedContinuation<Bool, Never>?
        var deactivateSucceeds = true
        var route = "route-a"

        func configureInactiveSession(request: CaptureRequest) throws { calls.append("configure") }
        func activate() async throws -> Bool {
            calls.append("activate")
            if suspendActivation {
                return try await withCheckedThrowingContinuation { activation = $0 }
            }
            return activationSucceeds
        }
        func prepareEngine(request: CaptureRequest) throws -> IOSCaptureEngineConfiguration {
            calls.append("prepare")
            return try IOSCaptureEngineConfiguration(
                format: PCMFormat(sampleRate: 48000, channelCount: 2),
                input: CaptureInputIdentity(
                    deviceIdentifier: .observed("input-a"), routeIdentifier: .observed(route)),
                processing: CaptureProcessingObservation(
                    sessionMode: .observed("measurement"),
                    engineVoiceProcessing: .observed(false)),
                audioSession: IOSAudioSessionObservation(
                    category: "record", mode: "measurement", categoryOptions: 0,
                    sampleRate: 48000, ioBufferDuration: 0.01))
        }
        func observe(_ handler: @escaping @MainActor @Sendable (IOSCaptureBackendEvent) -> Void) {
            calls.append("observe")
            self.handler = handler
        }
        func stopObserving() {
            calls.append("unobserve")
            handler = nil
        }
        func installTap(_ tap: PreparedCaptureTap, requestedFrames: UInt32) throws {
            calls.append("install")
            installed = tap
        }
        func startEngine() throws { calls.append("start") }
        func stopEngine() {
            calls.append("stop")
            installed = nil
        }
        func deactivate() async throws -> Bool {
            calls.append("deactivate")
            if suspendDeactivation {
                return await withCheckedContinuation { deactivation = $0 }
            }
            return deactivateSucceeds
        }
    }

    @MainActor private final class IOSCaptureHarness {
        let authorization = IOSAuthorizationDouble()
        let native = IOSBackendDouble()
        var events: [IOSCaptureEvent] = []
        var factories = 0
        var eventHook: ((IOSCaptureEvent) -> Void)?
        lazy var controller = IOSCaptureController(
            authorization: authorization,
            makeBackend: { [unowned self] in
                factories += 1
                return native
            },
            onEvent: { [unowned self] in
                events.append($0)
                eventHook?($0)
            })

        func start(
            ownership: CaptureSessionOwnership = .hostManaged,
            activity: IOSCaptureHostActivity = .active,
            lease: IOSCaptureHostLease? = nil, calibration: CaptureCalibrationContext? = nil
        ) async throws -> IOSCaptureSession {
            try await controller.start(
                intent: controller.prepareStart(), request: iosRequest(ownership),
                buffering: CaptureBuffering(maximumFramesPerChunk: 16, slotCount: 4),
                lease: lease ?? IOSCaptureHostLease(activity: activity), calibration: calibration)
        }
    }

    private func iosRequest(_ ownership: CaptureSessionOwnership = .hostManaged) throws
        -> CaptureRequest
    {
        try CaptureRequest(
            preferredFormat: PCMFormat(sampleRate: 44100, channelCount: 2),
            channelSelection: .arithmeticMean, processing: .measurement, sessionOwnership: ownership
        )
    }
    private func delegated(_ deactivate: Bool = true) -> CaptureSessionOwnership {
        .delegated(
            CaptureSessionDelegation(permitsActivation: true, permitsDeactivation: deactivate))
    }
    @MainActor private func failureReason(_ body: () async throws -> Void) async
        -> IOSCaptureFailureReason?
    {
        do {
            try await body()
            Issue.record("Expected capture failure")
            return nil
        } catch let error as IOSCaptureFailure { return error.reason } catch {
            Issue.record("Unexpected error type")
            return nil
        }
    }
    @MainActor private func awaitActivation(_ native: IOSBackendDouble) async throws {
        for _ in 0..<1000 {
            if native.activation != nil { return }
            await Task.yield()
        }
        _ = try #require(native.activation)
    }

    @Test @MainActor func iosCaptureLateAuthorizationIntentCannotReviveStoppedOwner() async throws {
        let h = IOSCaptureHarness()
        let intent = h.controller.prepareStart()
        #expect(h.authorization.queries == 0 && h.factories == 0)
        h.controller.stop()
        #expect(
            await failureReason {
                _ = try await h.controller.start(
                    intent: intent, request: iosRequest(), buffering: CaptureBuffering(),
                    lease: IOSCaptureHostLease(activity: .active), calibration: nil)
            } == .invalidStartIntent)
        #expect(h.authorization.queries == 0 && h.factories == 0)
    }

    @Test @MainActor func iosCaptureHostManagedPreservesSessionAndStartsFreshEpochs() async throws {
        let h = IOSCaptureHarness()
        let first = try await h.start()
        #expect(first.observation.capture.request.preferredFormat?.sampleRate == 44100)
        #expect(first.observation.capture.effectiveFormat.sampleRate == 48000)
        try await h.controller.finish()
        let second = try await h.start()
        #expect(
            second.observation.capture.epoch == (try first.observation.capture.epoch.successor()))
        try await h.controller.finish()
        #expect(!h.native.calls.contains("configure"))
        #expect(!h.native.calls.contains("activate"))
        #expect(!h.native.calls.contains("deactivate"))
        let boundaries = h.events.compactMap { event -> SourceDiscontinuity? in
            if case .stopped(_, let boundary) = event { return boundary }
            return nil
        }
        #expect(boundaries.count == 2)
        #expect(boundaries.first?.missingSource == nil)
        #expect(boundaries.first?.nextEpoch == second.observation.capture.epoch)
    }

    @Test @MainActor func iosCapturePermissionAndActivityFailuresHaveNoSessionSideEffects()
        async throws
    {
        let denied = IOSCaptureHarness()
        denied.authorization.status = .denied
        #expect(
            await failureReason { _ = try await denied.start() } == .integration(.permissionDenied))
        #expect(denied.factories == 0)
        let inactive = IOSCaptureHarness()
        #expect(
            await failureReason { _ = try await inactive.start(activity: .inactive) }
                == .integration(.configurationConflict(.inactiveSession)))
        #expect(inactive.factories == 0)
        let unknown = IOSCaptureHarness()
        #expect(
            await failureReason { _ = try await unknown.start(activity: .unknown) }
                == .unknownSessionActivity)
        #expect(unknown.factories == 0)
    }

    @Test @MainActor func iosCaptureDeactivationRequiresGrantAndItsOwnActivation() async throws {
        for (activity, permitsDeactivation, expected) in [
            (IOSCaptureHostActivity.active, true, false), (.inactive, false, false),
            (.inactive, true, true),
        ] {
            let h = IOSCaptureHarness()
            _ = try await h.start(ownership: delegated(permitsDeactivation), activity: activity)
            try await h.controller.finish()
            #expect(h.native.calls.contains("activate") == (activity == .inactive))
            #expect(h.native.calls.contains("configure") == (activity == .inactive))
            #expect(h.native.calls.contains("deactivate") == expected)
        }
    }

    @Test @MainActor func iosCaptureStopDuringActivationWaitsAndNeverStartsEngine() async throws {
        let h = IOSCaptureHarness()
        h.native.suspendActivation = true
        let operation = Task { try await h.start(ownership: delegated(), activity: .inactive) }
        try await awaitActivation(h.native)
        h.controller.stop()
        h.native.activation?.resume(returning: true)
        h.native.activation = nil
        #expect(await failureReason { _ = try await operation.value } == .cancelled)
        #expect(await failureReason { try await h.controller.finish() } == .cancelled)
        #expect(!h.native.calls.contains("prepare") && !h.native.calls.contains("start"))
        #expect(h.native.calls.filter { $0 == "deactivate" }.count == 1)
    }

    @Test @MainActor func iosCaptureInvalidatedLeaseCannotDeactivateHostAfterLateActivation()
        async throws
    {
        let h = IOSCaptureHarness()
        h.native.suspendActivation = true
        let lease = IOSCaptureHostLease(activity: .inactive)
        let operation = Task { try await h.start(ownership: delegated(), lease: lease) }
        try await awaitActivation(h.native)
        lease.invalidate()
        h.native.activation?.resume(returning: true)
        h.native.activation = nil
        #expect(await failureReason { _ = try await operation.value } == .invalidHostLease)
        #expect(!h.native.calls.contains("deactivate") && !h.native.calls.contains("start"))
    }

    @Test @MainActor func iosCaptureRouteChangeReportsUnknownGapAndDoesNotAutoResume() async throws
    {
        let h = IOSCaptureHarness()
        let session = try await h.start()
        let oldHandler = try #require(h.native.handler)
        oldHandler(.changed(.route(reason: 2)))
        #expect(h.controller.session == nil)
        #expect(
            await failureReason { try await h.controller.finish() }
                == .configurationChanged(.route(reason: 2)))
        oldHandler(.resumptionRecommended(true))
        #expect(h.controller.session == nil)
        #expect(h.native.calls.filter { $0 == "start" }.count == 1)
        let boundary = try #require(
            h.events.compactMap { event -> SourceDiscontinuity? in
                if case .configurationChanged(_, .route, let boundary) = event { return boundary }
                return nil
            }.first)
        #expect(
            boundary.previousEpoch == session.observation.capture.epoch
                && boundary.missingSource == nil)
        let restarted = try await h.start()
        oldHandler(.changed(.mediaServicesReset))
        #expect(h.controller.session?.observation == restarted.observation)
        try await h.controller.finish()
    }

    @Test @MainActor func iosCaptureFinishRejectsFaultPublishedAfterStop() async throws {
        let h = IOSCaptureHarness()
        _ = try await h.start()
        h.native.retainedCallback = h.native.installed
        h.controller.stop()
        let finishing = Task { try await h.controller.finish() }
        await Task.yield()
        h.native.retainedCallback?.publishFailureForTesting(.invalidBuffer)
        h.native.retainedCallback = nil
        #expect(await failureReason { try await finishing.value } == .callback(.invalidBuffer))
    }

    @Test @MainActor func iosCaptureChangedSettingsPreventStaleDeactivation() async throws {
        let h = IOSCaptureHarness()
        _ = try await h.start(ownership: delegated(), activity: .inactive)
        h.native.configurationStillMatches = false
        h.controller.poll()
        #expect(
            await failureReason { try await h.controller.finish() }
                == .configurationChanged(.sessionConfiguration))
        #expect(!h.native.calls.contains("deactivate"))
    }

    @Test @MainActor func iosCaptureDeactivationRejectionIsNotSuccessfulCompletion() async throws {
        let h = IOSCaptureHarness()
        _ = try await h.start(ownership: delegated(), activity: .inactive)
        h.native.deactivateSucceeds = false
        #expect(await failureReason { try await h.controller.finish() } == .deactivationRejected)
    }

    @Test @MainActor func iosCaptureCancellingTheCallerDuringActivationCleansUp() async throws {
        let h = IOSCaptureHarness()
        h.native.suspendActivation = true
        let operation = Task { try await h.start(ownership: delegated(), activity: .inactive) }
        try await awaitActivation(h.native)
        operation.cancel()
        h.native.activation?.resume(returning: true)
        h.native.activation = nil
        #expect(await failureReason { _ = try await operation.value } == .cancelled)
        #expect(!h.native.calls.contains("start"))
        #expect(h.native.calls.filter { $0 == "deactivate" }.count == 1)
    }

    @Test @MainActor func iosCaptureRejectedActivationDoesNotPrepareOrDeactivate() async throws {
        let h = IOSCaptureHarness()
        h.native.activationSucceeds = false
        #expect(
            await failureReason {
                _ = try await h.start(ownership: delegated(), activity: .inactive)
            }
                == .activationRejected)
        #expect(!h.native.calls.contains("prepare") && !h.native.calls.contains("deactivate"))
    }

    @Test @MainActor func iosCaptureInterruptionDuringActivationCannotResumeIt() async throws {
        let h = IOSCaptureHarness()
        h.native.suspendActivation = true
        let operation = Task { try await h.start(ownership: delegated(), activity: .inactive) }
        try await awaitActivation(h.native)
        h.native.sessionIsKnownInactive = true
        h.native.handler?(.changed(.systemInterruption(reason: 1)))
        h.native.activation?.resume(returning: true)
        h.native.activation = nil
        #expect(
            await failureReason { _ = try await operation.value }
                == .configurationChanged(.systemInterruption(reason: 1)))
        h.native.handler?(.resumptionRecommended(true))
        #expect(h.controller.session == nil && !h.native.calls.contains("start"))
        #expect(!h.native.calls.contains("deactivate"))
    }

    @Test @MainActor func iosCaptureNativeLifecycleChangesInvalidateBoundCalibration() async throws
    {
        let seed = IOSCaptureHarness()
        let original = try await seed.start()
        let calibration = CaptureCalibrationContext(observation: original.observation.capture)
        try await seed.controller.finish()
        for (change, reason) in [
            (IOSCaptureChange.systemInterruption(reason: nil), ResetReason.pause),
            (.mediaServicesLost, .explicitReset), (.mediaServicesReset, .explicitReset),
            (.engineConfiguration, .profileChange), (.sessionConfiguration, .profileChange),
            (.enteredBackground, .pause), (.route(reason: nil), .routeChange),
        ] {
            let h = IOSCaptureHarness()
            let session = try await h.start(calibration: calibration)
            if change == .enteredBackground {
                h.controller.enteredBackground()
            } else {
                h.native.handler?(.changed(change))
            }
            #expect(h.controller.session == nil)
            #expect(
                await failureReason { try await h.controller.finish() }
                    == .configurationChanged(change))
            #expect(
                h.events.contains { event in
                    if case .configurationChanged(_, let cause, let boundary) = event {
                        return cause == change && boundary?.reason == reason
                            && boundary?.missingSource == nil
                            && boundary?.previousEpoch == session.observation.capture.epoch
                    }
                    return false
                })
            #expect(
                h.events.contains { event in
                    if case .calibrationInvalidated(let observation, let cause) = event {
                        return observation == session.observation && cause == change
                    }
                    return false
                })
        }
    }

    @Test @MainActor func iosCaptureCalibrationEventCanCancelBeforeEngineStarts() async throws {
        let seed = IOSCaptureHarness()
        let original = try await seed.start()
        let calibration = CaptureCalibrationContext(observation: original.observation.capture)
        try await seed.controller.finish()
        let h = IOSCaptureHarness()
        h.native.route = "route-b"
        h.eventHook = { [weak h] event in
            if case .calibrationConfiguration = event { h?.controller.stop() }
        }
        #expect(
            await failureReason { _ = try await h.start(calibration: calibration) } == .cancelled)
        #expect(!h.native.calls.contains("install") && !h.native.calls.contains("start"))
        #expect(
            !h.events.contains {
                if case .started = $0 { return true }
                return false
            })
        #expect(
            h.events.contains {
                if case .failed(let problem) = $0 { return problem.observation != nil }
                return false
            })
    }

    @Test @MainActor func iosCaptureNewStartWaitsForPriorDeactivation() async throws {
        let h = IOSCaptureHarness()
        h.native.suspendDeactivation = true
        _ = try await h.start(ownership: delegated(), activity: .inactive)
        let finishing = Task { try await h.controller.finish() }
        for _ in 0..<1000 {
            if h.native.deactivation != nil { break }
            await Task.yield()
        }
        let suspended = try #require(h.native.deactivation)
        #expect(await failureReason { _ = try await h.start() } == .alreadyRunning)
        suspended.resume(returning: true)
        h.native.deactivation = nil
        try await finishing.value
        h.native.suspendDeactivation = false
        _ = try await h.start()
        try await h.controller.finish()
    }

    @Test @MainActor func iosCaptureLeaseInvalidationStopsWithoutDeactivatingHost() async throws {
        let h = IOSCaptureHarness()
        let lease = IOSCaptureHostLease(activity: .inactive)
        _ = try await h.start(ownership: delegated(), lease: lease)
        lease.invalidate()
        h.controller.poll()
        #expect(
            await failureReason { try await h.controller.finish() }
                == .configurationChanged(.hostLeaseInvalidated))
        #expect(!h.native.calls.contains("deactivate"))
    }

    @Test @MainActor func iosCaptureIntentsAreOwnerBoundAndSingleUse() async throws {
        let first = IOSCaptureHarness()
        let second = IOSCaptureHarness()
        let token = first.controller.prepareStart()
        #expect(
            await failureReason {
                _ = try await second.controller.start(
                    intent: token, request: iosRequest(), buffering: CaptureBuffering(),
                    lease: IOSCaptureHostLease(activity: .active), calibration: nil)
            } == .invalidStartIntent)
        _ = try await first.controller.start(
            intent: token, request: iosRequest(), buffering: CaptureBuffering(),
            lease: IOSCaptureHostLease(activity: .active), calibration: nil)
        try await first.controller.finish()
        #expect(
            await failureReason {
                _ = try await first.controller.start(
                    intent: token, request: iosRequest(), buffering: CaptureBuffering(),
                    lease: IOSCaptureHostLease(activity: .active), calibration: nil)
            } == .invalidStartIntent)
    }
#endif
