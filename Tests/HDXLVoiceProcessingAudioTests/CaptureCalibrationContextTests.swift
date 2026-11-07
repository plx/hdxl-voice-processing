import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio
import Testing

private func calibrationCaptureObservation(
    route: String? = "route-a", device: String? = "input-a", mode: String? = "measurement",
    rate: Double = 48000, channel: Int = 0, preferredRate: Double? = nil,
    gain: CaptureObservation<Bool> = .observed(false),
    echo: CaptureObservation<Bool> = .observed(false)
) throws -> CaptureConfigurationObservation {
    try CaptureConfigurationObservation(
        epoch: StreamEpoch(streamID: UUID()),
        request: CaptureRequest(
            preferredFormat: preferredRate.map { try PCMFormat(sampleRate: $0, channelCount: 2) },
            channelSelection: PCMChannelSelection(channelIndex: channel), processing: .measurement),
        effectiveFormat: PCMFormat(sampleRate: rate, channelCount: 2),
        input: CaptureInputIdentity(
            deviceIdentifier: device.map { .observed($0) } ?? .unknown,
            routeIdentifier: route.map { .observed($0) } ?? .unknown),
        processing: CaptureProcessingObservation(
            sessionMode: mode.map { .observed($0) } ?? .unknown,
            engineVoiceProcessing: .observed(false), automaticGainControl: gain,
            noiseSuppression: .observed(false), echoCancellation: echo))
}

@Test func calibrationCaptureComparesEffectiveConditionsAcrossEpochs() throws {
    let first = try calibrationCaptureObservation(preferredRate: 44100)
    let next = try calibrationCaptureObservation(preferredRate: 96000)
    #expect(first.epoch != next.epoch)
    let context = CaptureCalibrationContext(observation: first)
    #expect(context.compare(with: next) == .observedFieldsMatch)
}

@Test func calibrationCaptureUnknownConditionsNeverProveCompatibility() throws {
    let unknown = try calibrationCaptureObservation(route: nil, gain: .unknown)
    let context = CaptureCalibrationContext(observation: unknown)
    #expect(
        context.compare(with: unknown)
            == .indeterminate(unknownFields: [.route, .automaticGainControl]))
    let known = try calibrationCaptureObservation()
    #expect(
        context.compare(with: known)
            == .indeterminate(unknownFields: [.route, .automaticGainControl]))
    #expect(
        CaptureCalibrationContext(observation: known).compare(with: unknown)
            == .indeterminate(unknownFields: [.route, .automaticGainControl]))
}

@Test func calibrationCaptureReportsRouteAndProcessingMismatchEvenWithUnknownFields() throws {
    let reference = CaptureCalibrationContext(observation: try calibrationCaptureObservation())
    let changed = try calibrationCaptureObservation(
        route: "route-b", mode: "voiceChat", gain: .unknown,
        echo: .observed(true))
    #expect(
        reference.compare(with: changed)
            == .incompatible(
                changedFields: [.route, .sessionMode, .echoCancellation],
                unknownFields: [.automaticGainControl]))
}

@Test func calibrationCaptureDistinguishesDeviceChannelAndNativeFormatChanges() throws {
    let reference = CaptureCalibrationContext(observation: try calibrationCaptureObservation())
    let changed = try calibrationCaptureObservation(device: "input-b", rate: 44100, channel: 1)
    #expect(
        reference.compare(with: changed)
            == .incompatible(
                changedFields: [.format, .channelSelection, .device], unknownFields: []))
}
