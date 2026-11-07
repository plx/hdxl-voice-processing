import Foundation
import HDXLVoiceProcessingAudio

/// Render an allowlist, never an arbitrary error description, route ID or domain.
enum HostErrorReport {
    static func message(for error: any Error) -> String {
        if error is CancellationError { return "Stopped." }
        if let integration = error as? CaptureIntegrationError {
            switch integration {
            case .permissionDenied:
                return "Microphone permission was denied. Review access in Settings."
            case .permissionRestricted: return "Microphone access is restricted."
            case .permissionUndetermined: return "Microphone permission has not been granted."
            case .authorizationUnavailable: return "Microphone authorization is unavailable."
            case .inputUnavailable, .inputUnknown:
                return "A usable microphone input is unavailable."
            default: return "The requested capture configuration is unavailable."
            }
        }
        guard let failure = error as? IOSCaptureFailure else { return "Operation failed." }
        switch failure.reason {
        case .cancelled, .invalidStartIntent: return "Stopped before capture started."
        case .alreadyRunning: return "Capture is already running."
        case .invalidHostLease, .unknownSessionActivity: return "Audio session ownership changed."
        case .integration(let integration): return message(for: integration)
        case .activationRejected: return "Audio session activation was rejected."
        case .deactivationRejected: return "Audio session deactivation was rejected."
        case .configurationChanged: return "Input configuration changed. Start a new capture."
        case .system(let stage, let code): return "\(stage.rawValue) failed (code \(code))."
        case .preparation: return "Capture preparation failed."
        case .callback: return "Capture callback failed."
        }
    }
}
