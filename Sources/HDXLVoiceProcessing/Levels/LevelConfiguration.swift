import CryptoKit
import Foundation

public enum LevelAccumulation: String, Sendable, Hashable, Codable {
    case direct, compensatedSliding
}

public enum LevelWeighting: Sendable, Hashable, Codable {
    case none
    case bs1770Revision5(warmupSampleCount: Int)

    public var warmupSampleCount: Int {
        switch self {
        case .none: 0
        case .bs1770Revision5(let count): count
        }
    }
    private enum Kind: String, Codable { case none, bs1770Revision5 }
    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, warmupSampleCount }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .none:
            guard Set(c.allKeys) == [.kind] else { throw ContractError.invalidConfiguration }
            self = .none
        case .bs1770Revision5:
            let count = try c.decode(Int.self, forKey: .warmupSampleCount)
            guard count >= 0 else { throw ContractError.invalidConfiguration }
            self = .bs1770Revision5(warmupSampleCount: count)
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try c.encode(Kind.none, forKey: .kind)
        case .bs1770Revision5(let count):
            guard count >= 0 else { throw ContractError.invalidConfiguration }
            try c.encode(Kind.bs1770Revision5, forKey: .kind)
            try c.encode(count, forKey: .warmupSampleCount)
        }
    }
}

public enum LevelPCMReference: String, Sendable, Hashable, Codable { case unitPeak }
public enum LevelChannelPolicy: String, Sendable, Hashable, Codable { case monoAlreadySelected }
public enum LevelAveraging: String, Sendable, Hashable, Codable { case rectangularMeanSquare }
public enum LevelFilterPhasePolicy: String, Sendable, Hashable, Codable {
    case causalFrequencyDependentNoTimestampShift
}

/// A sample-indexed averaging grid. Input precision and Float64 arithmetic are separate facts.
/// Full-scale refers to a unit *peak*: a full-scale sine has -3.0103 dBFS RMS.
public struct LevelConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let arithmeticPrecision: AnalysisPrecision
    public let windowLength: Int
    public let hopLength: Int
    public let accumulation: LevelAccumulation
    public let weighting: LevelWeighting
    public let partialWindowPolicy: PartialWindowPolicy
    public let pcmReference: LevelPCMReference
    public let channelPolicy: LevelChannelPolicy
    public let averaging: LevelAveraging
    public let energyUnit: MeasurementUnit
    public let logLevelUnit: MeasurementUnit
    public let filterPhasePolicy: LevelFilterPhasePolicy
    public let kWeighting: KWeightingCoefficients?

    public var windowDurationSeconds: Double { Double(windowLength) / Double(sampleRate) }

    public init(
        sampleRate: Int, inputPrecision: AnalysisPrecision, windowLength: Int, hopLength: Int,
        accumulation: LevelAccumulation, weighting: LevelWeighting,
        partialWindowPolicy: PartialWindowPolicy = .emitUnavailable
    ) throws {
        guard (4000...192_000).contains(sampleRate), (1...262_144).contains(windowLength),
            (1...windowLength).contains(hopLength),
            (0...sampleRate * 10).contains(weighting.warmupSampleCount)
        else { throw ContractError.invalidConfiguration }
        self.schemaVersion = 1
        self.sampleRate = sampleRate
        self.inputPrecision = inputPrecision
        self.arithmeticPrecision = .float64
        self.windowLength = windowLength
        self.hopLength = hopLength
        self.accumulation = accumulation
        self.weighting = weighting
        self.partialWindowPolicy = partialWindowPolicy
        self.pcmReference = .unitPeak
        self.channelPolicy = .monoAlreadySelected
        self.averaging = .rectangularMeanSquare
        self.energyUnit = .normalizedSquaredAmplitude
        self.logLevelUnit = .decibelsFullScale
        self.filterPhasePolicy = .causalFrequencyDependentNoTimestampShift
        switch weighting {
        case .none: self.kWeighting = nil
        case .bs1770Revision5: self.kWeighting = try KWeightingCoefficients(sampleRate: sampleRate)
        }
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: "digital-level-windows", version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sampleRate, inputPrecision, arithmeticPrecision, windowLength, hopLength
        case accumulation, weighting, partialWindowPolicy, pcmReference, channelPolicy, averaging
        case energyUnit, logLevelUnit, filterPhasePolicy, kWeighting
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        guard c.contains(.kWeighting) else { throw ContractError.invalidConfiguration }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            windowLength: c.decode(Int.self, forKey: .windowLength),
            hopLength: c.decode(Int.self, forKey: .hopLength),
            accumulation: c.decode(LevelAccumulation.self, forKey: .accumulation),
            weighting: c.decode(LevelWeighting.self, forKey: .weighting),
            partialWindowPolicy: c.decode(PartialWindowPolicy.self, forKey: .partialWindowPolicy))
        guard
            try c.decode(AnalysisPrecision.self, forKey: .arithmeticPrecision)
                == arithmeticPrecision,
            try c.decode(LevelPCMReference.self, forKey: .pcmReference) == pcmReference,
            try c.decode(LevelChannelPolicy.self, forKey: .channelPolicy) == channelPolicy,
            try c.decode(LevelAveraging.self, forKey: .averaging) == averaging,
            try c.decode(MeasurementUnit.self, forKey: .energyUnit) == energyUnit,
            try c.decode(MeasurementUnit.self, forKey: .logLevelUnit) == logLevelUnit,
            try c.decode(LevelFilterPhasePolicy.self, forKey: .filterPhasePolicy)
                == filterPhasePolicy,
            try c.decodeIfPresent(KWeightingCoefficients.self, forKey: .kWeighting) == kWeighting
        else { throw ContractError.invalidConfiguration }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(inputPrecision, forKey: .inputPrecision)
        try c.encode(arithmeticPrecision, forKey: .arithmeticPrecision)
        try c.encode(windowLength, forKey: .windowLength)
        try c.encode(hopLength, forKey: .hopLength)
        try c.encode(accumulation, forKey: .accumulation)
        try c.encode(weighting, forKey: .weighting)
        try c.encode(partialWindowPolicy, forKey: .partialWindowPolicy)
        try c.encode(pcmReference, forKey: .pcmReference)
        try c.encode(channelPolicy, forKey: .channelPolicy)
        try c.encode(averaging, forKey: .averaging)
        try c.encode(energyUnit, forKey: .energyUnit)
        try c.encode(logLevelUnit, forKey: .logLevelUnit)
        try c.encode(filterPhasePolicy, forKey: .filterPhasePolicy)
        try c.encode(kWeighting, forKey: .kWeighting)
    }
}
