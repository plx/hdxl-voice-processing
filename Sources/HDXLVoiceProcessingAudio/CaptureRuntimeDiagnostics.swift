import HDXLVoiceProcessing

/// One successful worker drain, without audio, profile labels or route identifiers.
/// Clock values use monotonic host nanoseconds. Block time is the first source
/// sample's supplied host anchor, not callback entry or queue-enqueue time.
public struct CaptureWorkerObservation: Sendable, Equatable {
    public let capture: PCMTransferSnapshot
    public let deliveredPCMEvents: Int
    public let dequeuedBlocks: Int
    public let consumedSourceFrames: Int64
    public let emittedResults: Int
    public let workerStartedHostNanoseconds: UInt64?
    public let workerFinishedHostNanoseconds: UInt64?
    public let firstBlockHostStartNanoseconds: UInt64?
    public let firstBlockDequeuedHostNanoseconds: UInt64?

    public var processingNanoseconds: UInt64? {
        Self.difference(workerFinishedHostNanoseconds, workerStartedHostNanoseconds)
    }
    public var captureBlockStartToWorkerNanoseconds: UInt64? {
        Self.difference(firstBlockDequeuedHostNanoseconds, firstBlockHostStartNanoseconds)
    }
    static func difference(_ end: UInt64?, _ start: UInt64?) -> UInt64? {
        guard let end, let start, end >= start else { return nil }
        return end - start
    }
}

/// Numeric-only ordinary telemetry. Capture counters are independently sampled,
/// as documented by PCMTransferSnapshot. Optional latency summaries describe work
/// drains; idle polls do not add processing samples. No unbounded history is kept.
public struct CaptureRuntimeDiagnostics: Sendable, Equatable {
    public let mode: RuntimeDiagnosticMode
    public internal(set) var capture: PCMTransferSnapshot?
    public internal(set) var workerTurns: UInt64 = 0
    public internal(set) var latestWorker: CaptureWorkerObservation?
    public internal(set) var captureBlockStartToWorker = RuntimeLatencySummary()
    public internal(set) var processing = RuntimeLatencySummary()
    /// One observation at the first publication of a nonempty result batch.
    public internal(set) var workerToPublication = RuntimeLatencySummary()
    public internal(set) var latestFirstPublicationHostNanoseconds: UInt64?

    mutating func accept(_ observation: CaptureWorkerObservation, publicationTime: UInt64?) {
        capture = observation.capture
        let hadWork = observation.deliveredPCMEvents > 0 || observation.emittedResults > 0
        guard hadWork else { return }
        latestWorker = observation
        workerTurns = captureDeliveryAdd(workerTurns)
        latestFirstPublicationHostNanoseconds = publicationTime
        guard mode != .disabled else { return }
        processing.record(observation.processingNanoseconds)
        if observation.dequeuedBlocks > 0 {
            captureBlockStartToWorker.record(observation.captureBlockStartToWorkerNanoseconds)
        }
        if observation.emittedResults > 0 {
            workerToPublication.record(
                CaptureWorkerObservation.difference(
                    publicationTime, observation.workerFinishedHostNanoseconds))
        }
    }
}
