import Foundation

public enum MaskExclusionReason: String, Sendable, Hashable, Codable {
    case missingAcquisition, sourceRejected, sourceUnspecified, rejectedTag
}

/// A partition of the original timeline, never a newly concatenated signal.
public struct MaskSegment: Sendable, Hashable, Encodable {
    public let source: SourceInterval
    public let isEligible: Bool
    public let isSelected: Bool
    public let tags: [MaskTag]
    public let exclusions: [MaskExclusionReason]
}

/// Each tag's durations are unions within that category. Different tags can
/// overlap, so their counts must not be added to obtain overall coverage.
public struct MaskTagCoverage: Sendable, Hashable, Encodable {
    public let tag: MaskTag
    public let sampleCount: Int64
    public let eligibleSampleCount: Int64
    public let selectedSampleCount: Int64
    public let durationSeconds: Double
    public let eligibleDurationSeconds: Double
    public let selectedDurationSeconds: Double
}

/// source = missing + eligible; eligible = selected + excluded.
/// Empty source/eligibility gives zero fractions, never NaN or a favorable score.
public struct MaskCoverage: Sendable, Hashable, Encodable {
    public let sourceSampleCount: Int64
    public let missingSampleCount: Int64
    public let eligibleSampleCount: Int64
    public let selectedSampleCount: Int64
    public let excludedEligibleSampleCount: Int64
    public let sourceDurationSeconds: Double
    public let missingDurationSeconds: Double
    public let eligibleDurationSeconds: Double
    public let selectedDurationSeconds: Double
    public let excludedEligibleDurationSeconds: Double
    /// Selected / entire source, including acquisition gaps in the denominator.
    public let sourceCoverage: Double
    /// Selected / acquired samples. This is separate from sourceCoverage.
    public let eligibleCoverage: Double
    public let tags: [MaskTagCoverage]
}

private struct MaskEvent {
    let position: Int64
    let observation: Int
    let delta: Int
}

/// Resolved immutable report. Codable input is MaskPlan; this export includes
/// that complete input plus derived partitions, regions, and coverage diagnostics.
/// Resolution allocates and sorts; prepared PCM routing is a separate operation.
public struct MaskTimeline: Sendable, Hashable, Encodable {
    public let plan: MaskPlan
    public let segments: [MaskSegment]
    public let eligibleRegions: [SourceInterval]
    public let selectedRegions: [SourceInterval]
    public let coverage: MaskCoverage

    public init(_ plan: MaskPlan) throws {
        try self.init(plan, diagnostics: WorkerDiagnostics())
    }

    package init(_ plan: MaskPlan, diagnostics: WorkerDiagnostics) throws {
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 3403
        metadata.frameSequence = 0
        metadata.sampleCount = UInt32(clamping: plan.source.sampleCount)
        self = try diagnostics.withFrame(metadata) {
            try diagnostics.withInterval(.maskResolution) { try Self(resolving: plan) }
        }
    }

    private init(resolving plan: MaskPlan) throws {
        var events: [MaskEvent] = []
        events.reserveCapacity(plan.observations.count * 2)
        for (index, observation) in plan.observations.enumerated() {
            events.append(
                MaskEvent(position: observation.source.startSample, observation: index, delta: 1))
            events.append(
                MaskEvent(position: observation.source.endSample, observation: index, delta: -1))
        }
        events.sort { $0.position < $1.position }
        var positives = Array(repeating: 0, count: plan.provenances.count)
        var negatives = positives
        let tagOrder = MaskTag.allCases
        let tagIndices = Dictionary(uniqueKeysWithValues: tagOrder.enumerated().map { ($1, $0) })
        var activeTags = Array(repeating: 0, count: tagOrder.count)
        var result: [MaskSegment] = []
        var eventIndex = 0
        var position = plan.source.startSample
        while position < plan.source.endSample {
            while eventIndex < events.count, events[eventIndex].position == position {
                let event = events[eventIndex]
                let observation = plan.observations[event.observation]
                switch observation.selection {
                case .selected: positives[observation.provenanceIndex] += event.delta
                case .rejected: negatives[observation.provenanceIndex] += event.delta
                case .unspecified: break
                }
                for tag in observation.tags { activeTags[tagIndices[tag]!] += event.delta }
                eventIndex += 1
            }
            let end =
                eventIndex < events.count ? events[eventIndex].position : plan.source.endSample
            let tags = tagOrder.enumerated().compactMap {
                activeTags[$0.offset] > 0 ? $0.element : nil
            }
            .sorted { $0.rawValue < $1.rawValue }
            let eligible = !tags.contains(.missingAcquisition)
            var passedSources = 0
            var rejectedSources = 0
            var unspecifiedSources = 0
            for index in plan.policy.selectionSources {
                if negatives[index] > 0 {
                    rejectedSources += 1
                } else if positives[index] > 0 {
                    passedSources += 1
                } else {
                    unspecifiedSources += 1
                }
            }
            let sourceSelected =
                plan.policy.selectionSources.isEmpty
                || (plan.policy.combination == .all
                    ? passedSources == plan.policy.selectionSources.count : passedSources > 0)
            let tagRejected = plan.policy.rejectedTags.contains { tags.contains($0) }
            let selected = eligible && sourceSelected && !tagRejected
            var exclusions: [MaskExclusionReason] = []
            if !eligible { exclusions.append(.missingAcquisition) }
            if !sourceSelected {
                if rejectedSources > 0 { exclusions.append(.sourceRejected) }
                if unspecifiedSources > 0 { exclusions.append(.sourceUnspecified) }
            }
            if tagRejected { exclusions.append(.rejectedTag) }
            let start: Int64
            if let last = result.last, last.isEligible == eligible, last.isSelected == selected,
                last.tags == tags, last.exclusions == exclusions
            {
                start = last.source.startSample
                result.removeLast()
            } else {
                start = position
            }
            let interval = try SourceInterval(
                epoch: plan.source.epoch, startSample: start, sampleCount: end - start,
                sampleRate: plan.source.sampleRate)
            result.append(
                MaskSegment(
                    source: interval, isEligible: eligible, isSelected: selected,
                    tags: tags, exclusions: exclusions))
            position = end
        }
        self.plan = plan
        segments = result
        eligibleRegions = try Self.regions(in: result, selected: false)
        selectedRegions = try Self.regions(in: result, selected: true)
        coverage = Self.coverage(source: plan.source, segments: result)
    }

    public func canonicalJSON() throws -> Data { try canonicalContractJSON(self) }

    /// Pass the kernel's entire dependency support, including conditioning and
    /// smoothing support. A frame spanning a selection gap has no selected region.
    /// A center-only membership test is insufficient for safe kernel selection.
    public func selectedRegion(containing support: SourceInterval) throws -> Int? {
        try region(containing: support, in: selectedRegions)
    }

    /// Raw/all-eligible analysis still cannot span missing acquisition.
    public func eligibleRegion(containing support: SourceInterval) throws -> Int? {
        try region(containing: support, in: eligibleRegions)
    }

    private func region(containing support: SourceInterval, in regions: [SourceInterval]) throws
        -> Int?
    {
        guard support.epoch == plan.source.epoch, support.sampleRate == plan.source.sampleRate,
            support.startSample >= plan.source.startSample,
            support.endSample <= plan.source.endSample
        else { throw MaskError.unexpectedInterval }
        guard support.sampleCount > 0 else { return nil }
        var low = 0
        var high = regions.count
        while low < high {
            let middle = low + (high - low) / 2
            if regions[middle].endSample <= support.startSample {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < regions.count, regions[low].startSample <= support.startSample,
            regions[low].endSample >= support.endSample
        else { return nil }
        return low
    }

    private static func regions(in segments: [MaskSegment], selected: Bool) throws
        -> [SourceInterval]
    {
        var result: [SourceInterval] = []
        for segment in segments where selected ? segment.isSelected : segment.isEligible {
            if let last = result.last, last.endSample == segment.source.startSample {
                result[result.count - 1] = try SourceInterval(
                    epoch: last.epoch, startSample: last.startSample,
                    sampleCount: segment.source.endSample - last.startSample,
                    sampleRate: last.sampleRate)
            } else {
                result.append(segment.source)
            }
        }
        return result
    }

    private static func coverage(source: SourceInterval, segments: [MaskSegment]) -> MaskCoverage {
        var eligible: Int64 = 0
        var selected: Int64 = 0
        var tagTotals = Array(repeating: Int64(0), count: MaskTag.allCases.count)
        var tagEligible = tagTotals
        var tagSelected = tagTotals
        for segment in segments {
            let count = segment.source.sampleCount
            if segment.isEligible { eligible += count }
            if segment.isSelected { selected += count }
            for (index, tag) in MaskTag.allCases.enumerated() where segment.tags.contains(tag) {
                tagTotals[index] += count
                if segment.isEligible { tagEligible[index] += count }
                if segment.isSelected { tagSelected[index] += count }
            }
        }
        let rate = source.sampleRate
        let tags = MaskTag.allCases.enumerated().map { index, tag in
            MaskTagCoverage(
                tag: tag, sampleCount: tagTotals[index], eligibleSampleCount: tagEligible[index],
                selectedSampleCount: tagSelected[index],
                durationSeconds: Double(tagTotals[index]) / rate,
                eligibleDurationSeconds: Double(tagEligible[index]) / rate,
                selectedDurationSeconds: Double(tagSelected[index]) / rate)
        }
        return MaskCoverage(
            sourceSampleCount: source.sampleCount,
            missingSampleCount: source.sampleCount - eligible,
            eligibleSampleCount: eligible, selectedSampleCount: selected,
            excludedEligibleSampleCount: eligible - selected,
            sourceDurationSeconds: source.durationSeconds,
            missingDurationSeconds: Double(source.sampleCount - eligible) / rate,
            eligibleDurationSeconds: Double(eligible) / rate,
            selectedDurationSeconds: Double(selected) / rate,
            excludedEligibleDurationSeconds: Double(eligible - selected) / rate,
            sourceCoverage: source.sampleCount == 0
                ? 0 : Double(selected) / Double(source.sampleCount),
            eligibleCoverage: eligible == 0 ? 0 : Double(selected) / Double(eligible), tags: tags)
    }
}
