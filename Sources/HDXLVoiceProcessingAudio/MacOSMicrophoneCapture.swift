#if os(macOS)
    import AVFAudio
    import Foundation
    import HDXLVoiceProcessing

    public typealias MacOSCaptureBuffering = CaptureBuffering

    public enum MacOSCaptureFailureReason: Sendable, Hashable {
        case integration(CaptureIntegrationError)
        case alreadyRunning, configurationChanged
        case preparation
        case tapInstallation(domain: String, code: Int)
        case engineStart(domain: String, code: Int)
        case callback(CaptureTapFailure)
    }

    /// Recovery context omits localized system strings but retains the request and
    /// any observed input/configuration. Device identifiers are not logged implicitly.
    public struct MacOSCaptureFailure: Error, Sendable, Hashable {
        public let reason: MacOSCaptureFailureReason
        public let request: CaptureRequest
        public let observation: CaptureConfigurationObservation?
    }

    public struct MacOSCaptureSession: Sendable {
        public let observation: CaptureConfigurationObservation
        public let transfer: PCMTransfer

        /// Call on the serial worker that will own this schedule. Selection/downmix
        /// happens there while the tap preserves all native channels and metadata.
        public func makeSchedule<Sample: BinaryFloatingPoint & Sendable>(
            profile: AnalysisScheduleProfile, sourceTileCapacity: Int = 256
        ) throws -> PreparedPCMTransferSchedule<Sample> {
            guard profile.channels == observation.channelSelection else {
                throw AnalysisScheduleError.invalidConfiguration
            }
            let origin = try AnalysisScheduleOrigin(
                source: SourceInterval(
                    epoch: observation.epoch, startSample: 0, sampleCount: 0,
                    sampleRate: observation.effectiveFormat.sampleRate),
                continuityEpoch: observation.epoch)
            return try PreparedPCMTransferSchedule(
                transfer: transfer, profile: profile, origin: origin,
                sourceTileCapacity: sourceTileCapacity)
        }
    }

    public enum MacOSCaptureEvent: Sendable {
        case started(MacOSCaptureSession)
        case stopped(CaptureConfigurationObservation)
        /// Capture has stopped. Start explicitly to observe the new device/format in a new epoch.
        case configurationChanged(CaptureConfigurationObservation)
        case failed(MacOSCaptureFailure)
    }

    /// Basic serialized adapter owner. Constructing it does not construct an engine,
    /// query authorization, prompt, or start capture. All events run on the main actor;
    /// no event closure is reachable from the tap. Explicit `stop` is recommended.
    @MainActor public final class MacOSMicrophoneCapture {
        public private(set) var session: MacOSCaptureSession?
        private let authorization: any MicrophoneAuthorizationProviding
        private let makeEngine: () -> any MacOSCaptureEngine
        private let onEvent: @MainActor (MacOSCaptureEvent) -> Void
        private var engine: (any MacOSCaptureEngine)?
        private var tap: PreparedCaptureTap?
        private var timer: Timer?
        private var generation = UUID()
        private var completion: Task<MacOSCaptureFailure?, Never>?

        public convenience init(
            onEvent: @escaping @MainActor (MacOSCaptureEvent) -> Void = { _ in }
        ) {
            self.init(
                authorization: SystemMicrophoneAuthorization(),
                makeEngine: { SystemMacOSCaptureEngine() },
                onEvent: onEvent)
        }

        init(
            authorization: any MicrophoneAuthorizationProviding,
            makeEngine: @escaping () -> any MacOSCaptureEngine,
            onEvent: @escaping @MainActor (MacOSCaptureEvent) -> Void = { _ in }
        ) {
            self.authorization = authorization
            self.makeEngine = makeEngine
            self.onEvent = onEvent
        }

        isolated deinit { tearDown() }

        /// Each successful start creates independent storage and a fresh stream epoch.
        /// The host must explicitly request permission before calling this method.
        @discardableResult public func start(
            request: CaptureRequest, buffering: MacOSCaptureBuffering
        ) throws -> MacOSCaptureSession {
            guard session == nil else {
                throw MacOSCaptureFailure(
                    reason: .alreadyRunning, request: request,
                    observation: session?.observation)
            }
            completion = nil
            var observation: CaptureConfigurationObservation?
            var stage: MacOSCaptureFailureReason = .preparation
            do {
                guard request.sessionOwnership == .hostManaged else {
                    throw CaptureIntegrationError.unsupportedCapability(.sessionConfiguration)
                }
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
                let backend = makeEngine()
                engine = backend
                let configuration = try backend.configure(request: request)
                let epoch = StreamEpoch(streamID: UUID())
                let observed = try CaptureConfigurationObservation(
                    epoch: epoch, request: request, effectiveFormat: configuration.format,
                    input: configuration.input, processing: configuration.processing)
                observation = observed
                let transfer = PCMTransfer(
                    configuration: try PCMTransferConfiguration(
                        format: configuration.format, epoch: epoch,
                        maximumFramesPerChunk: buffering.maximumFramesPerChunk,
                        slotCount: buffering.slotCount))
                let prepared = PreparedCaptureTap(transfer: transfer)
                tap = prepared
                let currentGeneration = UUID()
                generation = currentGeneration
                // Backend delivers this on a later main-actor turn, never inside the
                // engine's configuration notification callback.
                backend.observeConfigurationChanges { [weak self] in
                    self?.configurationChanged(generation: currentGeneration)
                }
                stage = .tapInstallation(domain: "", code: 0)
                try backend.installTap(prepared, requestedFrames: buffering.requestedTapFrames)
                stage = .engineStart(domain: "", code: 0)
                try backend.start()
                let result = MacOSCaptureSession(observation: observed, transfer: transfer)
                session = result
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                    [weak self] _ in
                    // Installed on the main run loop by the main-actor owner.
                    MainActor.assumeIsolated { self?.poll() }
                }
                onEvent(.started(result))
                return result
            } catch {
                let reason: MacOSCaptureFailureReason
                if let integration = error as? CaptureIntegrationError {
                    reason = .integration(integration)
                } else {
                    let system = error as NSError
                    switch stage {
                    case .tapInstallation:
                        reason = .tapInstallation(domain: system.domain, code: system.code)
                    case .engineStart:
                        reason = .engineStart(domain: system.domain, code: system.code)
                    default: reason = .preparation
                    }
                }
                tearDown()
                let failure = MacOSCaptureFailure(
                    reason: reason, request: request, observation: observation)
                completion = Task { failure }
                onEvent(.failed(failure))
                throw failure
            }
        }

        /// Closes admission immediately. Pending callback failures are preserved;
        /// a stopped event does not certify successful completion. Await `finish()`
        /// before accepting a recording or other whole-session result as successful.
        public func stop() { _ = stopCurrent() }

        /// Stops the current session, or reconciles the last stopped session, and
        /// waits for outstanding callback references before reporting its outcome.
        /// This does not block the main actor or capture, and does not drain the
        /// worker. A caller accepting a recording must also finish its worker.
        public func finish() async throws {
            let terminal = stopCurrent() ?? completion
            if let failure = await terminal?.value { throw failure }
        }

        private func stopCurrent() -> Task<MacOSCaptureFailure?, Never>? {
            guard let previous = session else { return nil }
            let known = tap?.failure.map {
                MacOSCaptureFailure(
                    reason: .callback($0), request: previous.observation.request,
                    observation: previous.observation)
            }
            let retired = tearDown()
            let handler = onEvent
            let terminal = Task { @MainActor in
                guard let fault = await retired?.value else { return known }
                let failure = MacOSCaptureFailure(
                    reason: .callback(fault),
                    request: previous.observation.request, observation: previous.observation)
                if known == nil { handler(.failed(failure)) }
                return failure
            }
            completion = terminal
            if let known {
                onEvent(.failed(known))
            } else {
                onEvent(.stopped(previous.observation))
            }
            return terminal
        }

        /// Also called by the active control timer. Failure publication is constant
        /// size and atomic on capture; engine teardown and events occur only here.
        public func poll() {
            guard session != nil, tap?.failure != nil else { return }
            stop()
        }

        private func configurationChanged(generation: UUID) {
            guard generation == self.generation, let previous = session else { return }
            let retired = tearDown()
            completion = Task { @MainActor in
                let fault = await retired?.value
                return MacOSCaptureFailure(
                    reason: fault.map { .callback($0) } ?? .configurationChanged,
                    request: previous.observation.request, observation: previous.observation)
            }
            onEvent(.configurationChanged(previous.observation))
        }

        @discardableResult private func tearDown() -> Task<CaptureTapFailure?, Never>? {
            generation = UUID()
            timer?.invalidate()
            timer = nil
            tap?.close()
            engine?.stop()
            engine = nil
            let retired = tap.map { RetiredCaptureTap.releaseWhenUnreferenced($0) }
            tap = nil
            session = nil
            return retired
        }
    }

    struct MacOSCaptureEngineConfiguration {
        let format: PCMFormat
        let input: CaptureInputIdentity
        let processing: CaptureProcessingObservation
    }

    @MainActor protocol MacOSCaptureEngine: AnyObject {
        func configure(request: CaptureRequest) throws -> MacOSCaptureEngineConfiguration
        func observeConfigurationChanges(_ handler: @escaping @MainActor @Sendable () -> Void)
        func installTap(_ tap: PreparedCaptureTap, requestedFrames: UInt32) throws
        func start() throws
        func stop()
    }
#endif
