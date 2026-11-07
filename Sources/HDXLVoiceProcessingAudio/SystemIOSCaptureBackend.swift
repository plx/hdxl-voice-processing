#if os(iOS) && !targetEnvironment(macCatalyst)
    import AVFAudio
    import CryptoKit
    import Foundation
    import HDXLVoiceProcessing

    /// Created only after authorization and the host lease have been checked.
    /// Engine construction waits until the shared session is usable.
    @MainActor final class SystemIOSCaptureBackend: IOSCaptureBackend {
        private let audioSession = AVAudioSession.sharedInstance()
        private var engine: AVAudioEngine?
        private var nativeFormat: AVAudioFormat?
        private var installed = false
        private var typedObservers: [NotificationCenter.ObservationToken] = []
        private var sessionObservers: [any NSObjectProtocol] = []
        private var routeObserver: (any NSObjectProtocol)?
        private var engineObserver: (any NSObjectProtocol)?
        private var handler: (@MainActor @Sendable (IOSCaptureBackendEvent) -> Void)?
        private var observerGeneration = UUID()
        private var engineGeneration = UUID()
        private var activityRevision: UInt64 = 0
        private(set) var sessionIsKnownInactive = false
        private var expectedSettings: Settings?
        private var expectedRoute: RouteState?

        private struct Settings: Equatable {
            let category: AVAudioSession.Category
            let mode: AVAudioSession.Mode
            let options: AVAudioSession.CategoryOptions
            let sharingPolicy: AVAudioSession.RouteSharingPolicy
            let preferredRate: Double
            let preferredBuffer: Double
            let preferredInput: String?
            let prefersEchoCancellation: Bool
        }

        private struct RoutePort: Equatable, Encodable {
            let uid: String
            let kind: String
            let dataSource: Int?
            let channels: Int
        }

        private struct RouteState: Equatable {
            let inputs: [RoutePort]
            let outputs: [RoutePort]
            let rate: Double
            let bufferDuration: Double
            let channels: Int
            let inputAvailable: Bool
            let gain: Float
            let echoCancelledInput: Bool
        }

        isolated deinit {
            stopEngine()
            stopObserving()
        }

        func configureInactiveSession(request: CaptureRequest) throws {
            guard case .delegated = request.sessionOwnership else {
                throw CaptureIntegrationError.configurationConflict(.delegationRequired)
            }
            if request.processing == .measurement {
                try audioSession.setCategory(.record, mode: .measurement, options: [])
            } else {
                try validateSession(request)
            }
            if let preferred = request.preferredFormat {
                try audioSession.setPreferredSampleRate(preferred.sampleRate)
            }
            // No stale setting restoration: the host explicitly delegated these
            // changes, and owns the resulting shared session even if activation fails.
            expectedSettings = settings()
        }

        func activate() async throws -> Bool {
            let revision = activityRevision
            let result = try await audioSession.activate()
            if revision == activityRevision { sessionIsKnownInactive = !result }
            return result
        }

        func prepareEngine(request: CaptureRequest) throws -> IOSCaptureEngineConfiguration {
            guard !sessionIsKnownInactive else {
                throw CaptureIntegrationError.configurationConflict(.inactiveSession)
            }
            if let expectedSettings, expectedSettings != settings() {
                throw CaptureIntegrationError.configurationConflict(.sessionInUse)
            }
            try validateSession(request)
            let before = routeState()
            guard before.inputAvailable, !before.inputs.isEmpty, before.channels > 0,
                before.rate.isFinite, before.rate > 0
            else { throw CaptureIntegrationError.inputUnavailable }
            installRouteObserver()
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            if request.processing == .measurement, input.isVoiceProcessingEnabled {
                try input.setVoiceProcessingEnabled(false)
            }
            guard request.processing != .measurement || !input.isVoiceProcessingEnabled else {
                throw CaptureIntegrationError.configurationConflict(.incompatibleProcessing)
            }
            let hardware = input.inputFormat(forBus: 0)
            guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0
            else {
                throw CaptureIntegrationError.inputUnavailable
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                (1...32).contains(format.channelCount),
                format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64
            else {
                throw CaptureIntegrationError.configurationConflict(.incompatibleFormat)
            }
            let after = routeState()
            guard before == after else {
                throw CaptureIntegrationError.configurationConflict(.sessionInUse)
            }
            try validateSession(request)
            expectedSettings = settings()
            expectedRoute = after
            nativeFormat = format
            installEngineObserver(engine)
            return try IOSCaptureEngineConfiguration(
                format: PCMFormat(
                    sampleRate: format.sampleRate, channelCount: Int(format.channelCount),
                    encoding: format.commonFormat == .pcmFormatFloat32 ? .float32 : .float64,
                    layout: format.isInterleaved ? .interleaved : .planar),
                input: inputIdentity(after),
                processing: CaptureProcessingObservation(
                    sessionMode: .observed(audioSession.mode.rawValue),
                    engineVoiceProcessing: .observed(input.isVoiceProcessingEnabled),
                    // An enabled known stage proves some cancellation is present.
                    // A disabled stage does not prove all other stages are absent.
                    echoCancellation: after.echoCancelledInput ? .observed(true) : .unknown),
                audioSession: IOSAudioSessionObservation(
                    category: audioSession.category.rawValue, mode: audioSession.mode.rawValue,
                    categoryOptions: audioSession.categoryOptions.rawValue,
                    sampleRate: after.rate, ioBufferDuration: after.bufferDuration,
                    echoCancelledInputEnabled: .observed(after.echoCancelledInput)))
        }

        private func validateSession(_ request: CaptureRequest) throws {
            guard audioSession.category == .record || audioSession.category == .playAndRecord else {
                throw CaptureIntegrationError.configurationConflict(.unsupportedConfiguration)
            }
            if request.processing == .measurement {
                guard audioSession.mode == .measurement, !audioSession.isEchoCancelledInputEnabled
                else {
                    throw CaptureIntegrationError.configurationConflict(.incompatibleProcessing)
                }
            }
        }

        var configurationStillMatches: Bool {
            guard let expectedSettings, expectedSettings == settings() else { return false }
            return expectedRoute.map { $0 == routeState() } ?? true
        }

        func installTap(_ tap: PreparedCaptureTap, requestedFrames: UInt32) throws {
            guard let engine, let nativeFormat else {
                throw CaptureIntegrationError.invalidConfiguration
            }
            try engine.inputNode.installAudioTap(
                onBus: 0, bufferSize: requestedFrames, format: nativeFormat
            ) {
                buffer, time in tap.accept(buffer, at: time)
            }
            installed = true
        }

        func startEngine() throws {
            guard let engine else { throw CaptureIntegrationError.invalidConfiguration }
            try engine.start()
        }

        func stopEngine() {
            engineGeneration = UUID()
            if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
            if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
            engineObserver = nil
            routeObserver = nil
            engine?.stop()
            if installed { engine?.inputNode.removeTap(onBus: 0) }
            installed = false
            nativeFormat = nil
            engine = nil
        }

        func deactivate() async throws -> Bool {
            let result = try await audioSession.deactivate()
            if result { sessionIsKnownInactive = true }
            return result
        }

        func observe(_ handler: @escaping @MainActor @Sendable (IOSCaptureBackendEvent) -> Void) {
            stopObserving()
            self.handler = handler
            let center = NotificationCenter.default
            typedObservers = [
                center.addObserver(of: audioSession, for: .didBecomeActive) { [weak self] _ in
                    self?.activityRevision &+= 1
                    self?.sessionIsKnownInactive = false
                    self?.relay(.becameActive)
                },
                center.addObserver(of: audioSession, for: .didBecomeInactive) {
                    [weak self] message in
                    self?.activityRevision &+= 1
                    self?.sessionIsKnownInactive = true
                    switch message.deactivationResult {
                    case .appDeactivated: self?.relay(.changed(.hostDeactivatedSession))
                    case .systemInterruption(let context):
                        self?.relay(
                            .changed(.systemInterruption(reason: Int(context.reason.rawValue))))
                    @unknown default: self?.relay(.changed(.systemInterruption(reason: nil)))
                    }
                },
                center.addObserver(of: audioSession, for: .resumptionRecommendation) {
                    [weak self] message in
                    let recommendation: Bool?
                    switch message.recommendation {
                    case .shouldResume: recommendation = true
                    case .shouldNotResume: recommendation = false
                    @unknown default: recommendation = nil
                    }
                    self?.relay(.resumptionRecommended(recommendation))
                },
            ]
            for (name, change) in [
                (
                    AVAudioSession.mediaServicesWereLostNotification,
                    IOSCaptureChange.mediaServicesLost
                ),
                (
                    AVAudioSession.mediaServicesWereResetNotification,
                    IOSCaptureChange.mediaServicesReset
                ),
            ] {
                sessionObservers.append(
                    center.addObserver(forName: name, object: audioSession, queue: nil) {
                        [weak self] _ in
                        Task { @MainActor in
                            self?.activityRevision &+= 1
                            self?.sessionIsKnownInactive = true
                            self?.relay(.changed(change))
                        }
                    })
            }
        }

        func stopObserving() {
            observerGeneration = UUID()
            for token in typedObservers { NotificationCenter.default.removeObserver(token) }
            for token in sessionObservers { NotificationCenter.default.removeObserver(token) }
            typedObservers.removeAll()
            sessionObservers.removeAll()
            handler = nil
        }

        private func installRouteObserver() {
            let current = engineGeneration
            routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: audioSession, queue: nil
            ) { [weak self] notification in
                let reason =
                    (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?
                    .uintValue
                Task { @MainActor in
                    guard let self, current == self.engineGeneration else { return }
                    self.relay(.changed(.route(reason: reason)))
                }
            }
        }

        private func installEngineObserver(_ engine: AVAudioEngine) {
            let current = engineGeneration
            engineObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, current == self.engineGeneration else { return }
                    self.relay(.changed(.engineConfiguration))
                }
            }
        }

        private func relay(_ event: IOSCaptureBackendEvent) {
            let current = observerGeneration
            // A second main-actor turn also keeps native MainActorMessage delivery
            // free of engine teardown, user events, or shared-session mutations.
            Task { @MainActor [weak self] in
                guard let self, current == observerGeneration else { return }
                handler?(event)
            }
        }

        private func settings() -> Settings {
            Settings(
                category: audioSession.category, mode: audioSession.mode,
                options: audioSession.categoryOptions,
                sharingPolicy: audioSession.routeSharingPolicy,
                preferredRate: audioSession.preferredSampleRate,
                preferredBuffer: audioSession.preferredIOBufferDuration,
                preferredInput: audioSession.preferredInput?.uid,
                prefersEchoCancellation: audioSession.prefersEchoCancelledInput)
        }

        private func routeState() -> RouteState {
            func ports(_ values: [AVAudioSessionPortDescription]) -> [RoutePort] {
                values.map {
                    RoutePort(
                        uid: $0.uid, kind: $0.portType.rawValue,
                        dataSource: $0.selectedDataSource?.dataSourceID.intValue,
                        channels: $0.channels?.count ?? 0)
                }
            }
            let route = audioSession.currentRoute
            return RouteState(
                inputs: ports(route.inputs), outputs: ports(route.outputs),
                rate: audioSession.sampleRate,
                bufferDuration: audioSession.ioBufferDuration,
                channels: audioSession.inputNumberOfChannels,
                inputAvailable: audioSession.isInputAvailable, gain: audioSession.inputGain,
                echoCancelledInput: audioSession.isEchoCancelledInputEnabled)
        }

        private func inputIdentity(_ state: RouteState) throws -> CaptureInputIdentity {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode([state.inputs, state.outputs])
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            // The fingerprint is stable acquisition identity, not anonymization.
            // It and any UID stay local unless the host explicitly exports them.
            return try CaptureInputIdentity(
                deviceIdentifier: state.inputs.count == 1
                    ? .observed(state.inputs[0].uid) : .unknown,
                routeIdentifier: .observed("avroute-sha256:" + digest))
        }
    }
#endif
