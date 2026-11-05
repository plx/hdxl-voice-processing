import Foundation

private struct RollingCPPSEntry {
    let centerSample: Int64
    let source: SourceInterval
    let value: Double
}

/// A source-clock query, with window coverage separate from the full dependencies
/// of its contributing frames. Means give each eligible frame equal weight.
public struct CPPSRollingResult: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let window: SourceInterval
    public let timing: AnalysisTiming
    public let eligibleSampleCount: Int64
    public let selectedSampleCount: Int64
    public let observedSampleCountInWindow: Int64
    public let contributingFrameCount: Int
    public let latestFrameAgeSeconds: Double?
    public let meanDB: Double?
    public let unavailability: UnavailabilityReason?

    public func measurementResult() throws -> MeasurementResult {
        let outcome: MeasurementOutcome
        if let meanDB {
            outcome = .available(
                try ScalarEstimate(
                    value: meanDB,
                    warnings: observedSampleCountInWindow == window.sampleCount
                        ? [] : [.partialCoverage]))
        } else {
            outcome = .unavailable(unavailability ?? .analysisFailure)
        }
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .cpps, unit: .decibelsRatio, algorithm: profile.identifier),
            profile: profile, timing: timing, outcome: outcome)
    }
}

/// Bounded 1–5 second frame statistics. Pass the current immutable mask at query
/// time so a revised selection cannot leave previously selected scores active.
/// The mask must cover the query window; only frames whose complete dependencies
/// lie in one selected region contribute. No PCM or cepstral bins are retained.
///
/// Centers are floored to source-sample ticks; the window is [start, query). Query
/// clocks never move backwards. A current excluded/missing segment or the latest
/// unavailable frame suppresses the number. Scores also expire with the window;
/// age is always explicit. Reset clears all history across a continuity epoch.
public final class PreparedRollingCPPS {
    public let profile: CPPSStatisticProfile
    public let identity: ProfileIdentity
    public let frameCapacity: Int
    public let windowSampleCount: Int64
    public private(set) var origin: SourceInterval
    public var recordWorkspaceBytes: Int { entries.count * MemoryLayout<RollingCPPSEntry?>.stride }
    private let measurementIdentity: ProfileIdentity
    private var entries: [RollingCPPSEntry?]
    private var head = 0
    private var count = 0
    private var latestCenter: Int64?
    private var latestOrigin: SourceInterval?
    private var latestIndex: UInt64?
    private var latestReason: UnavailabilityReason?
    private var latestSupportStart: Int64?
    private var latestSupport: SourceInterval?
    private var queryClock: Int64
    private var hadAvailableFrame = false
    private let diagnostics: WorkerDiagnostics

    public convenience init(profile: CPPSStatisticProfile, origin: SourceInterval) throws {
        try self.init(profile: profile, origin: origin, diagnostics: WorkerDiagnostics())
    }
    package init(
        profile: CPPSStatisticProfile, origin: SourceInterval, diagnostics: WorkerDiagnostics
    ) throws {
        guard profile.aggregation == .rollingFrameMean, let seconds = profile.rollingWindowSeconds,
            origin.sampleCount == 0,
            origin.sampleRate
                == Double(profile.measurement.cepstrogram.conditioning.sourceSampleRate)
        else { throw CPPSError.invalidConfiguration }
        self.profile = profile
        self.origin = origin
        queryClock = origin.startSample
        identity = try profile.identity()
        measurementIdentity = try profile.measurement.identity()
        windowSampleCount = Int64(ceil(seconds * origin.sampleRate))
        frameCapacity = Int(ceil(seconds / profile.measurement.cepstrogram.hopSeconds)) + 2
        guard frameCapacity <= 50_002 else { throw CPPSError.capacityExceeded }
        entries = Array(repeating: nil, count: frameCapacity)
        self.diagnostics = diagnostics
    }

    public func append(_ frame: CPPSFrameResult) throws {
        guard frame.profile == measurementIdentity else { throw CPPSError.profileMismatch }
        let context = frame.context
        guard context.origin.epoch == origin.epoch, context.origin.sampleRate == origin.sampleRate,
            context.origin.startSample >= origin.startSample,
            context.timing.source.startSample >= (latestSupportStart ?? origin.startSample)
        else { throw CPPSError.unexpectedFrame }
        let offset = floor(context.centerSecondsFromOrigin * origin.sampleRate)
        guard offset.isFinite, offset >= 0, offset < Double(Int64.max) else {
            throw CPPSError.unexpectedFrame
        }
        let addition = context.origin.startSample.addingReportingOverflow(Int64(offset))
        guard !addition.overflow else { throw CPPSError.unexpectedFrame }
        let center = addition.partialValue
        guard center >= (latestCenter ?? origin.startSample) else {
            throw CPPSError.unexpectedFrame
        }
        if context.origin == latestOrigin, let latestIndex {
            guard context.frameIndex > latestIndex else { throw CPPSError.unexpectedFrame }
        }
        let cutoff = max(
            origin.startSample,
            max(center, queryClock) - min(max(center, queryClock), windowSampleCount))
        expire(before: cutoff)
        if let observation = frame.observation, center >= cutoff {
            guard count < frameCapacity else { throw CPPSError.capacityExceeded }
            entries[(head + count) % frameCapacity] = RollingCPPSEntry(
                centerSample: center,
                source: context.timing.source, value: observation.prominenceDB)
            count += 1
            hadAvailableFrame = true
        }
        latestCenter = center
        latestOrigin = context.origin
        latestIndex = context.frameIndex
        latestReason = frame.unavailability
        latestSupportStart = context.timing.source.startSample
        latestSupport = context.timing.source
    }

    public func result(atSourceSample clock: Int64, mask: MaskTimeline) throws -> CPPSRollingResult
    {
        try profile.validate(mask)
        guard clock >= queryClock, clock >= origin.startSample,
            latestCenter.map({ clock > $0 }) ?? true,
            latestSupport.map({ clock >= $0.endSample }) ?? true,
            mask.plan.source.epoch == origin.epoch
        else { throw CPPSError.unexpectedFrame }
        let start = max(origin.startSample, clock - min(clock, windowSampleCount))
        guard mask.plan.source.startSample <= start, mask.plan.source.endSample >= clock else {
            throw CPPSError.incompleteInput
        }
        let window = try SourceInterval(
            epoch: origin.epoch, startSample: start,
            sampleCount: clock - start, sampleRate: origin.sampleRate)
        queryClock = clock
        expire(before: start)
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 3701
        metadata.frameSequence = latestIndex ?? 0
        metadata.sampleCount = UInt32(clamping: count)
        return try diagnostics.withFrame(metadata) {
            try diagnostics.withInterval(.cppsAggregation) {
                var eligible: Int64 = 0
                var selected: Int64 = 0
                var currentReason: UnavailabilityReason?
                for segment in mask.segments {
                    let length = max(
                        0,
                        min(clock, segment.source.endSample)
                            - max(start, segment.source.startSample)
                    )
                    if segment.isEligible { eligible += length }
                    if segment.isSelected { selected += length }
                    if clock > start, segment.source.startSample < clock,
                        segment.source.endSample >= clock
                    {
                        if !segment.isEligible {
                            currentReason = .missingAcquisition
                        } else if !segment.isSelected {
                            currentReason = .excluded
                        }
                    }
                }
                var included = 0
                var sum = 0.0
                var correction = 0.0
                var supportStart: Int64?
                var supportEnd: Int64 = 0
                var supportCount: Int64 = 0
                var observedEnd = start
                var observed: Int64 = 0
                for index in 0..<count {
                    guard let entry = entries[(head + index) % frameCapacity] else {
                        throw CPPSError.invalidState
                    }
                    guard entry.source.startSample >= mask.plan.source.startSample,
                        entry.source.endSample <= mask.plan.source.endSample,
                        try mask.selectedRegion(containing: entry.source) != nil
                    else { continue }
                    let adjusted = entry.value - correction
                    let next = sum + adjusted
                    correction = (next - sum) - adjusted
                    sum = next
                    included += 1
                    if supportStart == nil {
                        supportStart = entry.source.startSample
                        supportEnd = entry.source.startSample
                    }
                    supportCount += max(
                        0, entry.source.endSample - max(entry.source.startSample, supportEnd))
                    supportEnd = max(supportEnd, entry.source.endSample)
                    let left = max(start, entry.source.startSample)
                    let right = min(clock, entry.source.endSample)
                    observed += max(0, right - max(left, observedEnd))
                    observedEnd = max(observedEnd, right)
                }
                let reason: UnavailabilityReason?
                let currentRegion =
                    clock > start
                    ? try mask.selectedRegion(
                        containing:
                            SourceInterval(
                                epoch: origin.epoch, startSample: clock - 1, sampleCount: 1,
                                sampleRate: origin.sampleRate)) : nil
                let latestRegion: Int?
                if let latestSupport, latestSupport.startSample >= mask.plan.source.startSample,
                    latestSupport.endSample <= mask.plan.source.endSample
                {
                    latestRegion = try mask.selectedRegion(containing: latestSupport)
                } else {
                    latestRegion = nil
                }
                if window.sampleCount == 0 {
                    reason = .insufficientData
                } else if let currentReason {
                    reason = currentReason
                } else if let latestReason, let latestCenter, latestCenter >= start {
                    reason = latestReason
                } else if included == 0 {
                    reason = hadAvailableFrame ? .stale : .insufficientData
                } else if latestRegion != currentRegion {
                    reason = .insufficientData
                } else {
                    reason = nil
                }
                let support = try SourceInterval(
                    epoch: origin.epoch, startSample: supportStart ?? start,
                    sampleCount: supportStart.map { supportEnd - $0 } ?? window.sampleCount,
                    sampleRate: origin.sampleRate)
                let timing = try AnalysisTiming(
                    source: support, includedSampleCount: reason == nil ? supportCount : 0,
                    effectiveDelaySeconds: max(
                        0,
                        Double(clock - support.startSample) / origin.sampleRate - support
                            .durationSeconds / 2))
                return CPPSRollingResult(
                    profile: identity, window: window, timing: timing,
                    eligibleSampleCount: eligible, selectedSampleCount: selected,
                    observedSampleCountInWindow: observed, contributingFrameCount: included,
                    latestFrameAgeSeconds: latestCenter.map {
                        Double(clock - $0) / origin.sampleRate
                    },
                    meanDB: reason == nil ? sum / Double(included) : nil, unavailability: reason)
            }
        }
    }

    public func reset(origin: SourceInterval) throws {
        guard origin.sampleCount == 0, origin.sampleRate == self.origin.sampleRate else {
            throw CPPSError.invalidConfiguration
        }
        self.origin = origin
        queryClock = origin.startSample
        head = 0
        count = 0
        latestCenter = nil
        latestOrigin = nil
        latestIndex = nil
        latestReason = nil
        latestSupportStart = nil
        latestSupport = nil
        hadAvailableFrame = false
        for index in entries.indices { entries[index] = nil }
        diagnostics.reset()
    }
    private func expire(before start: Int64) {
        while count > 0, let entry = entries[head], entry.centerSample < start {
            entries[head] = nil
            head = (head + 1) % frameCapacity
            count -= 1
        }
    }
}
