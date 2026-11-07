import Foundation
import HDXLVoiceProcessing

/// Unknown is distinct from false, absent processing, and an assumed default.
public enum CaptureObservation<Value: Sendable & Hashable>: Sendable, Hashable {
    case unknown
    case observed(Value)
}

/// Device/route identifiers can be sensitive and must not be exported implicitly.
/// Stream identity is carried separately by the effective configuration's epoch.
public struct CaptureInputIdentity: Sendable, Hashable {
    public let deviceIdentifier: CaptureObservation<String>
    public let routeIdentifier: CaptureObservation<String>

    public init(
        deviceIdentifier: CaptureObservation<String> = .unknown,
        routeIdentifier: CaptureObservation<String> = .unknown
    ) throws {
        for value in [deviceIdentifier, routeIdentifier] {
            if case .observed(let text) = value,
                text.isEmpty || text.utf8.count > 1024 || text.contains("\0")
            {
                throw CaptureIntegrationError.invalidConfiguration
            }
        }
        self.deviceIdentifier = deviceIdentifier
        self.routeIdentifier = routeIdentifier
    }
}

/// These are observations, not claims about the complete microphone/DSP signal path.
/// A measurement mode or disabled engine voice processing never proves raw samples.
public struct CaptureProcessingObservation: Sendable, Hashable {
    public let sessionMode: CaptureObservation<String>
    public let engineVoiceProcessing: CaptureObservation<Bool>
    public let automaticGainControl: CaptureObservation<Bool>
    public let noiseSuppression: CaptureObservation<Bool>
    public let echoCancellation: CaptureObservation<Bool>

    public init(
        sessionMode: CaptureObservation<String> = .unknown,
        engineVoiceProcessing: CaptureObservation<Bool> = .unknown,
        automaticGainControl: CaptureObservation<Bool> = .unknown,
        noiseSuppression: CaptureObservation<Bool> = .unknown,
        echoCancellation: CaptureObservation<Bool> = .unknown
    ) throws {
        if case .observed(let text) = sessionMode,
            text.isEmpty || text.utf8.count > 1024 || text.contains("\0")
        {
            throw CaptureIntegrationError.invalidConfiguration
        }
        self.sessionMode = sessionMode
        self.engineVoiceProcessing = engineVoiceProcessing
        self.automaticGainControl = automaticGainControl
        self.noiseSuppression = noiseSuppression
        self.echoCancellation = echoCancellation
    }
}

/// Immutable metadata captured after configuration, outside the real-time callback.
/// New format/route/processing conditions require a new epoch (#43). This value
/// preserves preferences even when hardware supplies a different rate or layout.
/// It is descriptive; construction does not certify processing-policy conformance.
public struct CaptureConfigurationObservation: Sendable, Hashable {
    public let epoch: StreamEpoch
    public let request: CaptureRequest
    public let effectiveFormat: PCMFormat
    public let input: CaptureInputIdentity
    public let processing: CaptureProcessingObservation
    public var channelSelection: PCMChannelSelection { request.channelSelection }

    public init(
        epoch: StreamEpoch, request: CaptureRequest, effectiveFormat: PCMFormat,
        input: CaptureInputIdentity, processing: CaptureProcessingObservation
    ) throws {
        if let index = request.channelSelection.channelIndex, index >= effectiveFormat.channelCount
        {
            throw CaptureIntegrationError.configurationConflict(.incompatibleFormat)
        }
        self.epoch = epoch
        self.request = request
        self.effectiveFormat = effectiveFormat
        self.input = input
        self.processing = processing
    }
}
