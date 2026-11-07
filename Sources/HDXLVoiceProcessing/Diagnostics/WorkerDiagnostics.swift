import Synchronization

#if canImport(os) && !HDXL_DISABLE_SIGNPOSTS
    import os
#endif

package enum DiagnosticIntervalToken {
    case recorded
    #if canImport(os) && !HDXL_DISABLE_SIGNPOSTS
        case signpost(OSSignpostIntervalState)
    #endif
}

/// Worker/control paths only. A sink must retain no unbounded queue of records.
/// Every accepted begin receives exactly one end, even when a scope throws.
package protocol DiagnosticSink: AnyObject, Sendable {
    func begin(_ record: DiagnosticRecord) -> DiagnosticIntervalToken?
    func end(_ record: DiagnosticRecord, token: DiagnosticIntervalToken)
    func event(_ record: DiagnosticRecord) -> Bool
}

/// Single-owner, synchronous scope facade. Never call from an audio callback.
/// It is intentionally not Sendable: each analyzer owns its worker's instance.
package final class WorkerDiagnostics {
    private static let identities = Mutex<UInt64>(1)
    package static let sampledFramePeriod: UInt64 = 16
    package static let recordsPerFrame = 64
    package static let maximumDepth = 8

    package let mode: DiagnosticMode
    package let session: UInt64
    package private(set) var counts = DiagnosticCounts()
    private let sink: (any DiagnosticSink)?
    private var epoch: UInt64 = 0
    private var nextSpan: UInt64 = 1
    private var remaining = recordsPerFrame
    private var depth = 0
    private var frame: DiagnosticMetadata?
    private var selected = true
    private var exhausted = false

    package init(mode: DiagnosticMode = .disabled, sink: (any DiagnosticSink)? = nil) {
        self.mode = mode
        session = Self.identities.withLock { value in
            let result = value
            if value != 0 { value = value == .max ? 0 : value + 1 }
            return result
        }
        // Zero is an unavailable identity, never reused after exhaustion.
        exhausted = session == 0
        if mode == .disabled {
            self.sink = nil
        } else {
            self.sink = sink ?? Self.systemSink()
        }
        event(.initialize)
    }

    private static func systemSink() -> (any DiagnosticSink)? {
        #if canImport(os) && !HDXL_DISABLE_SIGNPOSTS
            return SignpostDiagnosticSink()
        #else
            return nil
        #endif
    }

    /// Sampling admits whole frames. Suppressed scopes still execute their bodies.
    /// Nested frame entry is ignored diagnostically, preserving the enclosing scope.
    package func withFrame<T>(
        _ metadata: DiagnosticMetadata, stage: DiagnosticStage = .analysisFrame,
        _ body: () throws -> T
    ) rethrows -> T {
        guard mode != .disabled else { return try body() }
        guard frame == nil else {
            counts.suppressed = saturatingAdd(counts.suppressed)
            return try body()
        }
        frame = metadata
        selected = mode == .detailed || metadata.frameSequence % Self.sampledFramePeriod == 0
        remaining = Self.recordsPerFrame
        defer {
            frame = nil
            selected = true
        }
        return try withInterval(stage, body)
    }

    /// Synchronous lexical lifetime means return, throw and cooperative cancellation
    /// all end the same captured interval. Reset never discards outstanding tokens.
    package func withInterval<T>(_ stage: DiagnosticStage, _ body: () throws -> T) rethrows -> T {
        guard mode != .disabled else { return try body() }
        guard depth < Self.maximumDepth, let record = admit(stage) else {
            if depth >= Self.maximumDepth { counts.suppressed = saturatingAdd(counts.suppressed) }
            return try body()
        }
        guard let token = sink?.begin(record) else {
            counts.unavailable = saturatingAdd(counts.unavailable)
            return try body()
        }
        counts.intervals = saturatingAdd(counts.intervals)
        depth += 1
        defer {
            sink?.end(record, token: token)
            depth -= 1
        }
        return try body()
    }

    package func event(_ stage: DiagnosticStage, validity: DiagnosticValidity? = nil) {
        guard mode != .disabled, let record = admit(stage, validity: validity) else { return }
        if sink?.event(record) == true {
            counts.events = saturatingAdd(counts.events)
        } else {
            counts.unavailable = saturatingAdd(counts.unavailable)
        }
    }

    /// A reset is a control event; existing spans keep their original epoch.
    package func reset() {
        guard mode != .disabled else { return }
        event(.reset)
        if epoch == .max { exhausted = true } else { epoch += 1 }
    }

    private func admit(_ stage: DiagnosticStage, validity: DiagnosticValidity? = nil)
        -> DiagnosticRecord?
    {
        guard selected, remaining > 0, !exhausted else {
            counts.suppressed = saturatingAdd(counts.suppressed)
            return nil
        }
        remaining -= 1
        var metadata = frame ?? DiagnosticMetadata()
        if let validity { metadata.validity = validity }
        let record = DiagnosticRecord(
            session: session, epoch: epoch, span: nextSpan, stage: stage,
            metadata: metadata)
        if nextSpan == .max { exhausted = true } else { nextSpan += 1 }
        return record
    }
}
