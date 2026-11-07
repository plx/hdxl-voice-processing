#if os(macOS)
    import AVFAudio
    import AudioToolbox
    import CoreAudio
    import Foundation
    import HDXLVoiceProcessing

    /// Owned by the main actor. Created only after the host's permission has been checked.
    @MainActor final class SystemMacOSCaptureEngine: MacOSCaptureEngine {
        private let engine = AVAudioEngine()
        private var nativeFormat: AVAudioFormat?
        private var observer: (any NSObjectProtocol)?
        private var installed = false

        func configure(request: CaptureRequest) throws -> MacOSCaptureEngineConfiguration {
            let input = engine.inputNode
            let hardware = input.inputFormat(forBus: 0)
            guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0
            else {
                throw CaptureIntegrationError.inputUnavailable
            }
            if request.processing == .measurement, input.isVoiceProcessingEnabled {
                try input.setVoiceProcessingEnabled(false)
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0,
                (1...32).contains(format.channelCount),
                format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64
            else { throw CaptureIntegrationError.configurationConflict(.incompatibleFormat) }
            // Preferences are recorded, never passed as an invented hardware/tap format.
            nativeFormat = format
            return try MacOSCaptureEngineConfiguration(
                format: PCMFormat(
                    sampleRate: format.sampleRate, channelCount: Int(format.channelCount),
                    encoding: format.commonFormat == .pcmFormatFloat32 ? .float32 : .float64,
                    layout: format.isInterleaved ? .interleaved : .planar),
                input: identity(input),
                processing: CaptureProcessingObservation(
                    engineVoiceProcessing: .observed(input.isVoiceProcessingEnabled)))
        }

        func observeConfigurationChanges(_ handler: @escaping @MainActor @Sendable () -> Void) {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { _ in
                // Never stop/remove/deallocate the engine on its internal notification queue.
                Task { @MainActor in handler() }
            }
        }

        func installTap(_ tap: PreparedCaptureTap, requestedFrames: UInt32) throws {
            guard let nativeFormat else { throw CaptureIntegrationError.invalidConfiguration }
            try engine.inputNode.installAudioTap(
                onBus: 0, bufferSize: requestedFrames, format: nativeFormat
            ) {
                buffer, time in tap.accept(buffer, at: time)
            }
            installed = true
        }

        func start() throws { try engine.start() }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.stop()
            if installed { engine.inputNode.removeTap(onBus: 0) }
            installed = false
            nativeFormat = nil
        }

        private func identity(_ input: AVAudioInputNode) throws -> CaptureInputIdentity {
            var identifier: String?
            input.withAudioUnit { unit in
                guard let unit else { return }
                var device = AudioDeviceID(kAudioObjectUnknown)
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                guard
                    AudioUnitGetProperty(
                        unit, kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global, 0, &device, &size) == noErr,
                    device != kAudioObjectUnknown
                else { return }
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceUID,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                var value: Unmanaged<CFString>?
                size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
                    let value
                else { return }
                // Core Audio transfers ownership of this property value to the caller.
                identifier = value.takeRetainedValue() as String
            }
            return try CaptureInputIdentity(
                deviceIdentifier: identifier.map { .observed($0) } ?? .unknown)
        }
    }
#endif
