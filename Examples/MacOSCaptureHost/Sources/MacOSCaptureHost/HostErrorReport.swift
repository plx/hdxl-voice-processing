import Foundation
import HDXLVoiceProcessingAudio

/// Recovery objects may contain device IDs or file paths. Render only an allowlist
/// of categories and numeric codes; never interpolate an arbitrary Error/domain.
enum HostErrorReport {
    static func message(for error: any Error) -> String {
        guard let capture = error as? MacOSCaptureFailure else { return "operation failed" }
        switch capture.reason {
        case .alreadyRunning: return "capture already running"
        case .configurationChanged: return "input configuration changed"
        case .preparation: return "capture preparation failed"
        case .integration: return "capture permission or configuration rejected"
        case .tapInstallation(_, let code): return "tap installation failed (code \(code))"
        case .engineStart(_, let code): return "engine start failed (code \(code))"
        case .callback: return "capture callback failed"
        }
    }
}
