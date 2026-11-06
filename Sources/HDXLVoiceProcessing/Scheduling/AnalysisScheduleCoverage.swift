import CryptoKit
import Foundation

/// Unique source samples, not a sum of overlapping frame windows. Evidence tags
/// may overlap; pitch availability never changes these selection/evidence counts.
public struct AnalysisCoverageCounts: Sendable, Hashable {
    public internal(set) var source: Int64 = 0
    public internal(set) var eligible: Int64 = 0
    public internal(set) var selected: Int64 = 0
    public var missing: Int64 { source - eligible }
    public var excludedEligible: Int64 { eligible - selected }
    public var sourceCoverage: Double { source == 0 ? 0 : Double(selected) / Double(source) }
    public var eligibleCoverage: Double { eligible == 0 ? 0 : Double(selected) / Double(eligible) }
    private var missingAcquisition: Int64 = 0
    private var silence: Int64 = 0
    private var suspectedExternalNoise: Int64 = 0
    private var clipping: Int64 = 0
    private var speechDetected: Int64 = 0
    private var nonSpeechDetected: Int64 = 0
    private var lowPeriodicityConfidence: Int64 = 0
    private var algorithmInsufficiency: Int64 = 0
    private var energyEligible: Int64 = 0
    private var energyIneligible: Int64 = 0

    public func samples(tag: MaskTag) -> Int64 {
        switch tag {
        case .missingAcquisition: missingAcquisition
        case .silence: silence
        case .suspectedExternalNoise: suspectedExternalNoise
        case .clipping: clipping
        case .speechDetected: speechDetected
        case .nonSpeechDetected: nonSpeechDetected
        case .lowPeriodicityConfidence: lowPeriodicityConfidence
        case .algorithmInsufficiency: algorithmInsufficiency
        case .energyEligible: energyEligible
        case .energyIneligible: energyIneligible
        }
    }

    package static func acquired(_ count: Int64) -> Self {
        var result = Self()
        result.source = count
        result.eligible = count
        result.selected = count
        return result
    }

    fileprivate mutating func add(_ segment: MaskSegment, count: Int64) {
        source += count
        if segment.isEligible { eligible += count }
        if segment.isSelected { selected += count }
        for tag in segment.tags {
            switch tag {
            case .missingAcquisition: missingAcquisition += count
            case .silence: silence += count
            case .suspectedExternalNoise: suspectedExternalNoise += count
            case .clipping: clipping += count
            case .speechDetected: speechDetected += count
            case .nonSpeechDetected: nonSpeechDetected += count
            case .lowPeriodicityConfidence: lowPeriodicityConfidence += count
            case .algorithmInsufficiency: algorithmInsufficiency += count
            case .energyEligible: energyEligible += count
            case .energyIneligible: energyIneligible += count
            }
        }
    }

    fileprivate func subtracting(_ other: Self) -> Self {
        var result = Self()
        result.source = source - other.source
        result.eligible = eligible - other.eligible
        result.selected = selected - other.selected
        result.missingAcquisition = missingAcquisition - other.missingAcquisition
        result.silence = silence - other.silence
        result.suspectedExternalNoise = suspectedExternalNoise - other.suspectedExternalNoise
        result.clipping = clipping - other.clipping
        result.speechDetected = speechDetected - other.speechDetected
        result.nonSpeechDetected = nonSpeechDetected - other.nonSpeechDetected
        result.lowPeriodicityConfidence = lowPeriodicityConfidence - other.lowPeriodicityConfidence
        result.algorithmInsufficiency = algorithmInsufficiency - other.algorithmInsufficiency
        result.energyEligible = energyEligible - other.energyEligible
        result.energyIneligible = energyIneligible - other.energyIneligible
        return result
    }
}

/// Identity covers the complete immutable mask plan, including its source and
/// annotations. Scope distinguishes raw acquired diagnostics from selected analysis.
public struct AnalysisMaskProvenance: Sendable, Hashable {
    public let planIdentity: ProfileIdentity
    public let scope: MaskAnalysisScope
    public let policy: MaskSelectionPolicy
    public let sources: [MaskProvenance]
    public let effectiveDelaySeconds: Double
}

/// Prepare on a control/worker path. Prefix counts give bounded O(log segments)
/// coverage queries without per-frame allocations, even for long tracker support.
/// This consumes a resolved mask; it performs no detection or inferred labelling.
public struct PreparedAnalysisMask: Sendable {
    public let timeline: MaskTimeline
    public let provenance: AnalysisMaskProvenance
    private let prefixes: [AnalysisCoverageCounts]
    public var preparedCountBytes: Int {
        prefixes.count * MemoryLayout<AnalysisCoverageCounts>.stride
    }

    public init(timeline: MaskTimeline, scope: MaskAnalysisScope) throws {
        self.timeline = timeline
        provenance = try AnalysisMaskProvenance(
            planIdentity: ProfileIdentity(
                identifier: VersionedIdentifier(name: "analysis-mask-plan", version: 1),
                sha256: SHA256.hash(data: timeline.plan.canonicalJSON()).map {
                    String(format: "%02x", $0)
                }.joined()),
            scope: scope, policy: timeline.plan.policy, sources: timeline.plan.provenances,
            effectiveDelaySeconds: timeline.plan.effectiveDelaySeconds)
        var prefixes: [AnalysisCoverageCounts] = []
        prefixes.reserveCapacity(timeline.segments.count + 1)
        var total = AnalysisCoverageCounts()
        prefixes.append(total)
        for segment in timeline.segments {
            total.add(segment, count: segment.source.sampleCount)
            prefixes.append(total)
        }
        self.prefixes = prefixes
    }

    public var regions: [SourceInterval] {
        provenance.scope == .selected ? timeline.selectedRegions : timeline.eligibleRegions
    }

    public func coverage(of source: SourceInterval) throws -> AnalysisCoverageCounts {
        let plan = timeline.plan.source
        guard source.epoch == plan.epoch, source.sampleRate == plan.sampleRate,
            source.startSample >= plan.startSample, source.endSample <= plan.endSample
        else { throw AnalysisScheduleError.unexpectedInput }
        return prefix(at: source.endSample).subtracting(prefix(at: source.startSample))
    }

    func validateRegion(_ source: SourceInterval) throws {
        let index =
            try provenance.scope == .selected
            ? timeline.selectedRegion(containing: source)
            : timeline.eligibleRegion(containing: source)
        guard source.sampleCount == 0 || index != nil else {
            throw AnalysisScheduleError.invalidGap
        }
    }

    private func prefix(at sample: Int64) -> AnalysisCoverageCounts {
        let segments = timeline.segments
        var low = 0
        var high = segments.count
        while low < high {
            let middle = low + (high - low) / 2
            if segments[middle].source.endSample <= sample {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var result = prefixes[low]
        if low < segments.count {
            result.add(segments[low], count: sample - segments[low].source.startSample)
        }
        return result
    }
}
