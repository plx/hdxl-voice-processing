import Foundation
import HDXLVoiceProcessing

public enum CaptureLifecycleState: String, Sendable, Hashable {
    case idle, permissionPending, configuring, running, interrupted, stopping, stopped, failed
}

/// Obtain before a host-owned permission action. A stop invalidates this single-use token.
public struct CaptureLifecycleStartIntent: Sendable, Hashable {
    let owner: UUID
    let generation: UUID
}

/// An interruption-specific permission to ask for resumption. Explicit stop,
/// reconfiguration, or a newer start invalidates it, including delayed host callbacks.
public struct CaptureLifecycleRecoveryIntent: Sendable, Hashable {
    let owner: UUID
    let generation: UUID
}

public enum CaptureLifecycleChange: String, Sendable, Hashable {
    case route, engineConfiguration, sessionConfiguration, interruption
    case mediaServicesLost, mediaServicesReset, hostOwnership, enteredBackground
    case analysisConfiguration, explicitStop

    var resetReason: ResetReason {
        switch self {
        case .route: .routeChange
        case .engineConfiguration, .sessionConfiguration, .analysisConfiguration: .profileChange
        case .mediaServicesLost, .mediaServicesReset: .explicitReset
        default: .pause
        }
    }
}

public enum CaptureLifecycleStage: String, Sendable, Hashable {
    case command, captureStart, capture, analysisPreparation, analysis, shutdown
}

public enum CaptureLifecycleFailureReason: Sendable, Hashable {
    case invalidStartIntent, conflictingOperation, cancelled, missingHostLease
    case invalidConfiguration, resultCapacityExceeded, unexpectedCaptureEnd
    case capture(CaptureIntegrationError)
    case analysis(AnalysisScheduleError)
    case system(code: Int)
    case ios(IOSCaptureFailureReason)
    #if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
        case callback(CaptureTapFailure)
    #endif
}

public enum CaptureLifecycleRecovery: String, Sendable, Hashable {
    case newHostAction, correctConfiguration, waitForStopCompletion, renewHostLease
}

/// Contains no audio, localized system description, path or device identifier.
public struct CaptureLifecycleFailure: Error, Sendable, Hashable {
    public let stage: CaptureLifecycleStage
    public let reason: CaptureLifecycleFailureReason
    public let epoch: StreamEpoch?
    public let recovery: CaptureLifecycleRecovery

    init(
        stage: CaptureLifecycleStage, reason: CaptureLifecycleFailureReason,
        epoch: StreamEpoch? = nil, recovery: CaptureLifecycleRecovery = .newHostAction
    ) {
        self.stage = stage
        self.reason = reason
        self.epoch = epoch
        self.recovery = recovery
    }
}

/// Preparation runs on the serial analysis worker, using the actual native format.
/// The host explicitly chooses the recipe; no sample-rate or profile fallback is implied.
public typealias CaptureLifecycleAnalysis =
    @Sendable (
        PCMFormat, PCMChannelSelection
    ) throws -> AnalysisScheduleProfile

public struct CaptureLifecycleWorkerLimits: Sendable, Hashable {
    public let maximumResultEvents: Int
    public let sourceTileCapacity: Int

    public init(maximumResultEvents: Int = 256, sourceTileCapacity: Int = 256) throws {
        guard (1...4096).contains(maximumResultEvents), (1...65_536).contains(sourceTileCapacity)
        else { throw AnalysisScheduleError.invalidConfiguration }
        self.maximumResultEvents = maximumResultEvents
        self.sourceTileCapacity = sourceTileCapacity
    }
}

/// Observations may include private route identity; nothing is logged or exported implicitly.
public struct CaptureLifecycleConfiguration: Sendable, Hashable {
    public let capture: CaptureConfigurationObservation
    public let audioSession: IOSAudioSessionObservation?
    public let analysis: AnalysisScheduleProfile
    public let analysisIdentity: ProfileIdentity
    /// Fresh stream identity for this worker; PCM gaps advance its sequence only.
    public let initialAnalysisContinuityEpoch: StreamEpoch
}

/// A stop discards pending analysis, rather than certifying a complete recording.
/// Failures are bounded to the primary failure and one distinct cleanup failure.
public struct CaptureLifecycleCompletion: Sendable, Hashable {
    public let epoch: StreamEpoch?
    public let change: CaptureLifecycleChange
    public let failures: [CaptureLifecycleFailure]
    public let audioSessionDisposition: IOSCaptureSessionDisposition?
    public let recoveryIntent: CaptureLifecycleRecoveryIntent?
}

/// Synchronous main-actor delivery, outside capture. One bounded worker batch is
/// in flight at a time. Host handlers must return promptly and bound retained history.
/// Multi-subscriber delivery/coalescing policies belong to the result delivery layer.
public enum CaptureLifecycleEvent: Sendable {
    case state(CaptureLifecycleState, epoch: StreamEpoch?)
    case configured(CaptureLifecycleConfiguration)
    case analysis(PCMTransferScheduleEvent)
    case discontinuity(SourceDiscontinuity)
    case calibrationConfiguration(CaptureCalibrationComparison)
    case calibrationRevalidationRequired(StreamEpoch, CaptureLifecycleChange)
    case sessionDisposition(IOSCaptureSessionDisposition)
    case completed(CaptureLifecycleCompletion)
}
