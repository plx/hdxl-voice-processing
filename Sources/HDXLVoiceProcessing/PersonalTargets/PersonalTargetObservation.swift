import Foundation

public enum PersonalTargetClass: String, Sendable, Hashable, Encodable, CaseIterable {
    case usual, preferred
}

/// Small numerical input. Each scalar is a selected-interval median (or a stated
/// coverage fraction), not a frame, calibrated probability, or normalized score.
public struct PersonalTargetValues: Sendable, Hashable, Encodable {
    public let cppsDB: Double
    public let fundamentalFrequencyHz: Double
    public let levelDBFS: Double
    public let selectedFraction: Double
    public let cppsAvailableFraction: Double
    public let pitchAvailableFraction: Double
    public let levelAvailableFraction: Double

    func context(_ metric: PersonalTargetContextMetric) -> Double {
        switch metric {
        case .fundamentalFrequency: fundamentalFrequencyHz
        case .levelDBFS: levelDBFS
        case .selectedFraction: selectedFraction
        case .cppsAvailableFraction: cppsAvailableFraction
        case .pitchAvailableFraction: pitchAvailableFraction
        case .levelAvailableFraction: levelAvailableFraction
        }
    }

    static func groupMedian(_ values: [Self]) throws -> Self {
        func median(_ key: KeyPath<Self, Double>) throws -> Double {
            try PersonalTargetDistribution(values.map { $0[keyPath: key] }).median
        }
        return try Self(
            cppsDB: median(\.cppsDB), fundamentalFrequencyHz: median(\.fundamentalFrequencyHz),
            levelDBFS: median(\.levelDBFS), selectedFraction: median(\.selectedFraction),
            cppsAvailableFraction: median(\.cppsAvailableFraction),
            pitchAvailableFraction: median(\.pitchAvailableFraction),
            levelAvailableFraction: median(\.levelAvailableFraction))
    }
}

/// Construct on a worker/control path from a complete, provenance-checked clip
/// analysis. Construction performs no fitting and retains no PCM or frame history.
public struct PersonalTargetObservation: Sendable, Hashable, Encodable {
    public let statistic: PersonalTargetStatistic
    public let profile: ProfileIdentity
    public let analysisImplementation: VersionedIdentifier
    public let task: CalibrationTask
    public let conditions: CalibrationRecordingConditions
    public let coverage: CalibrationCoverage
    public let cpps: CalibrationMetricSummary
    public let pitch: CalibrationMetricSummary
    public let level: CalibrationMetricSummary

    public init(take: CalibrationTake, analysis: CalibrationAnalysisRecord) throws {
        try analysis.validate(for: take)
        guard let cpps = analysis.summary(.cpps),
            let pitch = analysis.summary(.fundamentalFrequency),
            let level = analysis.summary(.levelDBFS)
        else { throw PersonalTargetError.invalidObservation }
        statistic = .selectedIntervalLowerMedianV1
        profile = take.profileIdentity
        analysisImplementation = analysis.key.implementation
        task = take.task
        conditions = take.conditions
        coverage = analysis.coverage
        self.cpps = cpps
        self.pitch = pitch
        self.level = level
    }

    func findings(policy: PersonalTargetPolicy) -> [PersonalTargetReason] {
        var reasons: [PersonalTargetReason] = []
        if coverage.selected < policy.minimumSelectedSamples
            || coverage.selectedFraction < policy.minimumSelectedFraction
        {
            reasons.append(.insufficientCoverage)
        }
        for summary in [cpps, pitch, level] {
            if summary.availableCount < policy.minimumAvailableObservations {
                reasons.append(.insufficientMetricObservations)
            }
            if fraction(summary) < policy.minimumAvailableFraction {
                reasons.append(.insufficientMetricAvailability)
            }
            if summary.warnings.contains(where: {
                $0.key != MeasurementWarning.partialCoverage.rawValue && $0.value > 0
            }) {
                reasons.append(.untrustedMetricWarnings)
            }
            let boundary = summary.warnings[MeasurementWarning.partialCoverage.rawValue] ?? 0
            if Double(boundary) / Double(max(1, summary.availableCount))
                > policy.maximumBoundaryFraction
            {
                reasons.append(.excessiveBoundaryCoverage)
            }
        }
        if let minimum = pitch.minimum, minimum <= 0 {
            reasons.append(.invalidMeasurements)
        }
        return targetReasons(reasons)
    }

    func values(policy: PersonalTargetPolicy) -> PersonalTargetValues? {
        guard findings(policy: policy).isEmpty,
            let cppsDB = cpps.median, let pitchHz = pitch.median, let levelDBFS = level.median,
            pitchHz > 0
        else { return nil }
        return PersonalTargetValues(
            cppsDB: cppsDB, fundamentalFrequencyHz: pitchHz, levelDBFS: levelDBFS,
            selectedFraction: coverage.selectedFraction,
            cppsAvailableFraction: fraction(cpps), pitchAvailableFraction: fraction(pitch),
            levelAvailableFraction: fraction(level))
    }

    private func fraction(_ summary: CalibrationMetricSummary) -> Double {
        Double(summary.availableCount) / Double(max(1, summary.observationCount))
    }
}

public struct PersonalTargetTakeReport: Sendable, Hashable, Encodable {
    public let takeID: UUID
    public let sessionID: UUID
    public let label: CalibrationListeningPreference?
    public let labelConfidence: Double?
    public let analysisIdentity: CalibrationDigest?
    public let coverage: CalibrationCoverage
    public let reasons: [PersonalTargetReason]
}

/// Coverage is retained per take. Summing overlapping excerpts would not give
/// unique acquisition coverage, so no misleading cross-take sample sum is exposed.
public struct PersonalTargetGroupSummary: Sendable, Hashable, Encodable {
    public let recordingGroup: CalibrationDigest
    public let sessionIDs: [UUID]
    public let role: CalibrationSplitRole
    public let actual: PersonalTargetClass?
    public let isInScope: Bool
    public let takes: [PersonalTargetTakeReport]
    public let distinctAnalysisCount: Int
    public let values: PersonalTargetValues?
    public let reasons: [PersonalTargetReason]
}

func targetConditionFindings(
    _ conditions: CalibrationRecordingConditions,
    reference: CalibrationRecordingConditions
) -> [PersonalTargetReason] {
    var reasons: [PersonalTargetReason] = []
    for field in CalibrationConditionField.allCases {
        let value = conditions.comparisonValue(field)
        let expected = reference.comparisonValue(field)
        if value == nil || expected == nil { reasons.append(.unknownConditions) }
        if let value, let expected, value != expected { reasons.append(.changedConditions) }
    }
    return targetReasons(reasons)
}

func targetAssessmentReasons(_ findings: [CalibrationAssessmentFinding]) -> [PersonalTargetReason] {
    findings.compactMap {
        switch $0 {
        case .excluded: .excludedRecording
        case .emptySource, .noEligibleAudio, .noSelectedAudio, .insufficientCoverage:
            .insufficientCoverage
        case .missingLabel: .missingLabel
        case .uncertainLabel: .unsupportedLabel
        case .labelNotBlindedBeforeFeatures: .labelExposedToFeatures
        case .unknownCondition, .unknownReferenceCondition: .unknownConditions
        case .changedCondition: .changedConditions
        case .differentTask: .differentTask
        case .differentProfile: .differentProfile
        case .missingAnalysis: .missingAnalysis
        case .incompatibleAnalysis: .incompatibleAnalysis
        case .insufficientMetricObservations(let metric):
            [.cpps, .fundamentalFrequency, .levelDBFS].contains(metric)
                ? .insufficientMetricObservations : nil
        }
    }
}

func prepareTargetGroups(
    _ members: [CalibrationAssignedTake], analyses: [UUID: CalibrationAnalysisRecord],
    reference: CalibrationTake, policy: PersonalTargetPolicy
) throws -> [PersonalTargetGroupSummary] {
    guard members.count <= CalibrationRecordLimits.maximumTakes else {
        throw PersonalTargetError.capacityExceeded
    }
    let groups = Dictionary(grouping: members, by: \.recordingGroup)
    let assessmentPolicy = try CalibrationAssessmentPolicy(
        minimumSelectedSampleCount: policy.minimumSelectedSamples,
        minimumSelectedFraction: policy.minimumSelectedFraction,
        minimumAvailableObservations: policy.minimumAvailableObservations)
    return try groups.keys.sorted { $0.sha256 < $1.sha256 }.map { group in
        let assigned = groups[group]!.sorted { $0.take.id.uuidString < $1.take.id.uuidString }
        let sessions = Array(Set(assigned.map(\.sessionID))).sorted {
            $0.uuidString < $1.uuidString
        }
        var groupReasons: [PersonalTargetReason] = []
        if sessions.count != 1 { groupReasons.append(.conflictingGroupMetadata) }
        let labels = Set(assigned.map { $0.take.label?.preference })
        let actual: PersonalTargetClass?
        if labels.count == 1, labels.first! == .usual {
            actual = .usual
        } else if labels.count == 1, labels.first! == .preferred {
            actual = .preferred
        } else {
            actual = nil
            if labels.count > 1 { groupReasons.append(.conflictingGroupLabels) }
        }
        var reports: [PersonalTargetTakeReport] = []
        var seen: [CalibrationDigest: CalibrationDigest] = [:]
        var values: [PersonalTargetValues] = []
        for member in assigned {
            let take = member.take
            let analysis = analyses[take.id]
            let assessment = try CalibrationTakeAssessment(
                take: take, reference: reference, analysis: analysis, policy: assessmentPolicy)
            var reasons = targetAssessmentReasons(assessment.findings)
            if let label = take.label {
                if label.preference != .usual && label.preference != .preferred {
                    reasons.append(.unsupportedLabel)
                }
                if policy.minimumLabelConfidence > 0,
                    label.confidence == nil || label.confidence! < policy.minimumLabelConfidence
                {
                    reasons.append(.insufficientLabelConfidence)
                }
            }
            let identity = try analysis.map { try calibrationDigest($0) }
            if let analysis {
                if let observation = try? PersonalTargetObservation(take: take, analysis: analysis)
                {
                    reasons += observation.findings(policy: policy)
                    if reasons.isEmpty, let point = observation.values(policy: policy) {
                        let key = try analysis.key.identity()
                        if let previous = seen[key] {
                            if previous != identity {
                                groupReasons.append(.inconsistentAliasAnalysis)
                            }
                        } else {
                            seen[key] = identity!
                            values.append(point)
                        }
                    }
                } else {
                    reasons.append(.incompatibleAnalysis)
                }
            }
            reports.append(
                PersonalTargetTakeReport(
                    takeID: take.id, sessionID: member.sessionID, label: take.label?.preference,
                    labelConfidence: take.label?.confidence, analysisIdentity: identity,
                    coverage: assessment.coverage, reasons: targetReasons(reasons)))
            groupReasons += reasons
        }
        if reports.count > 1 && reports.contains(where: { !$0.reasons.isEmpty }) {
            groupReasons.append(.groupContainsRejectedTake)
        }
        let point =
            groupReasons.isEmpty && !values.isEmpty
            ? try PersonalTargetValues.groupMedian(values) : nil
        let domainReasons: Set<PersonalTargetReason> = [
            .differentTask, .differentProfile, .changedConditions, .unknownConditions,
            .conflictingGroupMetadata,
        ]
        return PersonalTargetGroupSummary(
            recordingGroup: group, sessionIDs: sessions, role: assigned[0].role,
            actual: actual, isInScope: !groupReasons.contains(where: domainReasons.contains),
            takes: reports, distinctAnalysisCount: seen.count,
            values: point, reasons: targetReasons(groupReasons))
    }
}
