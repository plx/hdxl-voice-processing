import Foundation
import HDXLVoiceProcessing

/// The host's explicit statement about its shared session before capture begins.
/// AVAudioSession does not provide a public active-state query. A nonzero sample
/// rate is not evidence of activation, and an unknown state cannot authorize use.
public enum IOSCaptureHostActivity: Sendable, Hashable {
    case active, inactive, unknown
}

/// A cooperative, single-operation agreement with the host's session owner.
/// This never changes AVAudioSession or supplies implicit exclusive ownership.
/// Invalidate and await the capture owner's finish before another feature changes
/// or reuses the session. Keep that agreement through suspended activation/teardown.
@MainActor public final class IOSCaptureHostLease {
    public let activity: IOSCaptureHostActivity
    public private(set) var isValid = true
    private var claimed = false

    public init(activity: IOSCaptureHostActivity) { self.activity = activity }
    public func invalidate() { isValid = false }

    func claim() -> Bool {
        guard isValid, !claimed else { return false }
        claimed = true
        return true
    }
}

/// Obtain from the capture owner before awaiting a host-owned permission action.
/// Owner identity and generation prevent reuse or a late response reviving capture.
public struct IOSCaptureStartIntent: Sendable, Hashable {
    let owner: UUID
    let generation: UUID
}

public enum IOSCaptureStage: String, Sendable, Hashable {
    case sessionConfiguration, activation, engineConfiguration, tapInstallation, engineStart,
        deactivation
}

public enum IOSCaptureChange: Sendable, Hashable {
    case route(reason: UInt?)
    case systemInterruption(reason: Int?)
    case hostDeactivatedSession, mediaServicesLost, mediaServicesReset
    case engineConfiguration, sessionConfiguration, hostLeaseInvalidated, enteredBackground
}

public enum IOSCaptureFailureReason: Sendable, Hashable {
    case integration(CaptureIntegrationError)
    case alreadyRunning, cancelled, invalidStartIntent, invalidHostLease, unknownSessionActivity
    case activationRejected, deactivationRejected
    case system(stage: IOSCaptureStage, code: Int)
    case configurationChanged(IOSCaptureChange)
    case preparation
    #if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
        case callback(CaptureTapFailure)
    #endif
}

/// Recovery context remains local. Neither the adapter nor a development host
/// should print this value wholesale: its observation may contain private route IDs.
public struct IOSCaptureFailure: Error, Sendable, Hashable {
    public let reason: IOSCaptureFailureReason
    public let request: CaptureRequest
    public let observation: IOSCaptureObservation?
}

/// Effective session state read after activation. Native tap format is retained
/// separately because AVAudioEngine's client format and session hardware differ.
public struct IOSAudioSessionObservation: Sendable, Hashable {
    public let category: String
    public let mode: String
    public let categoryOptions: UInt
    public let sampleRate: Double
    public let ioBufferDuration: Double
    /// The specific AVAudioSession echo-cancelled-input feature, not a statement
    /// about every route/device/engine echo-cancellation stage.
    public let echoCancelledInputEnabled: CaptureObservation<Bool>

    public init(
        category: String, mode: String, categoryOptions: UInt,
        sampleRate: Double, ioBufferDuration: Double,
        echoCancelledInputEnabled: CaptureObservation<Bool> = .unknown
    ) throws {
        guard
            [category, mode].allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0")
            }),
            sampleRate.isFinite, sampleRate > 0, ioBufferDuration.isFinite, ioBufferDuration > 0
        else { throw CaptureIntegrationError.invalidConfiguration }
        self.category = category
        self.mode = mode
        self.categoryOptions = categoryOptions
        self.sampleRate = sampleRate
        self.ioBufferDuration = ioBufferDuration
        self.echoCancelledInputEnabled = echoCancelledInputEnabled
    }
}

public struct IOSCaptureObservation: Sendable, Hashable {
    public let capture: CaptureConfigurationObservation
    public let audioSession: IOSAudioSessionObservation
}

public struct IOSCaptureSession: Sendable {
    public let observation: IOSCaptureObservation
    public let transfer: PCMTransfer

    public func makeSchedule<Sample: BinaryFloatingPoint & Sendable>(
        profile: AnalysisScheduleProfile, sourceTileCapacity: Int = 256
    ) throws -> PreparedPCMTransferSchedule<Sample> {
        let capture = observation.capture
        guard profile.channels == capture.channelSelection else {
            throw AnalysisScheduleError.invalidConfiguration
        }
        let origin = try AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: capture.epoch, startSample: 0, sampleCount: 0,
                sampleRate: capture.effectiveFormat.sampleRate),
            continuityEpoch: capture.epoch)
        return try PreparedPCMTransferSchedule(
            transfer: transfer, profile: profile,
            origin: origin, sourceTileCapacity: sourceTileCapacity)
    }
}

/// Describes a requested session side effect; it does not infer a global active
/// state when the adapter did not perform deactivation.
public enum IOSCaptureSessionDisposition: Sendable, Hashable {
    case notActivatedByAdapter, deactivationNotPermitted, ownershipChanged
    case configurationChanged, systemAlreadyInactive, deactivated, deactivationFailed
}

public enum IOSCaptureEvent: Sendable {
    case started(IOSCaptureSession)
    case stopped(IOSCaptureObservation, SourceDiscontinuity)
    /// Missing sample extent stays unknown. A later start observes a new configuration.
    case configurationChanged(IOSCaptureObservation?, IOSCaptureChange, SourceDiscontinuity?)
    case calibrationConfiguration(IOSCaptureObservation, CaptureCalibrationComparison)
    case calibrationInvalidated(IOSCaptureObservation, IOSCaptureChange)
    /// Informational only; capture never resumes itself in response.
    case resumptionRecommended(Bool?)
    case sessionBecameActive
    case sessionDisposition(IOSCaptureSessionDisposition)
    case failed(IOSCaptureFailure)
}
