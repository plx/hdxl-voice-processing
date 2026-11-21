import HDXLVoiceProcessing

/// At most one complete native result for each scheduled algorithm. Updating levels
/// cannot erase a current unavailable pitch or CPPS result. These are measurements,
/// not raw audio; their original support, validity and provenance remain intact.
public struct CaptureResultFrames: Sendable, Hashable {
    public internal(set) var levels: PCMTransferScheduledFrame?
    public internal(set) var pitch: PCMTransferScheduledFrame?
    public internal(set) var cpps: PCMTransferScheduledFrame?
    public internal(set) var hnr: PCMTransferScheduledFrame?
    public internal(set) var swipePrime: PCMTransferScheduledFrame?

    mutating func accept(_ value: PCMTransferScheduledFrame) {
        switch value.frame.algorithm {
        case .levels: levels = value
        case .yin: pitch = value
        case .cpps: cpps = value
        case .hnr: hnr = value
        case .swipePrime: swipePrime = value
        }
    }
}

/// Cumulative gap evidence within this capture operation. Known missing frames are
/// the sum of reported gap extents, never overlapping analysis-window support.
/// A gap of unknown extent remains visible even after new valid results arrive.
public struct CaptureResultLoss: Sendable, Equatable {
    public internal(set) var gapEvents: UInt64 = 0
    public internal(set) var knownMissingFrames: UInt64 = 0
    public internal(set) var unknownExtentGaps: UInt64 = 0
    public internal(set) var latestGap: PCMTransferGap?

    mutating func accept(_ gap: PCMTransferGap) {
        gapEvents = captureDeliveryAdd(gapEvents)
        if let missing = gap.missingSource {
            knownMissingFrames = captureDeliveryAdd(
                knownMissingFrames, UInt64(max(0, missing.frameCount)))
        } else {
            unknownExtentGaps = captureDeliveryAdd(unknownExtentGaps)
        }
        latestGap = gap
    }
}

/// A bounded current-state snapshot, plus the exact event that produced it. Newest
/// delivery can skip events, but cannot erase persistent gap, calibration or failure
/// state. Strict subscribers receive the event sequence or an explicit overflow.
/// Configuration may include host-private route metadata; no automatic logging or
/// diagnostic export serializes it. Delivery timestamps are in ResultDelivery.
public struct CaptureResultSnapshot: Sendable {
    public internal(set) var event: CaptureLifecycleEvent = .state(.idle, epoch: nil)
    public internal(set) var state: CaptureLifecycleState = .idle
    public internal(set) var configuration: CaptureLifecycleConfiguration?
    public internal(set) var frames = CaptureResultFrames()
    public internal(set) var loss = CaptureResultLoss()
    public internal(set) var resetCount: UInt64 = 0
    public internal(set) var latestReset: AnalysisScheduleReset?
    public internal(set) var latestDiscontinuity: SourceDiscontinuity?
    public internal(set) var latestRegionCompletion: AnalysisScheduleCompletion?
    public internal(set) var calibrationComparison: CaptureCalibrationComparison?
    public internal(set) var calibrationRevalidation: CaptureLifecycleChange?
    public internal(set) var sessionDisposition: IOSCaptureSessionDisposition?
    public internal(set) var completion: CaptureLifecycleCompletion?
    public internal(set) var runtime = CaptureRuntimeDiagnostics(mode: .disabled)

    /// False means no reported acquisition loss, not proof of healthy capture.
    /// Final transport counters include loss that stop prevented the worker from
    /// announcing as a gap. Display coalescing never contributes to this property.
    public var hasReportedAcquisitionLoss: Bool {
        if loss.gapEvents > 0 { return true }
        guard let capture = runtime.capture else { return false }
        return capture.droppedFrames > 0 || capture.overflowChunks > 0
            || capture.oversizedChunks > 0 || capture.invalidChunks > 0
            || capture.producerContractViolated
    }
}

@inline(__always)
func captureDeliveryAdd(_ value: UInt64, _ increment: UInt64 = 1) -> UInt64 {
    let (sum, overflow) = value.addingReportingOverflow(increment)
    return overflow ? .max : sum
}

#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    @MainActor final class CaptureResultDelivery {
        static let maximumSubscribers = 16
        private var publisher: BoundedResultPublisher<CaptureResultSnapshot>
        private let mode: RuntimeDiagnosticMode
        private(set) var snapshot = CaptureResultSnapshot()
        private var finished = false

        init(mode: RuntimeDiagnosticMode = .disabled) {
            self.mode = mode
            publisher = Self.makePublisher(mode: mode)
            snapshot.runtime = CaptureRuntimeDiagnostics(mode: mode)
        }

        private static func makePublisher(mode: RuntimeDiagnosticMode)
            -> BoundedResultPublisher<CaptureResultSnapshot>
        {
            // The private constant is within the publisher's validated 1...64 range.
            try! BoundedResultPublisher(
                maximumSubscribers: maximumSubscribers, replayLatest: true, diagnostics: mode)
        }

        func beginOperation() {
            guard finished else { return }
            publisher = Self.makePublisher(mode: mode)
            snapshot = CaptureResultSnapshot()
            snapshot.runtime = CaptureRuntimeDiagnostics(mode: mode)
            finished = false
        }

        func subscribe(_ policy: ResultDeliveryPolicy) throws
            -> ResultSubscription<CaptureResultSnapshot>
        {
            try publisher.subscribe(policy)
        }

        var activeSubscriberCount: Int { publisher.activeSubscriberCount }

        func observe(_ observation: CaptureWorkerObservation, publicationTime: UInt64?) {
            snapshot.runtime.accept(observation, publicationTime: publicationTime)
        }

        func observeFinalCapture(_ capture: PCMTransferSnapshot) {
            snapshot.runtime.capture = capture
        }

        func accept(_ event: CaptureLifecycleEvent) {
            guard !finished else { return }
            snapshot.event = event
            switch event {
            case .state(let state, _):
                snapshot.state = state
                if state != .running { snapshot.frames = CaptureResultFrames() }
            case .configured(let configuration):
                snapshot.configuration = configuration
                snapshot.state = .running
                snapshot.frames = CaptureResultFrames()
            case .analysis(let event):
                switch event {
                case .frame(let frame): snapshot.frames.accept(frame)
                case .gap(let gap):
                    snapshot.loss.accept(gap)
                    snapshot.frames = CaptureResultFrames()
                case .reset(let reset):
                    snapshot.resetCount = captureDeliveryAdd(snapshot.resetCount)
                    snapshot.latestReset = reset
                    snapshot.frames = CaptureResultFrames()
                case .regionCompleted(let completion):
                    snapshot.latestRegionCompletion = completion
                }
            case .discontinuity(let boundary):
                snapshot.latestDiscontinuity = boundary
                snapshot.frames = CaptureResultFrames()
            case .calibrationConfiguration(let comparison):
                snapshot.calibrationComparison = comparison
            case .calibrationRevalidationRequired(_, let change):
                snapshot.calibrationRevalidation = change
            case .sessionDisposition(let disposition): snapshot.sessionDisposition = disposition
            case .completed(let completion):
                snapshot.completion = completion
                snapshot.frames = CaptureResultFrames()
            }
            publisher.publish(snapshot)
            if case .completed(let completion) = event {
                finished = true
                publisher.finish(
                    completion.failures.isEmpty ? .finished : .failed(.upstreamFailure))
            }
        }

        func ownerReleased() {
            finished = true
            publisher.finish(.failed(.publisherReleased))
        }
    }
#endif
