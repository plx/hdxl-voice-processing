import Foundation

/// Maps one zero-based analysis continuity region to its original acquisition
/// clock. Capture configuration epochs and analysis continuity epochs are distinct:
/// a dropped chunk resets analysis without changing the capture token.
///
/// Optional clocks are projections from this anchor at the declared source rate.
/// They are not independently measured per-frame timestamps or drift correction.
public struct AnalysisScheduleOrigin: Sendable, Hashable, Codable {
    public let source: SourceInterval
    public let continuityEpoch: StreamEpoch
    public let sourceStartSeconds: Double?
    public let hostStartNanoseconds: UInt64?
    public let wallClockStartUnixSeconds: Double?

    public init(
        source: SourceInterval, continuityEpoch: StreamEpoch,
        sourceStartSeconds: Double? = nil, hostStartNanoseconds: UInt64? = nil,
        wallClockStartUnixSeconds: Double? = nil
    ) throws {
        guard source.sampleCount == 0, sourceStartSeconds?.isFinite != false,
            wallClockStartUnixSeconds?.isFinite != false
        else { throw AnalysisScheduleError.invalidClock }
        self.source = source
        self.continuityEpoch = continuityEpoch
        self.sourceStartSeconds = sourceStartSeconds.map { $0 == 0 ? 0 : $0 }
        self.hostStartNanoseconds = hostStartNanoseconds
        self.wallClockStartUnixSeconds = wallClockStartUnixSeconds.map { $0 == 0 ? 0 : $0 }
    }

    /// Integer support remains exact even when absolute floating-point seconds
    /// cannot distinguish neighboring source samples.
    public func sourceInterval(for analysis: SourceInterval) throws -> SourceInterval {
        guard analysis.epoch == continuityEpoch, analysis.sampleRate == source.sampleRate else {
            throw AnalysisScheduleError.unexpectedInput
        }
        let start = source.startSample.addingReportingOverflow(analysis.startSample)
        guard !start.overflow else { throw ContractError.arithmeticOverflow }
        return try SourceInterval(
            epoch: source.epoch, startSample: start.partialValue,
            sampleCount: analysis.sampleCount, sampleRate: source.sampleRate)
    }

    public func sourceSeconds(atAnalysisSample sample: Int64) throws -> Double? {
        try projectedSeconds(sourceStartSeconds, at: sample)
    }

    public func wallClockUnixSeconds(atAnalysisSample sample: Int64) throws -> Double? {
        try projectedSeconds(wallClockStartUnixSeconds, at: sample)
    }

    public func hostNanoseconds(atAnalysisSample sample: Int64) throws -> UInt64? {
        guard sample >= 0 else { throw AnalysisScheduleError.invalidClock }
        guard let anchor = hostStartNanoseconds else { return nil }
        // Split integer seconds before conversion, avoiding large integer-to-double
        // rounding of a small fractional offset. Scheduling supports integer-Hz input.
        guard let rate = Int64(exactly: source.sampleRate), rate > 0 else {
            throw AnalysisScheduleError.invalidClock
        }
        let seconds = UInt64(sample / rate)
        let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let fraction = (Double(sample % rate) * 1_000_000_000 / Double(rate))
            .rounded(.toNearestOrEven)
        guard !whole.overflow, let fractional = UInt64(exactly: fraction) else {
            throw AnalysisScheduleError.invalidClock
        }
        let offset = whole.partialValue.addingReportingOverflow(fractional)
        let result = anchor.addingReportingOverflow(offset.partialValue)
        guard !offset.overflow, !result.overflow else {
            throw AnalysisScheduleError.invalidClock
        }
        return result.partialValue
    }

    func mappedTiming(_ timing: AnalysisTiming) throws -> AnalysisTiming {
        let mapped = try sourceInterval(for: timing.source)
        return try AnalysisTiming(
            source: mapped, includedSampleCount: timing.includedSampleCount,
            sourceStartSeconds: sourceSeconds(atAnalysisSample: timing.source.startSample),
            hostStartNanoseconds: hostNanoseconds(atAnalysisSample: timing.source.startSample),
            completedHostNanoseconds: timing.completedHostNanoseconds,
            effectiveDelaySeconds: timing.effectiveDelaySeconds)
    }

    private func projectedSeconds(_ anchor: Double?, at sample: Int64) throws -> Double? {
        guard sample >= 0 else { throw AnalysisScheduleError.invalidClock }
        guard let anchor else { return nil }
        let value = anchor + Double(sample) / source.sampleRate
        guard value.isFinite else { throw AnalysisScheduleError.invalidClock }
        return value
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, continuityEpoch, sourceStartSeconds, hostStartNanoseconds
        case wallClockStartUnixSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard c.contains(.sourceStartSeconds), c.contains(.hostStartNanoseconds),
            c.contains(.wallClockStartUnixSeconds)
        else { throw AnalysisScheduleError.invalidClock }
        try self.init(
            source: c.decode(SourceInterval.self, forKey: .source),
            continuityEpoch: c.decode(StreamEpoch.self, forKey: .continuityEpoch),
            sourceStartSeconds: c.decodeIfPresent(Double.self, forKey: .sourceStartSeconds),
            hostStartNanoseconds: c.decodeIfPresent(UInt64.self, forKey: .hostStartNanoseconds),
            wallClockStartUnixSeconds: c.decodeIfPresent(
                Double.self, forKey: .wallClockStartUnixSeconds))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(continuityEpoch, forKey: .continuityEpoch)
        try c.encode(sourceStartSeconds, forKey: .sourceStartSeconds)
        try c.encode(hostStartNanoseconds, forKey: .hostStartNanoseconds)
        try c.encode(wallClockStartUnixSeconds, forKey: .wallClockStartUnixSeconds)
    }
}
