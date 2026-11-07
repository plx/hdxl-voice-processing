#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Foundation
    import HDXLVoiceProcessing

    struct IOSCaptureEngineConfiguration {
        let format: PCMFormat
        let input: CaptureInputIdentity
        let processing: CaptureProcessingObservation
        let audioSession: IOSAudioSessionObservation
    }

    enum IOSCaptureBackendEvent: Sendable {
        case changed(IOSCaptureChange)
        case becameActive
        case resumptionRecommended(Bool?)
    }

    /// Platform effects are injected so policy and suspended-operation races can
    /// be tested without pretending a macOS fake is an iOS microphone.
    @MainActor protocol IOSCaptureBackend: AnyObject {
        func configureInactiveSession(request: CaptureRequest) throws
        func activate() async throws -> Bool
        func prepareEngine(request: CaptureRequest) throws -> IOSCaptureEngineConfiguration
        func observe(_ handler: @escaping @MainActor @Sendable (IOSCaptureBackendEvent) -> Void)
        func stopObserving()
        func installTap(_ tap: PreparedCaptureTap, requestedFrames: UInt32) throws
        func startEngine() throws
        func stopEngine()
        var configurationStillMatches: Bool { get }
        var sessionIsKnownInactive: Bool { get }
        func deactivate() async throws -> Bool
    }

    @MainActor final class IOSCaptureController {
        private(set) var session: IOSCaptureSession?
        private let owner = UUID()
        private var intent: UUID?
        private var generation = UUID()
        private var monitorGeneration = UUID()
        private var nextEpoch = StreamEpoch(streamID: UUID())
        private let authorization: any MicrophoneAuthorizationProviding
        private let makeBackend: () -> any IOSCaptureBackend
        private let onEvent: @MainActor (IOSCaptureEvent) -> Void
        private var backend: (any IOSCaptureBackend)?
        private var lifecycleBackend: (any IOSCaptureBackend)?
        private var lease: IOSCaptureHostLease?
        private var tap: PreparedCaptureTap?
        private var timer: Timer?
        private var startup: Task<IOSCaptureSession, any Error>?
        private var completion: Task<IOSCaptureFailure?, Never>?
        private var finishing = false
        private var activated = false
        private var calibration: CaptureCalibrationContext?
        private var pendingChange: IOSCaptureChange?

        init(
            authorization: any MicrophoneAuthorizationProviding,
            makeBackend: @escaping () -> any IOSCaptureBackend,
            onEvent: @escaping @MainActor (IOSCaptureEvent) -> Void
        ) {
            self.authorization = authorization
            self.makeBackend = makeBackend
            self.onEvent = onEvent
        }

        isolated deinit {
            endCurrent(change: nil, reportEvents: false)
            lifecycleBackend?.stopObserving()
        }

        func prepareStart() -> IOSCaptureStartIntent {
            let token = UUID()
            intent = token
            return IOSCaptureStartIntent(owner: owner, generation: token)
        }

        func start(
            intent token: IOSCaptureStartIntent, request: CaptureRequest,
            buffering: CaptureBuffering, lease: IOSCaptureHostLease,
            calibration: CaptureCalibrationContext?
        ) async throws -> IOSCaptureSession {
            guard startup == nil, session == nil, !finishing else {
                throw failure(.alreadyRunning, request: request)
            }
            guard token.owner == owner, token.generation == intent else {
                throw failure(.invalidStartIntent, request: request)
            }
            intent = nil
            generation = token.generation
            pendingChange = nil
            completion = nil
            let task = Task { @MainActor in
                try await self.startOperation(
                    generation: token.generation, request: request,
                    buffering: buffering, lease: lease, calibration: calibration)
            }
            startup = task
            defer { startup = nil }
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if Task.isCancelled {
                stop()
                try? await finish()
                throw failure(.cancelled, request: request, observation: result.observation)
            }
            return result
        }

        private func startOperation(
            generation current: UUID, request: CaptureRequest,
            buffering: CaptureBuffering, lease: IOSCaptureHostLease,
            calibration: CaptureCalibrationContext?
        ) async throws -> IOSCaptureSession {
            var observation: IOSCaptureObservation?
            var stage: IOSCaptureStage = .sessionConfiguration
            do {
                try ensureCurrent(current, lease: lease, request: request)
                guard request.execution == .foreground else {
                    throw CaptureIntegrationError.unsupportedCapability(.backgroundExecution)
                }
                switch authorization.microphoneAuthorization() {
                case .authorized: break
                case .denied: throw CaptureIntegrationError.permissionDenied
                case .restricted: throw CaptureIntegrationError.permissionRestricted
                case .undetermined: throw CaptureIntegrationError.permissionUndetermined
                case .unavailable: throw CaptureIntegrationError.authorizationUnavailable
                }
                guard lease.claim() else { throw failure(.invalidHostLease, request: request) }
                if lease.activity == .unknown {
                    throw failure(.unknownSessionActivity, request: request)
                }
                if lease.activity == .inactive {
                    guard case .delegated(let permission) = request.sessionOwnership,
                        permission.permitsActivation
                    else {
                        throw CaptureIntegrationError.configurationConflict(.inactiveSession)
                    }
                }
                self.lease = lease
                self.calibration = calibration
                lifecycleBackend?.stopObserving()
                let native = makeBackend()
                backend = native
                lifecycleBackend = native
                monitorGeneration = current
                native.observe { [weak self] event in self?.receive(event, generation: current) }
                if lease.activity == .inactive {
                    try native.configureInactiveSession(request: request)
                    try ensureCurrent(current, lease: lease, request: request)
                    stage = .activation
                    let didActivate = try await native.activate()
                    activated = didActivate
                    guard didActivate else { throw failure(.activationRejected, request: request) }
                }
                try ensureCurrent(current, lease: lease, request: request)
                stage = .engineConfiguration
                let configuration = try native.prepareEngine(request: request)
                let capture = try CaptureConfigurationObservation(
                    epoch: nextEpoch, request: request, effectiveFormat: configuration.format,
                    input: configuration.input, processing: configuration.processing)
                let successor = try nextEpoch.successor()
                let observed = IOSCaptureObservation(
                    capture: capture, audioSession: configuration.audioSession)
                observation = observed
                if let calibration {
                    onEvent(.calibrationConfiguration(observed, calibration.compare(with: capture)))
                    try ensureCurrent(current, lease: lease, request: request)
                }
                let transfer = PCMTransfer(
                    configuration: try PCMTransferConfiguration(
                        format: configuration.format, epoch: capture.epoch,
                        maximumFramesPerChunk: buffering.maximumFramesPerChunk,
                        slotCount: buffering.slotCount))
                let prepared = PreparedCaptureTap(transfer: transfer)
                tap = prepared
                stage = .tapInstallation
                try native.installTap(prepared, requestedFrames: buffering.requestedTapFrames)
                stage = .engineStart
                try native.startEngine()
                try ensureCurrent(current, lease: lease, request: request)
                let result = IOSCaptureSession(observation: observed, transfer: transfer)
                session = result
                nextEpoch = successor
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                }
                onEvent(.started(result))
                return result
            } catch {
                if generation == current { generation = UUID() }
                let problem: IOSCaptureFailure
                if let change = pendingChange {
                    problem = failure(
                        .configurationChanged(change), request: request, observation: observation)
                } else if let known = error as? IOSCaptureFailure {
                    problem = failure(
                        known.reason, request: request,
                        observation: known.observation ?? observation)
                } else if let integration = error as? CaptureIntegrationError {
                    problem = failure(
                        .integration(integration), request: request, observation: observation)
                } else {
                    problem = failure(
                        .system(stage: stage, code: (error as NSError).code),
                        request: request, observation: observation)
                }
                tap?.close()
                backend?.stopEngine()
                let retired = tap.map { RetiredCaptureTap.releaseWhenUnreferenced($0) }
                tap = nil
                let native = backend
                backend = nil
                self.lease = nil
                self.calibration = nil
                let ownedActivation = activated
                activated = false
                _ = await retired?.value
                if let native {
                    let release = await Self.releaseSession(
                        native, lease: lease, request: request,
                        activated: ownedActivation, observation: observation)
                    onEvent(.sessionDisposition(release.disposition))
                    if let cleanupFailure = release.failure { onEvent(.failed(cleanupFailure)) }
                }
                completion = Task { problem }
                onEvent(.failed(problem))
                throw problem
            }
        }

        private func ensureCurrent(
            _ current: UUID, lease: IOSCaptureHostLease,
            request: CaptureRequest
        ) throws {
            guard current == generation, !Task.isCancelled else {
                throw failure(.cancelled, request: request)
            }
            guard lease.isValid else { throw failure(.invalidHostLease, request: request) }
        }

        func stop() {
            intent = nil
            generation = UUID()
            startup?.cancel()
            if session != nil {
                endCurrent(change: nil)
            } else if startup != nil {
                // An outstanding activation still has to return before release can
                // determine whether this operation actually activated the session.
                tap?.close()
                backend?.stopEngine()
            }
        }

        func finish() async throws {
            stop()
            // Bind this call to the operation it stopped. A later start must not
            // replace the terminal result while this caller is suspended.
            let starting = startup
            let terminal = completion
            if let starting { _ = try await starting.value }
            if let problem = await terminal?.value { throw problem }
        }

        func enteredBackground() {
            receive(.changed(.enteredBackground), generation: generation)
            // Also invalidate an intent awaiting a host permission action.
            stop()
        }

        func poll() {
            if lease?.isValid == false {
                receive(.changed(.hostLeaseInvalidated), generation: generation)
            } else if session != nil, backend?.configurationStillMatches == false {
                receive(.changed(.sessionConfiguration), generation: generation)
            } else if session != nil, tap?.failure != nil {
                stop()
            }
        }

        private func receive(_ event: IOSCaptureBackendEvent, generation current: UUID) {
            guard monitorGeneration == current else { return }
            switch event {
            case .becameActive: onEvent(.sessionBecameActive)
            case .resumptionRecommended(let recommendation):
                onEvent(.resumptionRecommended(recommendation))
            case .changed(let change):
                guard generation == current, session != nil || startup != nil else { return }
                pendingChange = change
                generation = UUID()
                intent = nil
                if session != nil {
                    endCurrent(change: change)
                } else {
                    startup?.cancel()
                    tap?.close()
                    backend?.stopEngine()
                    onEvent(.configurationChanged(nil, change, nil))
                }
            }
        }

        private func endCurrent(change: IOSCaptureChange?, reportEvents: Bool = true) {
            guard let previous = session, let native = backend, let lease else { return }
            generation = UUID()
            timer?.invalidate()
            timer = nil
            let knownFault = tap?.failure
            tap?.close()
            native.stopEngine()
            let retired = tap.map { RetiredCaptureTap.releaseWhenUnreferenced($0) }
            tap = nil
            backend = nil
            self.lease = nil
            session = nil
            let hadCalibration = calibration != nil
            calibration = nil
            let ownedActivation = activated
            activated = false
            let request = previous.observation.capture.request
            let primary =
                knownFault.map {
                    failure(.callback($0), request: request, observation: previous.observation)
                }
                ?? change.map {
                    failure(
                        .configurationChanged($0), request: request,
                        observation: previous.observation)
                }
            // nextEpoch was computed successfully before native capture began.
            let reason: ResetReason
            switch change {
            case .route: reason = .routeChange
            case .engineConfiguration, .sessionConfiguration: reason = .profileChange
            case .mediaServicesLost, .mediaServicesReset: reason = .explicitReset
            default: reason = .pause
            }
            let boundary = try? SourceDiscontinuity(
                previousEpoch: previous.observation.capture.epoch,
                nextEpoch: nextEpoch, reason: reason)
            finishing = true
            let handler = onEvent
            completion = Task { @MainActor [weak self] in
                let fault = await retired?.value
                let release = await Self.releaseSession(
                    native, lease: lease, request: request,
                    activated: ownedActivation, observation: previous.observation)
                let lateFailure = fault.map {
                    IOSCaptureFailure(
                        reason: .callback($0), request: request, observation: previous.observation)
                }
                if reportEvents {
                    handler(.sessionDisposition(release.disposition))
                    if knownFault == nil, let lateFailure { handler(.failed(lateFailure)) }
                    if let cleanupFailure = release.failure { handler(.failed(cleanupFailure)) }
                }
                self?.finishing = false
                return lateFailure ?? primary ?? release.failure
            }
            if reportEvents {
                if let change {
                    if hadCalibration {
                        onEvent(.calibrationInvalidated(previous.observation, change))
                    }
                    onEvent(.configurationChanged(previous.observation, change, boundary))
                } else if let boundary {
                    onEvent(.stopped(previous.observation, boundary))
                }
                if knownFault != nil, let primary { onEvent(.failed(primary)) }
            }
        }

        private static func releaseSession(
            _ native: any IOSCaptureBackend, lease: IOSCaptureHostLease,
            request: CaptureRequest, activated: Bool,
            observation: IOSCaptureObservation?
        ) async
            -> (disposition: IOSCaptureSessionDisposition, failure: IOSCaptureFailure?)
        {
            guard activated else { return (.notActivatedByAdapter, nil) }
            guard case .delegated(let permission) = request.sessionOwnership,
                permission.permitsDeactivation
            else { return (.deactivationNotPermitted, nil) }
            guard lease.isValid else { return (.ownershipChanged, nil) }
            guard !native.sessionIsKnownInactive else { return (.systemAlreadyInactive, nil) }
            guard native.configurationStillMatches else { return (.configurationChanged, nil) }
            do {
                guard try await native.deactivate() else {
                    return (
                        .deactivationFailed,
                        IOSCaptureFailure(
                            reason: .deactivationRejected,
                            request: request, observation: observation)
                    )
                }
                return (.deactivated, nil)
            } catch {
                return (
                    .deactivationFailed,
                    IOSCaptureFailure(
                        reason: .system(stage: .deactivation, code: (error as NSError).code),
                        request: request, observation: observation)
                )
            }
        }

        private func failure(
            _ reason: IOSCaptureFailureReason, request: CaptureRequest,
            observation: IOSCaptureObservation? = nil
        ) -> IOSCaptureFailure {
            IOSCaptureFailure(reason: reason, request: request, observation: observation)
        }
    }
#endif
