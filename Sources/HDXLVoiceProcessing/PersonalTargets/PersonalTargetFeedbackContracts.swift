import Foundation

public enum PersonalTargetFeedbackError: Error, Sendable, Equatable {
    case invalidConfiguration, incompatibleMeasurement, invalidEvidence, terminated
}

/// Engineering controls for temporal feedback, not clinical thresholds. The
/// accepted model supplies the preferred range; these controls never refit it.
public struct PersonalTargetFeedbackConfiguration: Sendable, Hashable, Encodable {
    public let measurement: MeasurementKind
    public let unit: MeasurementUnit
    public let warmupSeconds: Double
    public let entryPersistenceSeconds: Double
    public let exitPersistenceSeconds: Double
    public let minimumObservations: UInt64
    public let cooldownSeconds: Double
    public let maximumAgeSeconds: Double
    public let exitMarginDB: Double

    public init(
        measurement: MeasurementKind = .cpps, unit: MeasurementUnit = .decibelsRatio,
        warmupSeconds: Double = 0.25, entryPersistenceSeconds: Double = 0.5,
        exitPersistenceSeconds: Double = 0.5, minimumObservations: UInt64 = 2,
        cooldownSeconds: Double = 1, maximumAgeSeconds: Double = 2, exitMarginDB: Double = 0.5
    ) throws {
        guard measurement == .cpps, unit == .decibelsRatio else {
            throw PersonalTargetFeedbackError.incompatibleMeasurement
        }
        guard
            [warmupSeconds, entryPersistenceSeconds, exitPersistenceSeconds, cooldownSeconds]
                .allSatisfy({ $0.isFinite && (0...60).contains($0) }),
            maximumAgeSeconds.isFinite, maximumAgeSeconds > 0, maximumAgeSeconds <= 300,
            exitMarginDB.isFinite, (0...100).contains(exitMarginDB),
            (1...1024).contains(minimumObservations)
        else { throw PersonalTargetFeedbackError.invalidConfiguration }
        self.measurement = measurement
        self.unit = unit
        self.warmupSeconds = warmupSeconds == 0 ? 0 : warmupSeconds
        self.entryPersistenceSeconds = entryPersistenceSeconds == 0 ? 0 : entryPersistenceSeconds
        self.exitPersistenceSeconds = exitPersistenceSeconds == 0 ? 0 : exitPersistenceSeconds
        self.minimumObservations = minimumObservations
        self.cooldownSeconds = cooldownSeconds == 0 ? 0 : cooldownSeconds
        self.maximumAgeSeconds = maximumAgeSeconds
        self.exitMarginDB = exitMarginDB == 0 ? 0 : exitMarginDB
    }

    var maximumAgeNanoseconds: UInt64 { UInt64(ceil(maximumAgeSeconds * 1_000_000_000)) }
    var cooldownNanoseconds: UInt64 { UInt64(ceil(cooldownSeconds * 1_000_000_000)) }
}

public enum PersonalTargetFeedbackState: String, Sendable, Hashable, Encodable, CaseIterable {
    case unavailable, uncertain, approachingTarget, onTarget, departedTarget

    /// A visible text alternative; hosts may localize it and add non-color cues.
    /// No state describes vocal health, effort, tension, or a recommended action.
    public var text: String {
        switch self {
        case .unavailable: "Feedback unavailable"
        case .uncertain: "Insufficient evidence"
        case .approachingTarget: "Target match pending"
        case .onTarget: "Within your target"
        case .departedTarget: "Target drift"
        }
    }
}

public enum PersonalTargetFeedbackReason: String, Sendable, Hashable, Encodable, CaseIterable {
    case awaitingEvidence, warmingUp, entryPersistence, exitPersistence, cooldown
    case targetMatch, targetDrift, hysteresisHeld
    case missingData, droppedAudio, silence, suspectedNoise, clipping, lowPeriodicity
    case nonSpeech, insufficientEnergy
    case insufficientCoverage, unavailableMeasurements, untrustedMeasurements
    case incompatibleProfile, incompatibleStatistic, incompatibleTask, changedConditions
    case outsideObservedCPPS, outsideObservedPitch, outsideObservedLevel
    case stale, invalidClock, sourceDiscontinuity, routeChanged, profileChanged, modelChanged
    case paused, resumed, reset, cancelled, finished
}

/// The scored feature and applicability checks are separate; they are not averaged.
public enum PersonalTargetFeedbackFeature: String, Sendable, Hashable, Encodable {
    case timing, capture, context, coverage, fundamentalFrequency, levelDBFS, cpps
}

/// Current summary proximity remains visible while persistence or hysteresis
/// retains a previous state. It describes the summary, not every source frame.
public enum PersonalTargetFeedbackProximity: String, Sendable, Hashable, Encodable {
    case insidePreferred, withinExitMargin, outsideTarget
}

public enum PersonalTargetFeedbackInputDisposition: String, Sendable, Hashable, Encodable {
    case accepted, duplicate, outOfOrder, invalidClock, paused, control
}

public enum PersonalTargetFeedbackReset: String, Sendable, Hashable {
    case manual, routeChanged, profileChanged, discontinuity, missingData, droppedAudio
}

public struct PersonalTargetFeedbackInterval: Sendable, Hashable, Encodable {
    public let source: SourceInterval
    public let analysisIdentity: CalibrationDigest?
    public let profile: ProfileIdentity?
    public let statistic: PersonalTargetStatistic?
    public let analysisImplementation: VersionedIdentifier?
    public let sourceEndHostNanoseconds: UInt64
    /// Nil only for an explicit missing-acquisition interval.
    public let coverage: CalibrationCoverage?
    /// Tag unions within selected support; whole-source tags remain in coverage.
    /// An excluded silent/noisy region does not become selected vocal evidence.
    public let selectedTags: [String: Int64]
    public var isGap: Bool { coverage == nil }
}

/// Counts refer to one continuous source epoch/rate. An unobserved interval is
/// not automatically missing PCM. Tags overlap and must not be summed.
public struct PersonalTargetFeedbackCoverage: Sendable, Hashable, Encodable {
    public internal(set) var epoch: StreamEpoch?
    public internal(set) var sampleRate: Double?
    public internal(set) var sourceSamples: UInt64 = 0
    public internal(set) var eligibleSamples: UInt64 = 0
    public internal(set) var selectedSamples: UInt64 = 0
    public internal(set) var missingSamples: UInt64 = 0
    public internal(set) var excludedEligibleSamples: UInt64 = 0
    public internal(set) var unobservedSamples: UInt64 = 0
    public internal(set) var qualifiedSummarySamples: UInt64 = 0
    public internal(set) var matchingSummarySamples: UInt64 = 0
    public internal(set) var tags: [String: UInt64] = [:]
    public internal(set) var saturated = false

    public var qualifiedFraction: Double? {
        sourceSamples == 0 || saturated
            ? nil : Double(qualifiedSummarySamples) / Double(sourceSamples)
    }
}

public struct PersonalTargetFeedbackStatistics: Sendable, Hashable, Encodable {
    public internal(set) var acceptedIntervals: UInt64 = 0
    public internal(set) var duplicateInputs: UInt64 = 0
    public internal(set) var outOfOrderInputs: UInt64 = 0
    public internal(set) var invalidClocks: UInt64 = 0
    public internal(set) var unknownLossEvents: UInt64 = 0
    public internal(set) var resets: UInt64 = 0
    public internal(set) var stateChanges: UInt64 = 0
}

/// Supporting selected-summary duration is not measured per-frame in-target time.
public struct PersonalTargetFeedbackProgress: Sendable, Hashable, Encodable {
    public let qualifiedSeconds: Double
    public let entrySeconds: Double
    public let exitSeconds: Double
    public let entryObservations: UInt64
    public let exitObservations: UInt64
}

/// Owned bounded output; no PCM, labels, prompts, recording notes, or history.
/// Values are explicit personal results for subscribers, never diagnostic log fields.
public struct PersonalTargetFeedbackSnapshot: Sendable, Hashable, Encodable {
    public let targetIdentity: CalibrationDigest
    public let configurationIdentity: CalibrationDigest
    /// Required target profile; the actual input profile is in evidence.profile.
    public let profile: ProfileIdentity
    public let statistic: PersonalTargetStatistic
    public let state: PersonalTargetFeedbackState
    public let reasons: [PersonalTargetFeedbackReason]
    public let modelReasons: [PersonalTargetReason]
    public let responsibleFeature: PersonalTargetFeedbackFeature?
    public let proximity: PersonalTargetFeedbackProximity?
    public let evidence: PersonalTargetFeedbackInterval?
    public let values: PersonalTargetValues?
    public let progress: PersonalTargetFeedbackProgress
    public let coverage: PersonalTargetFeedbackCoverage
    public let statistics: PersonalTargetFeedbackStatistics
    public let inputDisposition: PersonalTargetFeedbackInputDisposition
    public let evaluatedAtHostNanoseconds: UInt64
    public let evidenceAgeNanoseconds: UInt64?
}
