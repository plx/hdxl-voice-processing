import Foundation

/// Stream identity plus a continuity epoch; sample positions are local to this epoch.
public struct StreamEpoch: Sendable, Hashable, Codable {
    public let streamID: UUID
    public let sequence: UInt64

    public init(streamID: UUID, sequence: UInt64 = 0) {
        self.streamID = streamID
        self.sequence = sequence
    }

    public func successor() throws -> Self {
        let next = sequence.addingReportingOverflow(1)
        guard !next.overflow else { throw ContractError.arithmeticOverflow }
        return Self(streamID: streamID, sequence: next.partialValue)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case streamID, sequence }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        self.init(
            streamID: try c.decode(UUID.self, forKey: .streamID),
            sequence: try c.decode(UInt64.self, forKey: .sequence))
    }
}

/// A half-open interval in source sample frames, not interleaved scalar elements.
public struct SourceInterval: Sendable, Hashable, Codable {
    public let epoch: StreamEpoch
    public let startSample: Int64
    public let sampleCount: Int64
    public let sampleRate: Double
    public var endSample: Int64 { startSample + sampleCount }
    /// Subtract/count in integer space first: large absolute positions do not erase short durations.
    public var durationSeconds: Double { Double(sampleCount) / sampleRate }

    public init(epoch: StreamEpoch, startSample: Int64, sampleCount: Int64, sampleRate: Double)
        throws
    {
        guard startSample >= 0, sampleCount >= 0, sampleRate.isFinite, sampleRate > 0 else {
            throw ContractError.invalidInterval
        }
        guard !startSample.addingReportingOverflow(sampleCount).overflow else {
            throw ContractError.arithmeticOverflow
        }
        guard (Double(sampleCount) / sampleRate).isFinite,
            (Double(startSample + sampleCount) / sampleRate).isFinite
        else { throw ContractError.invalidInterval }
        self.epoch = epoch
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case epoch, startSample, sampleCount, sampleRate
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            epoch: c.decode(StreamEpoch.self, forKey: .epoch),
            startSample: c.decode(Int64.self, forKey: .startSample),
            sampleCount: c.decode(Int64.self, forKey: .sampleCount),
            sampleRate: c.decode(Double.self, forKey: .sampleRate))
    }
}

/// Source support and coverage are independent of processing completion and display delay.
public struct AnalysisTiming: Sendable, Hashable, Codable {
    public let source: SourceInterval
    public let includedSampleCount: Int64
    /// Source-clock seconds at `source.startSample`, if the host supplies an anchor.
    public let sourceStartSeconds: Double?
    /// Monotonic host nanoseconds at the first source sample; not raw mach ticks.
    public let hostStartNanoseconds: UInt64?
    public let completedHostNanoseconds: UInt64?
    /// Algorithmic delay, including lookahead/filter delay; never changes source identity.
    public let effectiveDelaySeconds: Double
    public var measuredWindowSamples: Int64 { source.sampleCount }
    public var excludedSampleCount: Int64 { source.sampleCount - includedSampleCount }
    public var includedDurationSeconds: Double { Double(includedSampleCount) / source.sampleRate }
    public var excludedDurationSeconds: Double { Double(excludedSampleCount) / source.sampleRate }
    /// Empty support has zero coverage, never NaN and never an implicit successful interval.
    public var coverage: Double {
        source.sampleCount == 0 ? 0 : Double(includedSampleCount) / Double(source.sampleCount)
    }
    /// Center of source support, not the completion time. Large absolute doubles are approximate.
    public var displayTimeSeconds: Double {
        (sourceStartSeconds ?? Double(source.startSample) / source.sampleRate) + source
            .durationSeconds / 2
    }

    public init(
        source: SourceInterval, includedSampleCount: Int64, sourceStartSeconds: Double? = nil,
        hostStartNanoseconds: UInt64? = nil, completedHostNanoseconds: UInt64? = nil,
        effectiveDelaySeconds: Double = 0
    ) throws {
        guard (0...source.sampleCount).contains(includedSampleCount) else {
            throw ContractError.invalidCoverage
        }
        guard effectiveDelaySeconds.isFinite, effectiveDelaySeconds >= 0,
            sourceStartSeconds?.isFinite != false,
            ((sourceStartSeconds ?? Double(source.startSample) / source.sampleRate) + source
                .durationSeconds / 2).isFinite
        else { throw ContractError.invalidTiming }
        if let start = hostStartNanoseconds, let end = completedHostNanoseconds, end < start {
            throw ContractError.invalidTiming
        }
        self.source = source
        self.includedSampleCount = includedSampleCount
        self.sourceStartSeconds = sourceStartSeconds
        self.hostStartNanoseconds = hostStartNanoseconds
        self.completedHostNanoseconds = completedHostNanoseconds
        self.effectiveDelaySeconds = effectiveDelaySeconds == 0 ? 0 : effectiveDelaySeconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, includedSampleCount, sourceStartSeconds, hostStartNanoseconds
        case completedHostNanoseconds, effectiveDelaySeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            source: c.decode(SourceInterval.self, forKey: .source),
            includedSampleCount: c.decode(Int64.self, forKey: .includedSampleCount),
            sourceStartSeconds: c.decodeIfPresent(Double.self, forKey: .sourceStartSeconds),
            hostStartNanoseconds: c.decodeIfPresent(UInt64.self, forKey: .hostStartNanoseconds),
            completedHostNanoseconds: c.decodeIfPresent(
                UInt64.self, forKey: .completedHostNanoseconds),
            effectiveDelaySeconds: c.decode(Double.self, forKey: .effectiveDelaySeconds))
    }
}
