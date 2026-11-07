#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Foundation
    import HDXLVoiceProcessing

    struct CaptureLifecycleInput: Sendable {
        let observation: CaptureConfigurationObservation
        let audioSession: IOSAudioSessionObservation?
        let transfer: PCMTransfer
    }

    enum CaptureLifecycleSignal: Sendable {
        case changed(CaptureLifecycleChange)
        case failed(CaptureLifecycleFailure)
        case sessionDisposition(IOSCaptureSessionDisposition)
    }

    @MainActor protocol CaptureLifecycleDriver: AnyObject {
        func start(
            request: CaptureRequest, buffering: CaptureBuffering, epoch: StreamEpoch,
            lease: IOSCaptureHostLease?
        ) async throws -> CaptureLifecycleInput
        func stop()
        func finish() async throws
    }

    func lifecycleFailure(
        _ error: any Error, stage: CaptureLifecycleStage, epoch: StreamEpoch?
    ) -> CaptureLifecycleFailure {
        if let failure = error as? CaptureLifecycleFailure {
            return CaptureLifecycleFailure(
                stage: failure.stage, reason: failure.reason,
                epoch: failure.epoch ?? epoch, recovery: failure.recovery)
        }
        var reason = CaptureLifecycleFailureReason.system(code: (error as NSError).code)
        var effectiveStage = stage
        if error is CancellationError { reason = .cancelled }
        if let failure = error as? CaptureIntegrationError { reason = .capture(failure) }
        if let failure = error as? AnalysisScheduleError { reason = .analysis(failure) }
        if let failure = error as? IOSCaptureFailure {
            reason = .ios(failure.reason)
            switch failure.reason {
            case .deactivationRejected, .system(stage: .deactivation, code: _):
                effectiveStage = .shutdown
            default: break
            }
        }
        #if os(macOS)
            if let failure = error as? MacOSCaptureFailure {
                switch failure.reason {
                case .integration(let problem): reason = .capture(problem)
                case .callback(let problem): reason = .callback(problem)
                case .alreadyRunning: reason = .conflictingOperation
                case .configurationChanged: reason = .cancelled
                case .preparation: reason = .invalidConfiguration
                case .engineStart(_, let code), .tapInstallation(_, let code):
                    reason = .system(code: code)
                }
            }
        #endif
        return CaptureLifecycleFailure(stage: effectiveStage, reason: reason, epoch: epoch)
    }

    extension CaptureLifecycleFailure {
        var expectedDuringStop: Bool {
            switch reason {
            case .cancelled, .ios(.cancelled), .ios(.configurationChanged): true
            default: false
            }
        }
    }

    #if os(macOS)
        @MainActor final class MacOSLifecycleDriver: CaptureLifecycleDriver {
            private let capture: MacOSMicrophoneCapture
            init(signal: @escaping @MainActor @Sendable (CaptureLifecycleSignal) -> Void) {
                capture = MacOSMicrophoneCapture { event in
                    switch event {
                    case .configurationChanged: signal(.changed(.engineConfiguration))
                    case .failed(let failure):
                        signal(
                            .failed(
                                lifecycleFailure(
                                    failure, stage: .capture, epoch: failure.observation?.epoch)))
                    default: break
                    }
                }
            }
            func start(
                request: CaptureRequest, buffering: CaptureBuffering, epoch: StreamEpoch,
                lease: IOSCaptureHostLease?
            ) async throws -> CaptureLifecycleInput {
                guard lease == nil else { throw CaptureIntegrationError.invalidConfiguration }
                try Task.checkCancellation()
                let session = try capture.start(
                    request: request, buffering: buffering, epoch: epoch)
                return CaptureLifecycleInput(
                    observation: session.observation, audioSession: nil, transfer: session.transfer)
            }
            func stop() { capture.stop() }
            func finish() async throws { try await capture.finish() }
        }
    #else
        @MainActor final class IOSLifecycleDriver: CaptureLifecycleDriver {
            private let capture: IOSCaptureController
            init(signal: @escaping @MainActor @Sendable (CaptureLifecycleSignal) -> Void) {
                capture = IOSCaptureController(
                    authorization: SystemMicrophoneAuthorization(),
                    makeBackend: { SystemIOSCaptureBackend() },
                    onEvent: { event in
                        switch event {
                        case .configurationChanged(_, let change, _):
                            let reason: CaptureLifecycleChange
                            switch change {
                            case .route: reason = .route
                            case .systemInterruption: reason = .interruption
                            case .hostDeactivatedSession, .hostLeaseInvalidated:
                                reason = .hostOwnership
                            case .mediaServicesLost: reason = .mediaServicesLost
                            case .mediaServicesReset: reason = .mediaServicesReset
                            case .engineConfiguration: reason = .engineConfiguration
                            case .sessionConfiguration: reason = .sessionConfiguration
                            case .enteredBackground: reason = .enteredBackground
                            }
                            signal(.changed(reason))
                        case .failed(let failure):
                            signal(
                                .failed(
                                    lifecycleFailure(
                                        failure, stage: .capture,
                                        epoch: failure.observation?.capture.epoch)))
                        case .sessionDisposition(let disposition):
                            signal(.sessionDisposition(disposition))
                        default: break
                        }
                    })
            }
            func start(
                request: CaptureRequest, buffering: CaptureBuffering, epoch: StreamEpoch,
                lease: IOSCaptureHostLease?
            ) async throws -> CaptureLifecycleInput {
                guard let lease else {
                    throw CaptureLifecycleFailure(
                        stage: .command, reason: .missingHostLease, epoch: epoch,
                        recovery: .renewHostLease)
                }
                try Task.checkCancellation()
                let session = try await capture.start(
                    intent: capture.prepareStart(), request: request, buffering: buffering,
                    lease: lease, calibration: nil, epoch: epoch)
                return CaptureLifecycleInput(
                    observation: session.observation.capture,
                    audioSession: session.observation.audioSession, transfer: session.transfer)
            }
            func stop() { capture.stop() }
            func finish() async throws {
                defer { capture.releaseLifecycleObservers() }
                try await capture.finish()
            }
        }
    #endif
#endif
