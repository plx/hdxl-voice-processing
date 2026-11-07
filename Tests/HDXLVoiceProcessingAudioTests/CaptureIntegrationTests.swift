import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio
import Testing

@MainActor
private final class CaptureHostDouble: CaptureCapabilityProviding,
    MicrophoneAuthorizationProviding, CaptureConfigurationNegotiating
{
    var calls: [String] = []
    var capabilities: [AudioCapability: AudioCapabilityAvailability] = [:]
    var authorization: MicrophoneAuthorization = .authorized
    var input: CaptureInputAvailability = .available
    var decision: CaptureConfigurationDecision = .accepted
    var requests: [CaptureRequest] = []

    func availability(of capability: AudioCapability) -> AudioCapabilityAvailability {
        calls.append(capability.rawValue)
        return capabilities[capability] ?? .available
    }
    func inputAvailability() -> CaptureInputAvailability {
        calls.append("input")
        return input
    }
    func microphoneAuthorization() -> MicrophoneAuthorization {
        calls.append("authorization")
        return authorization
    }
    func evaluate(_ request: CaptureRequest) -> CaptureConfigurationDecision {
        calls.append("configuration")
        requests.append(request)
        return decision
    }
    func preflight() -> CapturePreflight {
        CapturePreflight(capabilities: self, authorization: self, configuration: self)
    }
}

private func captureRequest(
    ownership: CaptureSessionOwnership = .hostManaged,
    execution: CaptureExecutionRequest = .foreground
) throws -> CaptureRequest {
    try CaptureRequest(
        channelSelection: .init(channelIndex: 0), processing: .measurement,
        sessionOwnership: ownership, execution: execution)
}

@Test @MainActor func captureConstructionDoesNotInspectHostOrSystem() throws {
    let host = CaptureHostDouble()
    host.authorization = .undetermined
    _ = host.preflight()
    _ = SystemMicrophoneAuthorization()
    _ = try captureRequest()
    #expect(host.calls.isEmpty)
    #expect(host.requests.isEmpty)
}

@Test @MainActor func capturePreflightPreservesHostManagedSessionAndRechecksState() throws {
    let host = CaptureHostDouble()
    // macOS can capture without a shared-session capability.
    host.capabilities[.sessionConfiguration] = .unsupported
    let preflight = host.preflight()
    let request = try captureRequest()
    try preflight.check(request)
    #expect(host.calls == ["liveCapture", "authorization", "input", "configuration"])
    #expect(host.requests == [request])
    #expect(host.requests[0].sessionOwnership == .hostManaged)
    host.authorization = .denied
    host.calls.removeAll()
    #expect(throws: CaptureIntegrationError.permissionDenied) { try preflight.check(request) }
    #expect(host.calls == ["liveCapture", "authorization"])
    #expect(host.requests.count == 1)
}

@Test @MainActor func capturePreflightAuthorizationFailuresNeverNegotiate() throws {
    let cases: [(MicrophoneAuthorization, CaptureIntegrationError)] = [
        (.denied, .permissionDenied), (.restricted, .permissionRestricted),
        (.undetermined, .permissionUndetermined), (.unavailable, .authorizationUnavailable),
    ]
    for (authorization, error) in cases {
        let host = CaptureHostDouble()
        host.authorization = authorization
        let request = try captureRequest()
        #expect(throws: error) { try host.preflight().check(request) }
        #expect(host.calls == ["liveCapture", "authorization"])
        #expect(host.requests.isEmpty)
    }
}

@Test @MainActor func capturePreflightCapabilityFailuresAreTypedAndEarly() throws {
    let cases: [(AudioCapabilityAvailability, CaptureIntegrationError)] = [
        (.unsupported, .unsupportedCapability(.liveCapture)),
        (.unavailable, .unavailableCapability(.liveCapture)),
        (.unqualified, .unqualifiedCapability(.liveCapture)),
    ]
    for (availability, error) in cases {
        let host = CaptureHostDouble()
        host.capabilities[.liveCapture] = availability
        let request = try captureRequest()
        #expect(throws: error) { try host.preflight().check(request) }
        #expect(host.calls == ["liveCapture"])
    }
    let host = CaptureHostDouble()
    host.capabilities[.backgroundExecution] = .unqualified
    let background = try captureRequest(execution: .background)
    #expect(throws: CaptureIntegrationError.unqualifiedCapability(.backgroundExecution)) {
        try host.preflight().check(background)
    }
    #expect(host.calls == ["liveCapture", "backgroundExecution"])
}

@Test @MainActor func capturePreflightUnavailableAndUnknownInputsRemainDistinct() throws {
    for (input, error): (CaptureInputAvailability, CaptureIntegrationError) in [
        (.unavailable, .inputUnavailable), (.unknown, .inputUnknown),
    ] {
        let host = CaptureHostDouble()
        host.input = input
        let request = try captureRequest()
        #expect(throws: error) { try host.preflight().check(request) }
        #expect(host.calls == ["liveCapture", "authorization", "input"])
        #expect(host.requests.isEmpty)
    }
}

@Test @MainActor func capturePreflightNegotiatesDelegationWithoutExpandingPermission() throws {
    for activates in [false, true] {
        for deactivates in [false, true] {
            let host = CaptureHostDouble()
            let ownership = CaptureSessionOwnership.delegated(
                .init(permitsActivation: activates, permitsDeactivation: deactivates))
            let request = try captureRequest(ownership: ownership)
            try host.preflight().check(request)
            #expect(host.requests == [request])
            #expect(host.requests[0].sessionOwnership == ownership)
            #expect(
                host.calls == [
                    "liveCapture", "sessionConfiguration", "authorization", "input",
                    "configuration",
                ])
        }
    }
    let host = CaptureHostDouble()
    host.capabilities[.sessionConfiguration] = .unsupported
    let delegated = try captureRequest(
        ownership: .delegated(.init(permitsActivation: true, permitsDeactivation: false)))
    #expect(throws: CaptureIntegrationError.unsupportedCapability(.sessionConfiguration)) {
        try host.preflight().check(delegated)
    }
    #expect(host.calls == ["liveCapture", "sessionConfiguration"])
}

@Test @MainActor func capturePreflightReportsSessionConflictsWithoutRetryOrSubstitution() throws {
    let conflicts: [CaptureConfigurationConflict] = [
        .sessionInUse, .inactiveSession, .incompatibleFormat, .incompatibleProcessing,
        .delegationRequired, .unsupportedConfiguration,
    ]
    for conflict in conflicts {
        let host = CaptureHostDouble()
        host.decision = .conflict(conflict)
        let request = try captureRequest()
        #expect(throws: CaptureIntegrationError.configurationConflict(conflict)) {
            try host.preflight().check(request)
        }
        #expect(host.requests == [request])
        #expect(host.calls == ["liveCapture", "authorization", "input", "configuration"])
    }
}

@Test func captureObservationsPreservePreferencesAndUnknownProcessing() throws {
    let preferred = try PCMFormat(sampleRate: 48_000, channelCount: 2)
    let actual = try PCMFormat(sampleRate: 44_100, channelCount: 1, layout: .planar)
    let request = try CaptureRequest(
        preferredFormat: preferred, channelSelection: .arithmeticMean, processing: .measurement)
    let epoch = StreamEpoch(streamID: UUID(), sequence: 3)
    let observation = try CaptureConfigurationObservation(
        epoch: epoch, request: request, effectiveFormat: actual,
        input: .init(routeIdentifier: .observed("test-route")),
        processing: .init(
            sessionMode: .observed("measurement"), engineVoiceProcessing: .observed(false)))
    #expect(observation.epoch == epoch)
    #expect(observation.request.preferredFormat == preferred)
    #expect(observation.effectiveFormat == actual)
    #expect(observation.channelSelection == .arithmeticMean)
    #expect(observation.input.deviceIdentifier == .unknown)
    #expect(observation.input.routeIdentifier == .observed("test-route"))
    #expect(observation.processing.engineVoiceProcessing == .observed(false))
    #expect(observation.processing.automaticGainControl == .unknown)
    #expect(observation.processing.noiseSuppression == .unknown)
    #expect(observation.processing.echoCancellation == .unknown)
}

@Test func captureConfigurationRejectsInvalidChannelAndMetadataValues() throws {
    let mono = try PCMFormat(sampleRate: 48_000, channelCount: 1)
    let stereo = try PCMFormat(sampleRate: 48_000, channelCount: 2)
    #expect(throws: CaptureIntegrationError.invalidConfiguration) {
        try CaptureRequest(
            preferredFormat: mono, channelSelection: .init(channelIndex: 1),
            processing: .observeHostConfiguration)
    }
    let request = try CaptureRequest(
        preferredFormat: stereo, channelSelection: .init(channelIndex: 1), processing: .measurement)
    #expect(throws: CaptureIntegrationError.configurationConflict(.incompatibleFormat)) {
        try CaptureConfigurationObservation(
            epoch: .init(streamID: UUID()), request: request, effectiveFormat: mono,
            input: .init(), processing: .init())
    }
    for text in ["", "test\0route", String(repeating: "é", count: 513)] {
        #expect(throws: CaptureIntegrationError.invalidConfiguration) {
            try CaptureInputIdentity(deviceIdentifier: .observed(text))
        }
        #expect(throws: CaptureIntegrationError.invalidConfiguration) {
            try CaptureInputIdentity(routeIdentifier: .observed(text))
        }
        #expect(throws: CaptureIntegrationError.invalidConfiguration) {
            try CaptureProcessingObservation(sessionMode: .observed(text))
        }
    }
    let limit = String(repeating: "é", count: 512)
    #expect(
        try CaptureInputIdentity(deviceIdentifier: .observed(limit)).deviceIdentifier
            == .observed(limit))
    #expect(
        try CaptureProcessingObservation(sessionMode: .observed(limit)).sessionMode
            == .observed(limit))
}
