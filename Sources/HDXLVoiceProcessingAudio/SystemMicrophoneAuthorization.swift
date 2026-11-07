#if os(macOS)
    import AVFoundation
#elseif os(iOS) && !targetEnvironment(macCatalyst)
    import AVFAudio
#endif

/// Read-only platform authorization bridge. Neither construction nor import queries
/// the system. There is deliberately no permission-request method in this provider.
@MainActor public struct SystemMicrophoneAuthorization: MicrophoneAuthorizationProviding {
    public init() {}

    public func microphoneAuthorization() -> MicrophoneAuthorization {
        #if os(macOS)
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .undetermined
            @unknown default: return .unavailable
            }
        #elseif os(iOS) && !targetEnvironment(macCatalyst)
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .authorized
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .unavailable
            }
        #else
            // Other platforms, including watchOS, remain unqualified pending #60.
            return .unavailable
        #endif
    }
}
