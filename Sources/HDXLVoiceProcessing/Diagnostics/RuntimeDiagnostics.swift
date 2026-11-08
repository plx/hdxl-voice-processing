import Dispatch

/// Disabled retains delivery/loss correctness counters but adds no signpost records
/// or optional processing measurements. Sampled admits every sixteenth record group;
/// detailed admits each group. Neither mode changes numerical analysis.
public enum RuntimeDiagnosticMode: String, Sendable, Hashable, CaseIterable {
    case disabled, sampled, detailed

    package var facadeMode: DiagnosticMode {
        switch self {
        case .disabled: .disabled
        case .sampled: .sampled
        case .detailed: .detailed
        }
    }
}

/// Bounded scalar summary, without an implicit sample history. Missing/invalid
/// clocks count as unavailable, never zero latency. Export distributions using an
/// explicitly bounded host probe. Saturated totals cannot produce a valid mean.
public struct RuntimeLatencySummary: Sendable, Hashable, Encodable {
    public private(set) var samples: UInt64 = 0
    public private(set) var unavailableSamples: UInt64 = 0
    public private(set) var lastNanoseconds: UInt64?
    public private(set) var minimumNanoseconds: UInt64?
    public private(set) var maximumNanoseconds: UInt64?
    public private(set) var totalNanoseconds: UInt64 = 0
    public private(set) var saturated = false
    public var meanNanoseconds: Double? {
        samples == 0 || saturated ? nil : Double(totalNanoseconds) / Double(samples)
    }

    public init() {}

    package mutating func record(_ value: UInt64?) {
        lastNanoseconds = value
        guard let value else {
            unavailableSamples = saturatingAdd(unavailableSamples)
            return
        }
        let (sum, overflow) = totalNanoseconds.addingReportingOverflow(value)
        saturated = saturated || overflow || samples == .max
        totalNanoseconds = overflow ? .max : sum
        samples = saturatingAdd(samples)
        minimumNanoseconds = min(minimumNanoseconds ?? value, value)
        maximumNanoseconds = max(maximumNanoseconds ?? value, value)
    }
}

/// Explicit synchronous host rendering work, separate from analysis, publication
/// and consumer observation. This cannot measure compositor presentation or infer
/// that pixels reached a display. Single-owner control/UI path; never capture.
public final class ResultRenderingDiagnostics {
    public let mode: RuntimeDiagnosticMode
    public private(set) var duration = RuntimeLatencySummary()
    private let facade: WorkerDiagnostics
    private let clock: @Sendable () -> UInt64
    private var sequence: UInt64 = 0

    public convenience init(mode: RuntimeDiagnosticMode = .disabled) {
        self.init(mode: mode, sink: nil, clock: { DispatchTime.now().uptimeNanoseconds })
    }

    init(
        mode: RuntimeDiagnosticMode, sink: (any DiagnosticSink)?,
        clock: @escaping @Sendable () -> UInt64
    ) {
        self.mode = mode
        self.facade = WorkerDiagnostics(mode: mode.facadeMode, sink: sink)
        self.clock = clock
    }

    public func measure<T>(_ work: () throws -> T) rethrows -> T {
        guard mode != .disabled else { return try work() }
        let start = clock()
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 5403
        metadata.frameSequence = sequence
        sequence = saturatingAdd(sequence)
        defer {
            let end = clock()
            duration.record(end >= start ? end - start : nil)
        }
        return try facade.withFrame(metadata, stage: .rendering, work)
    }
}
