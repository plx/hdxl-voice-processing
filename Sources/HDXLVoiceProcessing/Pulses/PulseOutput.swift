import Foundation

/// Fixed-width diagnostics avoid allocating a reason array for every cycle.
public struct PulseRejections: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let outsideAcquisition = Self(rawValue: 1 << 0)
    public static let outsideVoicedInterval = Self(rawValue: 1 << 1)
    public static let insufficientSupport = Self(rawValue: 1 << 2)
    public static let silence = Self(rawValue: 1 << 3)
    public static let degenerateWaveform = Self(rawValue: 1 << 4)
    public static let illConditionedPeak = Self(rawValue: 1 << 5)
    public static let numericalFailure = Self(rawValue: 1 << 6)
    public static let excludedSupport = Self(rawValue: 1 << 7)
    public static let trackingFailure = Self(rawValue: 1 << 8)
    public static let differentRun = Self(rawValue: 1 << 9)
    public static let periodBelowMinimum = Self(rawValue: 1 << 10)
    public static let periodAboveMaximum = Self(rawValue: 1 << 11)
    public static let adjacentPeriodFactor = Self(rawValue: 1 << 12)
    public static let insufficientCycles = Self(rawValue: 1 << 13)
    public static let lowCorrelation = Self(rawValue: 1 << 14)
    public static let lowAmplitude = Self(rawValue: 1 << 15)
    public static let priorIntervalCollision = Self(rawValue: 1 << 16)
    public static let rangeFallback = Self(rawValue: 1 << 17)

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(UInt32.self)
        guard value & ~((1 << 18) - 1) == 0 else { throw ContractError.invalidValue }
        self.init(rawValue: value)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PulseTrackingDirection: String, Sendable, Hashable, Codable {
    case seed, backward, forward
}

/// Raw reference-style landmark plus independent native timing eligibility.
/// `timeSeconds` is relative to result.timing.source.startSample, never an
/// imprecise subtraction of two large absolute source-clock values.
public struct PulseLandmark: Sendable, Hashable {
    public internal(set) var index: Int = 0
    public internal(set) var timeSeconds: Double = 0
    public internal(set) var voicedIntervalID: Int = 0
    public internal(set) var runID: Int?
    public internal(set) var direction: PulseTrackingDirection = .seed
    public internal(set) var stepIndex: Int = 0
    public internal(set) var attemptIndex: Int?
    public internal(set) var rejections: PulseRejections = []
    public var isEligible: Bool { rejections.isEmpty && runID != nil }
}

/// Every proposed matching step is retained, including points not added to the
/// raw landmark list. Interpolated correlation is a diagnostic, not confidence.
public struct PulseTrackingAttempt: Sendable, Hashable {
    public internal(set) var index: Int = 0
    public internal(set) var voicedIntervalID: Int = 0
    public internal(set) var direction: PulseTrackingDirection = .forward
    public internal(set) var stepIndex: Int = 0
    public internal(set) var fromSeconds: Double = 0
    public internal(set) var proposedSeconds: Double = 0
    public internal(set) var frequencyHz: Double = 0
    public internal(set) var correlation: Double?
    public internal(set) var amplitudeGatePeak: Double = 0
    public internal(set) var curvature: Double = 0
    public internal(set) var observedPairCount: Int = 0
    public internal(set) var firstRequiredSampleIndex: Int = 0
    public internal(set) var lastRequiredSampleIndex: Int = 0
    public internal(set) var selectedSyntheticCandidate = false
    public internal(set) var acceptedByReferenceGates = false
    public internal(set) var usedRangeFallback = false
    public internal(set) var rejections: PulseRejections = []
}

public struct PulsePeriod: Sendable, Hashable {
    public internal(set) var index: Int = 0
    public internal(set) var leftPulseIndex: Int = 0
    public internal(set) var rightPulseIndex: Int = 0
    public internal(set) var durationSeconds: Double = 0
    public internal(set) var runID: Int?
    public internal(set) var rejections: PulseRejections = []
    public var isEligible: Bool { rejections.isEmpty && runID != nil }
}

/// A bad adjacent ratio does not remove either period from every other statistic.
public struct PulsePeriodPair: Sendable, Hashable {
    public internal(set) var index: Int = 0
    public internal(set) var leftPeriodIndex: Int = 0
    public internal(set) var rightPeriodIndex: Int = 0
    public internal(set) var ratio: Double = 0
    public internal(set) var rejections: PulseRejections = []
    public var isEligible: Bool { rejections.isEmpty }
}

public struct PulseCycleAmplitude: Sendable, Hashable {
    public internal(set) var pulseIndex: Int = 0
    public internal(set) var rmsAmplitude: Double?
    public internal(set) var supportStartSeconds: Double?
    public internal(set) var supportEndSeconds: Double?
    public internal(set) var observedSampleCount: Int = 0
    public internal(set) var rejections: PulseRejections = []
    public var isEligible: Bool { rmsAmplitude != nil && rejections.isEmpty }
}

public struct PulseAnalysisResult: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let timing: AnalysisTiming
    public let f0ContourIdentity: ProfileIdentity
    public let f0SourceProfile: ProfileIdentity?
    public let f0FrameCount: Int
    public let f0FirstCenterSeconds: Double
    public let f0StepSeconds: Double
    public let voicedIntervalCount: Int
    public let rawPulseCount: Int
    public let trackingAttemptCount: Int
    public let eligiblePulseCount: Int
    public let eligiblePeriodCount: Int
    public let eligiblePairCount: Int
    public let availableAmplitudeCount: Int
    public let runCount: Int
    public let unavailability: UnavailabilityReason?
    public var timeUnit: MeasurementUnit { .seconds }
    public var amplitudeUnit: MeasurementUnit { .normalizedAmplitude }
}

/// All pointers are valid only for the synchronous analyze callback. An owned
/// copy is an explicit caller operation with a total retained-record budget.
public struct BorrowedPulseOutput {
    public let result: PulseAnalysisResult
    public let landmarks: UnsafeBufferPointer<PulseLandmark>
    public let attempts: UnsafeBufferPointer<PulseTrackingAttempt>
    public let periods: UnsafeBufferPointer<PulsePeriod>
    public let periodPairs: UnsafeBufferPointer<PulsePeriodPair>
    public let amplitudes: UnsafeBufferPointer<PulseCycleAmplitude>

    public func snapshot(maximumRecordCount: Int) throws -> PulseSnapshot {
        let count =
            landmarks.count + attempts.count + periods.count + periodPairs.count + amplitudes.count
        guard count <= maximumRecordCount else { throw ContractError.intermediateBudgetExceeded }
        return PulseSnapshot(
            result: result, landmarks: Array(landmarks), attempts: Array(attempts),
            periods: Array(periods), periodPairs: Array(periodPairs), amplitudes: Array(amplitudes))
    }
}

public struct PulseSnapshot: Sendable, Hashable {
    public let result: PulseAnalysisResult
    public let landmarks: [PulseLandmark]
    public let attempts: [PulseTrackingAttempt]
    public let periods: [PulsePeriod]
    public let periodPairs: [PulsePeriodPair]
    public let amplitudes: [PulseCycleAmplitude]
}

public struct PulseExecutionStatistics: Sendable, Hashable {
    public let preparedBufferBytes: Int
    public let analyzedIntervalCount: UInt64
    public let trackingAttemptCount: Int
    public let evaluatedLagCount: Int
}
