/// Each subscriber owns an independent, fixed-capacity buffer. There is no
/// unbounded option and no producer wait for consumer progress.
public enum ResultDeliveryPolicy: Sendable, Hashable {
    /// Intentional display coalescing; the oldest buffered publication is replaced.
    case newest(capacity: Int)
    /// Preserve accepted publications, then fail explicitly on the first overflow.
    /// This is not a durable storage or lossless recording guarantee.
    case failOnOverflow(capacity: Int)

    var capacity: Int {
        switch self {
        case .newest(let capacity), .failOnOverflow(let capacity): capacity
        }
    }
}

public enum ResultDeliveryError: Error, Sendable, Hashable {
    case invalidCapacity, subscriberLimit, concurrentIteration
    case overflow(rejectedPublication: UInt64)
    case cancelled, publisherReleased, sequenceExhausted, upstreamFailure
}

public enum ResultDeliveryTermination: Sendable, Hashable {
    case finished
    case failed(ResultDeliveryError)
}

/// Scalar delivery metadata only; never contains the published value or audio.
/// Counters saturate instead of wrapping. Coalescing is separate from overflow.
public struct ResultDeliveryStatistics: Sendable, Hashable {
    public let capacity: Int
    public let buffered: Int
    public let highWater: Int
    public let accepted: UInt64
    public let delivered: UInt64
    public let coalesced: UInt64
    public let rejected: UInt64
    public let discardedOnCancellation: UInt64
    public let lastSubscriberLagNanoseconds: UInt64?
    public let maximumSubscriberLagNanoseconds: UInt64?
}

/// The value and its scientific timing remain unchanged. These timestamps describe
/// publication and observation by `next()`, not acoustic support or actual rendering.
public struct ResultDelivery<Value: Sendable>: Sendable {
    public let value: Value
    public let publication: UInt64
    public let publishedAtHostNanoseconds: UInt64
    public let observedAtHostNanoseconds: UInt64
    public let statistics: ResultDeliveryStatistics
}

/// Outcomes for one producer call, across all currently attached subscribers.
public struct ResultPublicationReport: Sendable, Hashable {
    public let publication: UInt64?
    public let acceptedSubscribers: Int
    public let coalescedSubscribers: Int
    public let overflowedSubscribers: Int
    public let isFinished: Bool
}
