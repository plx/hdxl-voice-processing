import Foundation

/// Source reliability/selection reasons, independent of numerical period bounds.
/// Multiple reasons may apply to one observation. A rejected interval remains in
/// its original position and breaks numerator neighborhoods on both sides.
public struct JitterPeriodRejections: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let excluded = Self(rawValue: 1 << 0)
    public static let discontinuity = Self(rawValue: 1 << 1)
    public static let unreliable = Self(rawValue: 1 << 2)
    public static let missingAcquisition = Self(rawValue: 1 << 3)
    public static let invalidInput = Self(rawValue: 1 << 4)
    public static let silence = Self(rawValue: 1 << 5)
    static let knownBits: UInt8 = 0x3f

    private enum CodingKeys: String, CodingKey, CaseIterable { case rawValue }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let raw = try c.decode(UInt8.self, forKey: .rawValue)
        guard raw & ~Self.knownBits == 0 else { throw JitterError.invalidInput }
        self.init(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        guard rawValue & ~Self.knownBits == 0 else { throw JitterError.invalidInput }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rawValue, forKey: .rawValue)
    }
}

/// An observed adjacent interval, in seconds relative to dependencyTiming.source.
/// Durations are not rounded to integer sample frames. Run identity and touching
/// endpoints are both required for continuity; identity reuse cannot bridge a gap.
public struct JitterPeriodInput: Sendable, Hashable, Codable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let runID: UInt64
    public let rejections: JitterPeriodRejections
    public var durationSeconds: Double { endSeconds - startSeconds }

    public init(
        startSeconds: Double, endSeconds: Double, runID: UInt64 = 0,
        rejections: JitterPeriodRejections = []
    ) throws {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds < endSeconds,
            (endSeconds - startSeconds).isFinite,
            rejections.rawValue & ~JitterPeriodRejections.knownBits == 0
        else { throw JitterError.invalidInput }
        self.startSeconds = startSeconds == 0 ? 0 : startSeconds
        self.endSeconds = endSeconds == 0 ? 0 : endSeconds
        self.runID = runID
        self.rejections = rejections
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case startSeconds, endSeconds, runID, rejections
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            startSeconds: c.decode(Double.self, forKey: .startSeconds),
            endSeconds: c.decode(Double.self, forKey: .endSeconds),
            runID: c.decode(UInt64.self, forKey: .runID),
            rejections: c.decode(JitterPeriodRejections.self, forKey: .rejections))
    }
}

/// Exact relative query bounds. A period contributes only when both endpoints
/// are inside this closed point-query range; empty ranges contain no periods.
public struct JitterQueryRange: Sendable, Hashable, Codable {
    public let startSeconds: Double
    public let endSeconds: Double
    public var durationSeconds: Double { endSeconds - startSeconds }
    public var centerSeconds: Double { startSeconds + durationSeconds / 2 }

    public init(startSeconds: Double, endSeconds: Double) throws {
        guard startSeconds.isFinite, endSeconds.isFinite, 0 <= startSeconds,
            startSeconds <= endSeconds, (endSeconds - startSeconds).isFinite
        else { throw JitterError.unexpectedContext }
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

public enum JitterInputKind: String, Sendable, Hashable, Codable {
    case suppliedPeriods, acousticPulses
}

/// Unidentified supplied periods are explicit; they are never presented as
/// independently measured or reference-validated merely because they have values.
public struct JitterInputProvenance: Sendable, Hashable, Codable {
    public let kind: JitterInputKind
    public let periodSourceProfile: ProfileIdentity?
    public let f0ContourIdentity: ProfileIdentity?
    public let f0SourceProfile: ProfileIdentity?

    public init(periodSourceProfile: ProfileIdentity? = nil) {
        kind = .suppliedPeriods
        self.periodSourceProfile = periodSourceProfile
        f0ContourIdentity = nil
        f0SourceProfile = nil
    }

    public init(pulseResult: PulseAnalysisResult) {
        kind = .acousticPulses
        periodSourceProfile = pulseResult.profile
        f0ContourIdentity = pulseResult.f0ContourIdentity
        f0SourceProfile = pulseResult.f0SourceProfile
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, periodSourceProfile, f0ContourIdentity, f0SourceProfile
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        kind = try c.decode(JitterInputKind.self, forKey: .kind)
        periodSourceProfile = try c.decodeIfPresent(
            ProfileIdentity.self, forKey: .periodSourceProfile)
        f0ContourIdentity = try c.decodeIfPresent(ProfileIdentity.self, forKey: .f0ContourIdentity)
        f0SourceProfile = try c.decodeIfPresent(ProfileIdentity.self, forKey: .f0SourceProfile)
        switch kind {
        case .suppliedPeriods:
            guard f0ContourIdentity == nil, f0SourceProfile == nil else {
                throw JitterError.unexpectedContext
            }
        case .acousticPulses:
            guard periodSourceProfile != nil, f0ContourIdentity != nil else {
                throw JitterError.unexpectedContext
            }
        }
    }
}
