import CryptoKit
import Foundation

public enum PulseF0Unavailability: String, Sendable, Hashable, Codable {
    case outsideDomain, outsideContour, unvoiced
}

/// A queried value is a frequency observation, never a pulse or confidence score.
public struct PulseF0Observation: Sendable, Hashable {
    public let frequencyHz: Double?
    public let nearestFrameIndex: Int?
    public let otherFrameIndex: Int?
    public let unavailability: PulseF0Unavailability?
}

/// Immutable, regularly sampled selected F0. Zero explicitly marks an unvoiced
/// frame. Interior-only contours retain their unsupported edges; no padding occurs.
/// The array is an owned preparation input and is never mutated by a pulse worker.
public struct PulseF0Contour: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let sampleCount: Int
    public let firstCenterSeconds: Double
    public let stepSeconds: Double
    public let ceilingHz: Double
    public let frequenciesHz: [Double]
    /// Optional identity of the estimator/recipe that supplied these frequencies.
    /// A nil value declares an unidentified supplied contour, not an oracle claim.
    public let sourceProfile: ProfileIdentity?
    private var preparedIdentity: ProfileIdentity?

    /// Reference interchange axis uses this operation order explicitly.
    public var domainEndSeconds: Double { Double(sampleCount) * (1 / Double(sampleRate)) }

    public init(
        sampleRate: Int, sampleCount: Int, firstCenterSeconds: Double,
        stepSeconds: Double, ceilingHz: Double, frequenciesHz: [Double],
        sourceProfile: ProfileIdentity? = nil
    ) throws {
        guard (4000...192_000).contains(sampleRate),
            (1...PulseConfiguration.maximumInputSampleCount).contains(sampleCount),
            (1...PulseConfiguration.maximumContourFrameCount).contains(frequenciesHz.count),
            firstCenterSeconds.isFinite, firstCenterSeconds > 0,
            stepSeconds.isFinite, stepSeconds > 0, ceilingHz.isFinite,
            20 < ceilingHz, ceilingHz <= Double(sampleRate) / 4
        else { throw PulseError.invalidContour }
        let end = Double(sampleCount) * (1 / Double(sampleRate))
        let last = firstCenterSeconds.addingProduct(Double(frequenciesHz.count - 1), stepSeconds)
        guard firstCenterSeconds <= end, last.isFinite, last <= end,
            stepSeconds <= max(1, end),
            frequenciesHz.count == 1
                || (firstCenterSeconds.addingProduct(1, stepSeconds) > firstCenterSeconds
                    && last
                        > firstCenterSeconds.addingProduct(
                            Double(frequenciesHz.count - 2), stepSeconds)),
            frequenciesHz.allSatisfy({ $0.isFinite && ($0 == 0 || (20 <= $0 && $0 < ceilingHz)) })
        else { throw PulseError.invalidContour }
        self.schemaVersion = 1
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.firstCenterSeconds = firstCenterSeconds
        self.stepSeconds = stepSeconds
        self.ceilingHz = ceilingHz
        self.frequenciesHz = frequenciesHz.map { $0 == 0 ? 0 : $0 }
        self.sourceProfile = sourceProfile
        self.preparedIdentity = try identity()
    }

    /// Content identity includes the exact selected frequencies and their source
    /// identity. Compute during preparation, not in a sample callback.
    public func identity() throws -> ProfileIdentity {
        if let preparedIdentity { return preparedIdentity }
        return try ProfileIdentity(
            identifier: VersionedIdentifier(name: "hdxl-pulse-supplied-f0", version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    public func observation(atRelativeSeconds time: Double) throws -> PulseF0Observation {
        guard time.isFinite else { throw PulseError.invalidInput }
        return frequenciesHz.withUnsafeBufferPointer {
            Self.observation(
                time: time, end: domainEndSeconds, first: firstCenterSeconds,
                step: stepSeconds, frequencies: $0)
        }
    }

    package static func observation(
        time: Double, end: Double, first: Double, step: Double,
        frequencies: UnsafeBufferPointer<Double>
    ) -> PulseF0Observation {
        guard (0...end).contains(time) else {
            return PulseF0Observation(
                frequencyHz: nil, nearestFrameIndex: nil, otherFrameIndex: nil,
                unavailability: .outsideDomain)
        }
        let coordinate = (time - first) / step + 1
        // Check the bounded supported region before converting to Int, including
        // extremely small valid frame steps and far-away finite query times.
        guard coordinate.isFinite, coordinate >= 0.5,
            coordinate < Double(frequencies.count) + 0.5
        else {
            return PulseF0Observation(
                frequencyHz: nil, nearestFrameIndex: nil, otherFrameIndex: nil,
                unavailability: .outsideContour)
        }
        let floorCoordinate = floor(coordinate)
        let fraction = coordinate - floorCoordinate
        let lower = Int(floorCoordinate) - 1
        let nearest = lower + (fraction >= 0.5 ? 1 : 0)
        let other = lower + (fraction >= 0.5 ? 0 : 1)
        let value = frequencies[nearest]
        guard value > 0 else {
            return PulseF0Observation(
                frequencyHz: nil, nearestFrameIndex: nearest, otherFrameIndex: nil,
                unavailability: .unvoiced)
        }
        guard frequencies.indices.contains(other), frequencies[other] > 0 else {
            return PulseF0Observation(
                frequencyHz: value, nearestFrameIndex: nearest, otherFrameIndex: nil,
                unavailability: nil)
        }
        let weight = fraction >= 0.5 ? 1 - fraction : fraction
        return PulseF0Observation(
            frequencyHz: value.addingProduct(weight, frequencies[other] - value),
            nearestFrameIndex: nearest, otherFrameIndex: other, unavailability: nil)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sampleRate, sampleCount, firstCenterSeconds
        case stepSeconds, ceilingHz, frequenciesHz, sourceProfile
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            sampleCount: c.decode(Int.self, forKey: .sampleCount),
            firstCenterSeconds: c.decode(Double.self, forKey: .firstCenterSeconds),
            stepSeconds: c.decode(Double.self, forKey: .stepSeconds),
            ceilingHz: c.decode(Double.self, forKey: .ceilingHz),
            frequenciesHz: c.decode([Double].self, forKey: .frequenciesHz),
            sourceProfile: c.decodeIfPresent(ProfileIdentity.self, forKey: .sourceProfile))
    }
}
