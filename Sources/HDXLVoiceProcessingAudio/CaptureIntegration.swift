import HDXLVoiceProcessing

/// Independent capabilities; importing a product does not acquire any of them.
public enum AudioCapability: String, Sendable, Hashable, CaseIterable {
    case dsp, fileDecoding, liveCapture, sessionConfiguration, playback, visualization
    case backgroundExecution
}

/// A runtime provider's assessment, not an inference from SDK declarations.
public enum AudioCapabilityAvailability: Sendable, Hashable {
    case available, unavailable, unsupported, unqualified
}

public enum MicrophoneAuthorization: Sendable, Hashable {
    case authorized, denied, restricted, undetermined, unavailable
}

public enum CaptureInputAvailability: Sendable, Hashable {
    case available, unavailable, unknown
}

/// Permission to change a shared session must be explicitly supplied by the host.
/// Configuration permission does not imply permission to activate or deactivate.
public struct CaptureSessionDelegation: Sendable, Hashable {
    public let permitsActivation: Bool
    public let permitsDeactivation: Bool

    public init(permitsActivation: Bool, permitsDeactivation: Bool) {
        self.permitsActivation = permitsActivation
        self.permitsDeactivation = permitsDeactivation
    }
}

public enum CaptureSessionOwnership: Sendable, Hashable {
    /// Observe/validate the host's shared session. Never configure, activate, or deactivate it.
    /// Also used on macOS, which has no shared-session configuration capability.
    case hostManaged
    /// The host permits the adapter to negotiate configuration for this capture operation.
    /// This is not exclusivity: the adapter must still detect conflicts and ownership changes.
    case delegated(CaptureSessionDelegation)
}

public enum CaptureProcessingRequest: Sendable, Hashable {
    case observeHostConfiguration
    /// Request the measurement path and disabled engine voice processing; never implies raw audio.
    case measurement
}

public enum CaptureExecutionRequest: Sendable, Hashable {
    case foreground, background
}

/// Preferences remain distinct from the effective format observed after configuration.
/// Initialization only validates values; it does not inspect permissions or hardware.
public struct CaptureRequest: Sendable, Hashable {
    /// Nil accepts the system-selected format. A preference is not a hardware guarantee.
    public let preferredFormat: PCMFormat?
    public let channelSelection: PCMChannelSelection
    public let processing: CaptureProcessingRequest
    public let sessionOwnership: CaptureSessionOwnership
    public let execution: CaptureExecutionRequest

    public init(
        preferredFormat: PCMFormat? = nil, channelSelection: PCMChannelSelection,
        processing: CaptureProcessingRequest,
        sessionOwnership: CaptureSessionOwnership = .hostManaged,
        execution: CaptureExecutionRequest = .foreground
    ) throws {
        if let format = preferredFormat, let index = channelSelection.channelIndex,
            index >= format.channelCount
        {
            throw CaptureIntegrationError.invalidConfiguration
        }
        self.preferredFormat = preferredFormat
        self.channelSelection = channelSelection
        self.processing = processing
        self.sessionOwnership = sessionOwnership
        self.execution = execution
    }
}

public enum CaptureConfigurationConflict: Sendable, Hashable {
    case sessionInUse, inactiveSession, incompatibleFormat, incompatibleProcessing
    case delegationRequired, unsupportedConfiguration
}

public enum CaptureConfigurationDecision: Sendable, Hashable {
    case accepted
    case conflict(CaptureConfigurationConflict)
}

/// Capture/control failures are separate from core measurement unavailability.
/// No private device names, audio, or underlying system error strings are carried here.
public enum CaptureIntegrationError: Error, Sendable, Hashable {
    case unsupportedCapability(AudioCapability)
    case unavailableCapability(AudioCapability)
    case unqualifiedCapability(AudioCapability)
    case permissionDenied, permissionRestricted, permissionUndetermined, authorizationUnavailable
    case inputUnavailable, inputUnknown, invalidConfiguration
    case configurationConflict(CaptureConfigurationConflict)
}

/// Control-plane providers run on the host's main actor, never in a capture callback.
/// Implementations must only inspect state; queries must not prompt, activate, or persist audio.
@MainActor public protocol CaptureCapabilityProviding {
    func availability(of capability: AudioCapability) -> AudioCapabilityAvailability
    func inputAvailability() -> CaptureInputAvailability
}

/// Checking permission is separate from requesting it after an explicit host action.
@MainActor public protocol MicrophoneAuthorizationProviding {
    func microphoneAuthorization() -> MicrophoneAuthorization
}

/// Inspect whether the entire request agrees with host policy and the current session.
/// Acceptance does not itself apply configuration, acquire a session, or start capture.
@MainActor public protocol CaptureConfigurationNegotiating {
    func evaluate(_ request: CaptureRequest) -> CaptureConfigurationDecision
}

/// Read-only, transient preflight. Construction invokes none of the providers.
/// A successful check is not an authorization lease: adapters must recheck on start
/// and report changes during capture. The host alone decides whether to request permission.
@MainActor public struct CapturePreflight {
    private let capabilities: any CaptureCapabilityProviding
    private let authorization: any MicrophoneAuthorizationProviding
    private let configuration: any CaptureConfigurationNegotiating

    public init(
        capabilities: any CaptureCapabilityProviding,
        authorization: any MicrophoneAuthorizationProviding,
        configuration: any CaptureConfigurationNegotiating
    ) {
        self.capabilities = capabilities
        self.authorization = authorization
        self.configuration = configuration
    }

    /// Fail before consulting later providers; no request, configuration, or start occurs here.
    public func check(_ request: CaptureRequest) throws {
        try require(.liveCapture)
        if request.execution == .background { try require(.backgroundExecution) }
        if case .delegated = request.sessionOwnership { try require(.sessionConfiguration) }
        switch authorization.microphoneAuthorization() {
        case .authorized: break
        case .denied: throw CaptureIntegrationError.permissionDenied
        case .restricted: throw CaptureIntegrationError.permissionRestricted
        case .undetermined: throw CaptureIntegrationError.permissionUndetermined
        case .unavailable: throw CaptureIntegrationError.authorizationUnavailable
        }
        switch capabilities.inputAvailability() {
        case .available: break
        case .unavailable: throw CaptureIntegrationError.inputUnavailable
        case .unknown: throw CaptureIntegrationError.inputUnknown
        }
        if case .conflict(let reason) = configuration.evaluate(request) {
            throw CaptureIntegrationError.configurationConflict(reason)
        }
    }

    private func require(_ capability: AudioCapability) throws {
        switch capabilities.availability(of: capability) {
        case .available: break
        case .unavailable: throw CaptureIntegrationError.unavailableCapability(capability)
        case .unsupported: throw CaptureIntegrationError.unsupportedCapability(capability)
        case .unqualified: throw CaptureIntegrationError.unqualifiedCapability(capability)
        }
    }
}
