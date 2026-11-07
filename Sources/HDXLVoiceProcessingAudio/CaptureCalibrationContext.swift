import HDXLVoiceProcessing

public enum CaptureCalibrationField: String, Sendable, Hashable, CaseIterable {
    case format, channelSelection, device, route, sessionMode, engineVoiceProcessing
    case automaticGainControl, noiseSuppression, echoCancellation
}

/// Comparison of acquisition metadata only, not a certification of a calibration
/// model, acoustic environment, microphone distance, or scoring validity.
public enum CaptureCalibrationComparison: Sendable, Hashable {
    case observedFieldsMatch
    case indeterminate(unknownFields: [CaptureCalibrationField])
    case incompatible(
        changedFields: [CaptureCalibrationField], unknownFields: [CaptureCalibrationField])
}

/// Immutable conditions bound by the host when it selects calibration data.
/// Comparing a new observation never modifies the original calibration.
public struct CaptureCalibrationContext: Sendable, Hashable {
    public let format: PCMFormat
    public let channelSelection: PCMChannelSelection
    public let input: CaptureInputIdentity
    public let processing: CaptureProcessingObservation

    public init(observation: CaptureConfigurationObservation) {
        format = observation.effectiveFormat
        channelSelection = observation.channelSelection
        input = observation.input
        processing = observation.processing
    }

    public func compare(with observation: CaptureConfigurationObservation)
        -> CaptureCalibrationComparison
    {
        var changed: [CaptureCalibrationField] = []
        var unknown: [CaptureCalibrationField] = []
        if format != observation.effectiveFormat { changed.append(.format) }
        if channelSelection != observation.channelSelection { changed.append(.channelSelection) }
        func compare<Value>(
            _ field: CaptureCalibrationField, _ expected: CaptureObservation<Value>,
            _ actual: CaptureObservation<Value>
        ) {
            switch (expected, actual) {
            case (.observed(let left), .observed(let right)):
                if left != right { changed.append(field) }
            default: unknown.append(field)
            }
        }
        compare(.device, input.deviceIdentifier, observation.input.deviceIdentifier)
        compare(.route, input.routeIdentifier, observation.input.routeIdentifier)
        compare(.sessionMode, processing.sessionMode, observation.processing.sessionMode)
        compare(
            .engineVoiceProcessing, processing.engineVoiceProcessing,
            observation.processing.engineVoiceProcessing)
        compare(
            .automaticGainControl, processing.automaticGainControl,
            observation.processing.automaticGainControl)
        compare(
            .noiseSuppression, processing.noiseSuppression, observation.processing.noiseSuppression)
        compare(
            .echoCancellation, processing.echoCancellation, observation.processing.echoCancellation)
        if !changed.isEmpty { return .incompatible(changedFields: changed, unknownFields: unknown) }
        return unknown.isEmpty ? .observedFieldsMatch : .indeterminate(unknownFields: unknown)
    }
}
