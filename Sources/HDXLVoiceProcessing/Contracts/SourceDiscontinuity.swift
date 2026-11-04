import Foundation

/// A boundary event, including the old-clock missing interval when its extent is known.
/// Unknown loss remains nil; it must not be guessed as zero missing samples.
public struct SourceDiscontinuity: Sendable, Hashable, Codable {
    public let previousEpoch: StreamEpoch
    public let nextEpoch: StreamEpoch
    public let reason: ResetReason
    public let missingSource: SourceInterval?

    public init(
        previousEpoch: StreamEpoch, nextEpoch: StreamEpoch, reason: ResetReason,
        missingSource: SourceInterval? = nil
    ) throws {
        if reason == .newSource {
            guard previousEpoch.streamID != nextEpoch.streamID, nextEpoch.sequence == 0 else {
                throw ContractError.invalidInterval
            }
        } else {
            guard nextEpoch == (try previousEpoch.successor()) else {
                throw ContractError.invalidInterval
            }
        }
        if let missingSource {
            guard missingSource.epoch == previousEpoch, missingSource.sampleCount > 0 else {
                throw ContractError.invalidInterval
            }
        }
        self.previousEpoch = previousEpoch
        self.nextEpoch = nextEpoch
        self.reason = reason
        self.missingSource = missingSource
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case previousEpoch, nextEpoch, reason, missingSource
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            previousEpoch: c.decode(StreamEpoch.self, forKey: .previousEpoch),
            nextEpoch: c.decode(StreamEpoch.self, forKey: .nextEpoch),
            reason: c.decode(ResetReason.self, forKey: .reason),
            missingSource: c.decodeIfPresent(SourceInterval.self, forKey: .missingSource))
    }
}
