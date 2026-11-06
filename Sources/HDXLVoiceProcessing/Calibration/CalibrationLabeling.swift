import Foundation

public struct CalibrationReplayToken: Sendable, Hashable, Codable {
    public let identity: CalibrationDigest
    init(identity: CalibrationDigest) { self.identity = identity }

    private enum CodingKeys: String, CodingKey, CaseIterable { case identity }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        self.init(identity: try c.decode(CalibrationDigest.self, forKey: .identity))
    }
}

/// Presenter-safe replay metadata. No production instruction, prior label, task,
/// locator, recording identity, numerical feature or target score is included.
public struct CalibrationReplayItem: Sendable, Hashable, Encodable {
    public let token: CalibrationReplayToken
    public let ordinal: Int
}

/// Controller-only resolution request. The host resolves and plays this media
/// without showing its identifier or filename in the blinded presenter.
public struct CalibrationReplayMedia: Sendable, Hashable {
    public let media: CalibrationMediaReference
    public let source: SourceInterval
}

private struct CalibrationReplaySeed: Encodable {
    let domain: String
    let dataset: CalibrationDigest
    let seed: UInt64
    let takeID: UUID
}

private struct CalibrationOrderedTake {
    let take: CalibrationTake
    let order: CalibrationDigest
}

/// Single-owner, synchronous labeling transaction. The API's presenter projection
/// and completion gate support blinding; they cannot prevent a host that owns the
/// original dataset from exposing other information outside this workflow.
/// Numerical analysis is neither performed nor required here.
public final class CalibrationLabelingSession {
    public let datasetIdentity: CalibrationDigest
    public let items: [CalibrationReplayItem]
    public var completedCount: Int { dispositions.count }
    public var isComplete: Bool { completedDataset != nil }

    private enum Disposition {
        case labeled(CalibrationListeningLabel)
        case excluded(String)
    }
    private let original: CalibrationDataset
    private let takes: [CalibrationReplayToken: CalibrationTake]
    private var dispositions: [UUID: Disposition] = [:]
    private var completedDataset: CalibrationDataset?

    /// A supplied seed makes the order reproducible for a particular dataset
    /// version. Presentation order never depends on the caller's array ordering.
    public init(dataset: CalibrationDataset, shuffleSeed: UInt64) throws {
        guard dataset.takeCount > 0 else { throw CalibrationError.invalidRecord }
        let identity = try dataset.identity()
        var keyed: [CalibrationOrderedTake] = []
        for session in dataset.sessions {
            for take in session.takes {
                let order = try calibrationDigest(
                    CalibrationReplaySeed(
                        domain: "calibration-replay-order-v1", dataset: identity,
                        seed: shuffleSeed, takeID: take.id))
                keyed.append(CalibrationOrderedTake(take: take, order: order))
            }
        }
        keyed.sort {
            if $0.order == $1.order { return $0.take.id.uuidString < $1.take.id.uuidString }
            return $0.order.sha256 < $1.order.sha256
        }
        var mapping: [CalibrationReplayToken: CalibrationTake] = [:]
        var items: [CalibrationReplayItem] = []
        for (index, pair) in keyed.enumerated() {
            let token = try CalibrationReplayToken(
                identity: calibrationDigest(
                    CalibrationReplaySeed(
                        domain: "calibration-replay-token-v1", dataset: identity,
                        seed: shuffleSeed, takeID: pair.take.id)))
            guard mapping.updateValue(pair.take, forKey: token) == nil else {
                throw CalibrationError.duplicateIdentity
            }
            items.append(CalibrationReplayItem(token: token, ordinal: index + 1))
        }
        self.original = dataset
        self.datasetIdentity = identity
        self.takes = mapping
        self.items = items
    }

    public func replayMedia(for token: CalibrationReplayToken) throws -> CalibrationReplayMedia {
        guard let take = takes[token] else { throw CalibrationError.unknownReplay }
        return CalibrationReplayMedia(media: take.media, source: take.source)
    }

    /// Replaces a disposition while listening is still in progress. The intention
    /// does not constrain the actual label, including other/uncertain outcomes.
    public func submit(
        _ token: CalibrationReplayToken, preference: CalibrationListeningPreference,
        confidence: Double? = nil, notes: String = "", recordedAtUnixSeconds: Double? = nil
    ) throws {
        guard completedDataset == nil else { throw CalibrationError.invalidState }
        guard let take = takes[token] else { throw CalibrationError.unknownReplay }
        let label = try CalibrationListeningLabel(
            preference: preference, confidence: confidence, notes: notes,
            recordedAtUnixSeconds: recordedAtUnixSeconds, exposure: .blindedBeforeFeatures)
        dispositions[take.id] = .labeled(label)
    }

    /// Missing/unusable media can be explicitly excluded without inventing a label.
    public func exclude(_ token: CalibrationReplayToken, reason: String) throws {
        guard completedDataset == nil else { throw CalibrationError.invalidState }
        guard let take = takes[token] else { throw CalibrationError.unknownReplay }
        dispositions[take.id] = .excluded(try calibrationText(reason, allowEmpty: false))
    }

    /// Reveal only after every take has a listening label or explicit exclusion.
    /// Returns a new immutable revision; repeated completion returns the same value.
    public func complete() throws -> CalibrationDataset {
        if let completedDataset { return completedDataset }
        guard dispositions.count == original.takeCount else {
            throw CalibrationError.missingLabels
        }
        let sessions = try original.sessions.map { session in
            try CalibrationSession(
                id: session.id, recordedAtUnixSeconds: session.recordedAtUnixSeconds,
                notes: session.notes,
                takes: session.takes.map { take in
                    guard let disposition = dispositions[take.id] else {
                        throw CalibrationError.missingLabels
                    }
                    switch disposition {
                    case .labeled(let label): return try take.replacingLabel(label)
                    case .excluded(let reason):
                        return try take.replacingLabel(nil, exclusionReason: reason)
                    }
                })
        }
        let dataset = try original.revised(sessions: sessions)
        completedDataset = dataset
        return dataset
    }
}
