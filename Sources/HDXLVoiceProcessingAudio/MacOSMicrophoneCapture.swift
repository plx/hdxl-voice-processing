#if os(macOS)
    import AVFAudio
    import Foundation
    import HDXLVoiceProcessing

    public struct MacOSCaptureBuffering: Sendable, Hashable {
        public let requestedTapFrames: UInt32
        public let maximumFramesPerChunk: UInt32
        public let slotCount: Int

        /// The requested tap size is a hint, independent of the maximum accepted size.
        /// The engine may deliver larger blocks; these become explicit transport gaps.
        public init(
            requestedTapFrames: UInt32 = 4096, maximumFramesPerChunk: UInt32 = 32_768,
            slotCount: Int = 16
        ) throws {
            guard (1...65_536).contains(requestedTapFrames),
                (1...65_536).contains(maximumFramesPerChunk),
                (2...4096).contains(slotCount), slotCount.nonzeroBitCount == 1
            else { throw CaptureIntegrationError.invalidConfiguration }
            self.requestedTapFrames = requestedTapFrames
            self.maximumFramesPerChunk = maximumFramesPerChunk
            self.slotCount = slotCount
        }
    }

    public enum MacOSCaptureFailureReason: Sendable, Hashable {
        case integration(CaptureIntegrationError)
        case alreadyRunning
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
                onEvent(.failed(failure))
                throw failure
            }
        }

        /// Idempotent. Already admitted copies may finish; the worker drains to `.finished`.
        public func stop() {
            guard let previous = session else { return }
            tearDown()
            onEvent(.stopped(previous.observation))
        }

        /// Also called by the active control timer. Failure publication is constant
        /// size and atomic on capture; engine teardown and events occur only here.
        public func poll() {
            guard let previous = session, let failure = tap?.failure else { return }
            tearDown()
            onEvent(
                .failed(
                    MacOSCaptureFailure(
                        reason: .callback(failure),
                        request: previous.observation.request, observation: previous.observation)))
        }

        private func configurationChanged(generation: UUID) {
            guard generation == self.generation, let previous = session else { return }
            tearDown()
            onEvent(.configurationChanged(previous.observation))
        }

        private func tearDown() {
            generation = UUID()
            timer?.invalidate()
            timer = nil
            tap?.close()
            engine?.stop()
            engine = nil
            if let tap { RetiredCaptureTap.releaseWhenUnreferenced(tap) }
            tap = nil
            session = nil
        }
    }

    /// After tap removal no new callback closure is published. Existing invocations
    /// may still retain the bridge even after its atomic admission flag clears. Keep
    /// the final reference on the control actor until those closures have released it;
    /// a quiescent flag alone would not cover the callback's ARC epilogue.
    @MainActor private final class RetiredCaptureTap {
        var tap: PreparedCaptureTap?
        init(_ tap: PreparedCaptureTap) { self.tap = tap }

        static func releaseWhenUnreferenced(_ tap: PreparedCaptureTap) {
            let owner = RetiredCaptureTap(tap)
            Task { @MainActor in
                while !isKnownUniquelyReferenced(&owner.tap) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                owner.tap = nil
            }
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
