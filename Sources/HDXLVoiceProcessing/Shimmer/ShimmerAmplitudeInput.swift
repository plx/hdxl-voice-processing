import Foundation

/// Source reasons differ from the numerical zero, period and amplitude-ratio
/// rules. Retain rejected observations so they break consecutive neighborhoods.
public struct ShimmerAmplitudeRejections: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let excluded = Self(rawValue: 1 << 0)
    public static let discontinuity = Self(rawValue: 1 << 1)
    public static let unreliable = Self(rawValue: 1 << 2)
    public static let missingAcquisition = Self(rawValue: 1 << 3)
    public static let invalidInput = Self(rawValue: 1 << 4)
    public static let silence = Self(rawValue: 1 << 5)
    public static let insufficientSupport = Self(rawValue: 1 << 6)
    public static let periodExclusion = Self(rawValue: 1 << 7)
    static let knownBits: UInt16 = 0xff

    private enum CodingKeys: String, CodingKey, CaseIterable { case rawValue }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let raw = try c.decode(UInt16.self, forKey: .rawValue)
        guard raw & ~Self.knownBits == 0 else { throw ShimmerError.invalidInput }
        self.init(rawValue: raw)
    }
    public func encode(to encoder: any Encoder) throws {
        guard rawValue & ~Self.knownBits == 0 else { throw ShimmerError.invalidInput }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rawValue, forKey: .rawValue)
    }
}

/// A cycle-amplitude observation at a time relative to dependencyTiming.source.
/// A sequence index identifies the original observation position, including
/// missing/rejected cycles. Adjacent indices and equal run IDs are both needed
/// for continuity. A missing value requires an explicit source rejection.
public struct ShimmerAmplitudeInput: Sendable, Hashable, Codable {
    public let timeSeconds: Double
    public let amplitude: Double?
    public let sequenceIndex: UInt64
    public let runID: UInt64
    public let rejections: ShimmerAmplitudeRejections

    public init(
        timeSeconds: Double, amplitude: Double?, sequenceIndex: UInt64,
        runID: UInt64 = 0, rejections: ShimmerAmplitudeRejections = []
    ) throws {
        guard timeSeconds.isFinite,
            rejections.rawValue & ~ShimmerAmplitudeRejections.knownBits == 0,
            amplitude.map({ $0.isFinite && $0 >= 0 }) ?? !rejections.isEmpty
        else { throw ShimmerError.invalidInput }
        self.timeSeconds = timeSeconds == 0 ? 0 : timeSeconds
        self.amplitude = amplitude.map { $0 == 0 ? 0 : $0 }
        self.sequenceIndex = sequenceIndex
        self.runID = runID
        self.rejections = rejections
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case timeSeconds, amplitude, sequenceIndex, runID, rejections
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            timeSeconds: c.decode(Double.self, forKey: .timeSeconds),
            amplitude: c.decodeIfPresent(Double.self, forKey: .amplitude),
            sequenceIndex: c.decode(UInt64.self, forKey: .sequenceIndex),
            runID: c.decode(UInt64.self, forKey: .runID),
            rejections: c.decode(ShimmerAmplitudeRejections.self, forKey: .rejections))
    }
}

/// Closed amplitude-center bounds; amplitudes are not rounded to sample indices.
public struct ShimmerQueryRange: Sendable, Hashable, Codable {
    public let startSeconds: Double
    public let endSeconds: Double
    public var durationSeconds: Double { endSeconds - startSeconds }
    public var centerSeconds: Double { startSeconds + durationSeconds / 2 }

    public init(startSeconds: Double, endSeconds: Double) throws {
        guard startSeconds.isFinite, endSeconds.isFinite, 0 <= startSeconds,
            startSeconds <= endSeconds, (endSeconds - startSeconds).isFinite
        else { throw ShimmerError.unexpectedContext }
        self.startSeconds = startSeconds == 0 ? 0 : startSeconds
        self.endSeconds = endSeconds == 0 ? 0 : endSeconds
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case startSeconds, endSeconds }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            startSeconds: c.decode(Double.self, forKey: .startSeconds),
            endSeconds: c.decode(Double.self, forKey: .endSeconds))
    }
}

public enum ShimmerInputKind: String, Sendable, Hashable, Codable {
    case suppliedAmplitudes, acousticPulses
}

public struct ShimmerInputProvenance: Sendable, Hashable, Codable {
    public let kind: ShimmerInputKind
    public let amplitudeSourceProfile: ProfileIdentity?
    public let f0ContourIdentity: ProfileIdentity?
    public let f0SourceProfile: ProfileIdentity?

    public init(amplitudeSourceProfile: ProfileIdentity? = nil) {
        kind = .suppliedAmplitudes
        self.amplitudeSourceProfile = amplitudeSourceProfile
        f0ContourIdentity = nil
        f0SourceProfile = nil
    }
    public init(pulseResult: PulseAnalysisResult) {
        kind = .acousticPulses
        amplitudeSourceProfile = pulseResult.profile
        f0ContourIdentity = pulseResult.f0ContourIdentity
        f0SourceProfile = pulseResult.f0SourceProfile
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, amplitudeSourceProfile, f0ContourIdentity, f0SourceProfile
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        kind = try c.decode(ShimmerInputKind.self, forKey: .kind)
        amplitudeSourceProfile = try c.decodeIfPresent(
            ProfileIdentity.self, forKey: .amplitudeSourceProfile)
        f0ContourIdentity = try c.decodeIfPresent(ProfileIdentity.self, forKey: .f0ContourIdentity)
        f0SourceProfile = try c.decodeIfPresent(ProfileIdentity.self, forKey: .f0SourceProfile)
        switch kind {
        case .suppliedAmplitudes:
            guard f0ContourIdentity == nil, f0SourceProfile == nil else {
                throw ShimmerError.unexpectedContext
            }
        case .acousticPulses:
            guard amplitudeSourceProfile != nil, f0ContourIdentity != nil else {
                throw ShimmerError.unexpectedContext
            }
        }
    }
}
