import Foundation

/// Portable decoder identity. No private URL, filename or audio is serialized.
public struct CalibrationDecoderProvenance: Sendable, Hashable, Codable {
    public let identifier: String
    public let runtime: String
    public let storage: [String: ProfileSetting]
    public let decodedPCM: PCMFormat
    public let fileSampleCount: Int64

    public init(
        identifier: String, runtime: String, storage: [String: ProfileSetting],
        decodedPCM: PCMFormat, fileSampleCount: Int64
    ) throws {
        guard validContractIdentifier(identifier), fileSampleCount >= 0,
            storage.count <= 32, storage.keys.allSatisfy(validContractIdentifier)
        else { throw CalibrationError.invalidRecord }
        self.identifier = identifier
        self.runtime = try calibrationText(runtime, allowEmpty: false)
        self.storage = try storage.mapValues { try $0.validated() }
        self.decodedPCM = decodedPCM
        self.fileSampleCount = fileSampleCount
        guard try canonicalContractJSON(self.storage).count <= 16 * 1024 else {
            throw CalibrationError.capacityExceeded
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier, runtime, storage, decodedPCM, fileSampleCount
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            identifier: c.decode(String.self, forKey: .identifier),
            runtime: c.decode(String.self, forKey: .runtime),
            storage: c.decode([String: ProfileSetting].self, forKey: .storage),
            decodedPCM: c.decode(PCMFormat.self, forKey: .decodedPCM),
            fileSampleCount: c.decode(Int64.self, forKey: .fileSampleCount))
    }
}

/// Exact numerical reuse identity. Labels, production instructions and host
/// conditions are deliberately separate; a fitted dataset binds those as well.
/// Constructing this value does not verify media bytes. The Audio adapter does.
public struct CalibrationAnalysisKey: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let implementation: VersionedIdentifier
    public let audio: CalibrationDigest
    public let audioByteCount: Int64
    public let profile: ProfileIdentity
    public let source: SourceInterval
    public let selection: CalibrationDigest
    public let decoder: CalibrationDecoderProvenance

    /// Bump for any change to decoding, selection, metric extraction or summaries
    /// that could change these records without changing the executable profile.
    public static var currentImplementation: VersionedIdentifier {
        // This literal is a valid contract identifier and positive version.
        try! VersionedIdentifier(name: "calibration-clip-analysis", version: 1)
    }

    public init(take: CalibrationTake, decoder: CalibrationDecoderProvenance) throws {
        guard decoder.decodedPCM == take.profile.inputFormat,
            take.source.endSample <= decoder.fileSampleCount
        else { throw CalibrationError.incompatibleDataset }
        try self.init(
            implementation: Self.currentImplementation, audio: take.media.content,
            audioByteCount: take.media.byteCount, profile: take.profileIdentity,
            source: take.source,
            selection: CalibrationDigest(bytes: take.effectiveMaskPlan().canonicalJSON()),
            decoder: decoder)
    }

    private init(
        implementation: VersionedIdentifier, audio: CalibrationDigest, audioByteCount: Int64,
        profile: ProfileIdentity, source: SourceInterval, selection: CalibrationDigest,
        decoder: CalibrationDecoderProvenance
    ) throws {
        guard audioByteCount >= 0, source.endSample <= decoder.fileSampleCount,
            source.sampleRate == decoder.decodedPCM.sampleRate
        else { throw CalibrationError.invalidRecord }
        schemaVersion = 1
        self.implementation = implementation
        self.audio = audio
        self.audioByteCount = audioByteCount
        self.profile = profile
        self.source = source
        self.selection = selection
        self.decoder = decoder
    }

    public func identity() throws -> CalibrationDigest { try calibrationDigest(self) }

    /// Metadata compatibility only. Before reuse, validate the current bytes and
    /// construct a new key from the actual decoder, then compare the entire key.
    public func matches(_ take: CalibrationTake) throws -> Bool {
        guard decoder.decodedPCM == take.profile.inputFormat,
            take.source.endSample <= decoder.fileSampleCount
        else { return false }
        return try self == Self(take: take, decoder: decoder)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, implementation, audio, audioByteCount, profile, source, selection,
            decoder
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            implementation: c.decode(VersionedIdentifier.self, forKey: .implementation),
            audio: c.decode(CalibrationDigest.self, forKey: .audio),
            audioByteCount: c.decode(Int64.self, forKey: .audioByteCount),
            profile: c.decode(ProfileIdentity.self, forKey: .profile),
            source: c.decode(SourceInterval.self, forKey: .source),
            selection: c.decode(CalibrationDigest.self, forKey: .selection),
            decoder: c.decode(CalibrationDecoderProvenance.self, forKey: .decoder))
    }
}

/// Unique source positions, independent of overlapping windows and label choice.
public struct CalibrationCoverage: Sendable, Hashable, Codable {
    public let source: Int64
    public let eligible: Int64
    public let selected: Int64
    /// Independent tag counts may overlap and must not be added to infer coverage.
    public let tags: [String: Int64]
    public var missing: Int64 { source - eligible }
    public var excludedEligible: Int64 { eligible - selected }
    public var selectedFraction: Double { source == 0 ? 0 : Double(selected) / Double(source) }

    public init(_ counts: AnalysisCoverageCounts) throws {
        try self.init(
            source: counts.source, eligible: counts.eligible, selected: counts.selected,
            tags: Dictionary(
                uniqueKeysWithValues: MaskTag.allCases.map {
                    ($0.rawValue, counts.samples(tag: $0))
                }))
    }

    private init(source: Int64, eligible: Int64, selected: Int64, tags: [String: Int64]) throws {
        guard source >= 0, (0...source).contains(eligible), (0...eligible).contains(selected),
            Set(tags.keys) == Set(MaskTag.allCases.map(\.rawValue)),
            tags.values.allSatisfy({ (0...source).contains($0) }),
            tags[MaskTag.missingAcquisition.rawValue] == source - eligible
        else { throw CalibrationError.invalidRecord }
        self.source = source
        self.eligible = eligible
        self.selected = selected
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case source, eligible, selected, tags
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            source: c.decode(Int64.self, forKey: .source),
            eligible: c.decode(Int64.self, forKey: .eligible),
            selected: c.decode(Int64.self, forKey: .selected),
            tags: c.decode([String: Int64].self, forKey: .tags))
    }
}

/// Raw-unit, equal-frame summaries of available estimates; no gain/pitch
/// normalization, imputation or confidence weighting. Quantiles use the inverse
/// empirical CDF (nearest rank, lower median for even counts), not interpolation.
/// Counts describe frames, not independent observations or unique source coverage.
public struct CalibrationMetricSummary: Sendable, Hashable, Codable {
    public static let maximumObservationCount = 30_000
    public let metric: ScheduledMetric
    public let availableCount: Int
    public let unavailable: [String: Int]
    public let warnings: [String: Int]
    public let minimum: Double?
    public let lowerQuartile: Double?
    public let median: Double?
    public let upperQuartile: Double?
    public let maximum: Double?
    public var observationCount: Int { availableCount + unavailable.values.reduce(0, +) }
    public var unit: MeasurementUnit {
        switch metric {
        case .rms: .normalizedAmplitude
        case .levelDBFS: .decibelsFullScale
        case .fundamentalFrequency, .trackedFundamentalFrequency: .hertz
        default: .decibelsRatio  // Only CPP and CPPS pass the validated metric list.
        }
    }

    package init(
        metric: ScheduledMetric, values: [Double], unavailable: [String: Int],
        warnings: [String: Int]
    ) throws {
        guard values.count <= Self.maximumObservationCount, values.allSatisfy(\.isFinite) else {
            throw CalibrationError.capacityExceeded
        }
        let sorted = values.sorted()
        func quantile(_ p: Double) -> Double? {
            sorted.isEmpty ? nil : sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)]
        }
        try self.init(
            metric: metric, availableCount: values.count, unavailable: unavailable,
            warnings: warnings,
            minimum: sorted.first, lowerQuartile: quantile(0.25), median: quantile(0.5),
            upperQuartile: quantile(0.75), maximum: sorted.last)
    }

    private init(
        metric: ScheduledMetric, availableCount: Int, unavailable: [String: Int],
        warnings: [String: Int], minimum: Double?, lowerQuartile: Double?, median: Double?,
        upperQuartile: Double?, maximum: Double?
    ) throws {
        guard calibrationSummaryMetrics.contains(metric),
            (0...Self.maximumObservationCount).contains(availableCount),
            unavailable.keys.allSatisfy({ UnavailabilityReason(rawValue: $0) != nil }),
            unavailable.values.allSatisfy({ (1...Self.maximumObservationCount).contains($0) }),
            unavailable.values.reduce(availableCount, +) <= Self.maximumObservationCount,
            warnings.keys.allSatisfy({ MeasurementWarning(rawValue: $0) != nil }),
            warnings.values.allSatisfy({ $0 > 0 && $0 <= availableCount })
        else { throw CalibrationError.invalidRecord }
        let quantiles = [minimum, lowerQuartile, median, upperQuartile, maximum]
        if availableCount == 0 {
            guard quantiles.allSatisfy({ $0 == nil }) else { throw CalibrationError.invalidRecord }
        } else {
            let values = quantiles.compactMap { $0 }
            guard values.count == 5, values.allSatisfy(\.isFinite), values == values.sorted() else {
                throw CalibrationError.invalidRecord
            }
        }
        self.metric = metric
        self.availableCount = availableCount
        self.unavailable = unavailable
        self.warnings = warnings
        self.minimum = minimum
        self.lowerQuartile = lowerQuartile
        self.median = median
        self.upperQuartile = upperQuartile
        self.maximum = maximum
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metric, availableCount, unavailable, warnings
        case minimum, lowerQuartile, median, upperQuartile, maximum
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            metric: c.decode(ScheduledMetric.self, forKey: .metric),
            availableCount: c.decode(Int.self, forKey: .availableCount),
            unavailable: c.decode([String: Int].self, forKey: .unavailable),
            warnings: c.decode([String: Int].self, forKey: .warnings),
            minimum: c.decodeIfPresent(Double.self, forKey: .minimum),
            lowerQuartile: c.decodeIfPresent(Double.self, forKey: .lowerQuartile),
            median: c.decodeIfPresent(Double.self, forKey: .median),
            upperQuartile: c.decodeIfPresent(Double.self, forKey: .upperQuartile),
            maximum: c.decodeIfPresent(Double.self, forKey: .maximum))
    }
}

package let calibrationSummaryMetrics: [ScheduledMetric] = [
    .rms, .levelDBFS, .fundamentalFrequency, .trackedFundamentalFrequency, .cpp, .cpps,
]

package func calibrationMetrics(for profile: AnalysisScheduleProfile) -> [ScheduledMetric] {
    var result: [ScheduledMetric] = []
    if profile.levels != nil { result += [.rms, .levelDBFS] }
    if profile.pitch != nil { result.append(.fundamentalFrequency) }
    if profile.pitch?.tracker != nil { result.append(.trackedFundamentalFrequency) }
    if profile.cpps != nil { result += [.cpp, .cpps] }
    return result
}

/// A complete numerical result, never a partial/cancelled analysis. Hosts own
/// storage and eviction; importing this record alone does not authorize reuse.
public struct CalibrationAnalysisRecord: Sendable, Hashable, Codable {
    public let key: CalibrationAnalysisKey
    public let coverage: CalibrationCoverage
    public let summaries: [CalibrationMetricSummary]
    public static let maximumEncodedBytes = 128 * 1024

    package init(
        key: CalibrationAnalysisKey, coverage: CalibrationCoverage,
        summaries: [CalibrationMetricSummary]
    ) throws {
        guard coverage.source == key.source.sampleCount,
            summaries.count <= calibrationSummaryMetrics.count,
            Set(summaries.map(\.metric)).count == summaries.count
        else { throw CalibrationError.invalidRecord }
        self.key = key
        self.coverage = coverage
        self.summaries = summaries.sorted { $0.metric.rawValue < $1.metric.rawValue }
    }

    public func summary(_ metric: ScheduledMetric) -> CalibrationMetricSummary? {
        summaries.first { $0.metric == metric }
    }

    /// Verifies complete recipe/selection metadata and summary presence. It is
    /// not a signature: hosts must treat cached numerical values as trusted data.
    public func validate(for take: CalibrationTake) throws {
        guard try key.matches(take),
            Set(summaries.map(\.metric)) == Set(calibrationMetrics(for: take.profile))
        else { throw CalibrationError.incompatibleDataset }
        let mask = try PreparedAnalysisMask(
            timeline: MaskTimeline(take.effectiveMaskPlan()), scope: .selected)
        guard try coverage == CalibrationCoverage(mask.coverage(of: take.source)) else {
            throw CalibrationError.incompatibleDataset
        }
    }

    public func canonicalJSON() throws -> Data { try canonicalContractJSON(self) }
    public static func decode(_ data: Data, for take: CalibrationTake) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw CalibrationError.capacityExceeded }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(for: take)
        return value
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case key, coverage, summaries }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            key: c.decode(CalibrationAnalysisKey.self, forKey: .key),
            coverage: c.decode(CalibrationCoverage.self, forKey: .coverage),
            summaries: c.decode([CalibrationMetricSummary].self, forKey: .summaries))
    }
}
