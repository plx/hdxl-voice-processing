import Foundation

public enum CalibrationConditionField: String, Sendable, Hashable, CaseIterable {
    case route, room, microphoneDistance, inputGain, recordingSettings
}

/// Problems and changes are explicit facts, not a voice-quality score. A changed
/// task/room may be intentional held-out evaluation; the caller must not silently
/// pool it with fitting data. Unknown is never evidence of equivalence.
public enum CalibrationAssessmentFinding: Sendable, Hashable {
    case excluded, emptySource, noEligibleAudio, noSelectedAudio, insufficientCoverage
    case missingLabel, uncertainLabel, labelNotBlindedBeforeFeatures
    case unknownCondition(CalibrationConditionField)
    case unknownReferenceCondition(CalibrationConditionField)
    case changedCondition(CalibrationConditionField)
    case differentTask, differentProfile
    case missingAnalysis, incompatibleAnalysis
    case insufficientMetricObservations(ScheduledMetric)
}

/// Caller-selected evidence requirements, not learned or clinical thresholds.
/// Defaults check only nonempty selected audio and at least one available frame.
public struct CalibrationAssessmentPolicy: Sendable, Hashable {
    public let minimumSelectedSampleCount: Int64
    public let minimumSelectedFraction: Double
    public let minimumAvailableObservations: Int

    public init(
        minimumSelectedSampleCount: Int64 = 1, minimumSelectedFraction: Double = 0,
        minimumAvailableObservations: Int = 1
    ) throws {
        guard minimumSelectedSampleCount >= 1,
            minimumSelectedFraction.isFinite, (0...1).contains(minimumSelectedFraction),
            (1...CalibrationMetricSummary.maximumObservationCount).contains(
                minimumAvailableObservations)
        else { throw CalibrationError.invalidRecord }
        self.minimumSelectedSampleCount = minimumSelectedSampleCount
        self.minimumSelectedFraction = minimumSelectedFraction
        self.minimumAvailableObservations = minimumAvailableObservations
    }
}

public struct CalibrationTakeAssessment: Sendable, Hashable {
    public let takeID: UUID
    public let coverage: CalibrationCoverage
    public let findings: [CalibrationAssessmentFinding]

    public init(
        take: CalibrationTake, reference: CalibrationTake? = nil,
        analysis: CalibrationAnalysisRecord? = nil,
        policy: CalibrationAssessmentPolicy
    ) throws {
        takeID = take.id
        let mask = try PreparedAnalysisMask(
            timeline: MaskTimeline(take.effectiveMaskPlan()), scope: .selected)
        coverage = try CalibrationCoverage(mask.coverage(of: take.source))
        var findings: [CalibrationAssessmentFinding] = []
        if take.exclusionReason != nil { findings.append(.excluded) }
        if take.source.sampleCount == 0 { findings.append(.emptySource) }
        if coverage.eligible == 0 { findings.append(.noEligibleAudio) }
        if coverage.selected == 0 { findings.append(.noSelectedAudio) }
        if coverage.selected < policy.minimumSelectedSampleCount
            || coverage.selectedFraction < policy.minimumSelectedFraction
        {
            findings.append(.insufficientCoverage)
        }
        if let label = take.label {
            if label.preference == .uncertain { findings.append(.uncertainLabel) }
            if label.exposure != .blindedBeforeFeatures {
                findings.append(.labelNotBlindedBeforeFeatures)
            }
        } else if take.exclusionReason == nil {
            findings.append(.missingLabel)
        }
        for field in CalibrationConditionField.allCases {
            let value = take.conditions.comparisonValue(field)
            if value == nil { findings.append(.unknownCondition(field)) }
            if let reference {
                let other = reference.conditions.comparisonValue(field)
                if other == nil { findings.append(.unknownReferenceCondition(field)) }
                if let value, let other, value != other {
                    findings.append(.changedCondition(field))
                }
            }
        }
        if let reference {
            if take.task != reference.task { findings.append(.differentTask) }
            if take.profileIdentity != reference.profileIdentity {
                findings.append(.differentProfile)
            }
        }
        if let analysis {
            do {
                try analysis.validate(for: take)
                for summary in analysis.summaries
                where summary.availableCount < policy.minimumAvailableObservations {
                    findings.append(.insufficientMetricObservations(summary.metric))
                }
            } catch {
                findings.append(.incompatibleAnalysis)
            }
        } else {
            findings.append(.missingAnalysis)
        }
        self.findings = findings
    }
}

extension CalibrationRecordingConditions {
    func comparisonValue(_ field: CalibrationConditionField) -> [String:
        ProfileSetting]?
    {
        switch field {
        case .route: routeIdentifier.map { ["value": .text($0)] }
        case .room: roomIdentifier.map { ["value": .text($0)] }
        case .microphoneDistance: microphoneDistanceMeters.map { ["value": .real($0)] }
        case .inputGain: inputGainDB.map { ["value": .real($0)] }
        case .recordingSettings: recordingSettings
        }
    }
}
