/// Finalization never invents samples or joins separate continuity epochs.
public enum PartialWindowPolicy: String, Sendable, Hashable, Codable {
    case discard
    case emitUnavailable
}

public enum ResetReason: String, Sendable, Hashable, Codable {
    case explicitReset, newSource, droppedAudio, pause, routeChange, profileChange
}

/// An explicit opt-in scalar budget shared across all intermediate arrays in one result.
/// This is not a history budget; consumers must separately bound retained results.
public struct IntermediateOutputPolicy: Sendable, Hashable, Codable {
    public let maximumScalarCount: Int
    public static let disabled = Self()
    private init() { maximumScalarCount = 0 }
    public init(maximumScalarCount: Int) throws {
        guard maximumScalarCount >= 0,
            !maximumScalarCount.multipliedReportingOverflow(by: MemoryLayout<Double>.stride)
                .overflow
        else { throw ContractError.invalidConfiguration }
        self.maximumScalarCount = maximumScalarCount
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case maximumScalarCount }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(maximumScalarCount: c.decode(Int.self, forKey: .maximumScalarCount))
    }
}

/// Single-owner synchronous worker interface, deliberately not `Sendable`.
///
/// Setup/reconfiguration allocates scratch and caches profile identity. `process` borrows
/// its buffer only for the call; neither processor nor receiver may retain that pointer.
/// Input is interleaved normalized PCM with `interval.sampleCount * channelCount` scalars,
/// matching the profile encoding and source rate. This interface requires an interleaved
/// profile; adapters convert other layouts outside capture callbacks, before creating the
/// worker profile. An implementation must reject mismatches before reading samples.
///
/// Emission is synchronous and nonescaping: it cannot create an unbounded task/stream backlog.
/// Owned immutable results may cross tasks; the receiver must use bounded delivery. Do not
/// invoke this interface from a real-time capture callback or reenter it from `emit`.
/// See Documentation/Architecture/0002-measurement-contracts.md for lifecycle requirements.
public protocol PCMProcessor {
    associatedtype Sample: BinaryFloatingPoint & Sendable
    var profile: AnalysisProfile { get }
    var epoch: StreamEpoch { get }

    mutating func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (MeasurementResult) -> Void
    ) throws

    /// Discard partial/filter/smoothing state and require the new epoch at position zero.
    /// The previous epoch must match this processor. The scheduler forwards the boundary.
    mutating func reset(for discontinuity: SourceDiscontinuity) throws

    /// Validate and allocate first; failure leaves the old configuration/state intact.
    mutating func reconfigure(to profile: AnalysisProfile, epoch: StreamEpoch) throws

    /// Flush complete support; follow the profile's partial-window policy exactly once.
    mutating func finalize(emit: (MeasurementResult) -> Void) throws

    /// Stop immediately, discard pending work, and release scratch; idempotent.
    mutating func cancel()
}
