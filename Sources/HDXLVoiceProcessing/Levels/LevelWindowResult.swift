import Foundation

public enum LevelEnergyOutcome: Sendable, Hashable, Codable {
    case available(LevelEnergy)
    case unavailable(UnavailabilityReason)
    public var energy: LevelEnergy? { if case .available(let value) = self { value } else { nil } }
    public var meanSquare: MeasurementOutcome {
        switch self {
        case .available(let value): value.meanSquare
        case .unavailable(let reason): .unavailable(reason)
        }
    }
    public var rms: MeasurementOutcome {
        switch self {
        case .available(let value): value.rms
        case .unavailable(let reason): .unavailable(reason)
        }
    }
    public var digitalLevel: DigitalLevel {
        switch self {
        case .available(let value): value.digitalLevel
        case .unavailable(let reason): .unavailable(reason)
        }
    }
    private enum Status: String, Codable { case available, unavailable }
    private enum CodingKeys: String, CodingKey, CaseIterable { case status, energy, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        switch try c.decode(Status.self, forKey: .status) {
        case .available:
            guard Set(c.allKeys) == [.status, .energy] else { throw ContractError.invalidValue }
            self = .available(try c.decode(LevelEnergy.self, forKey: .energy))
        case .unavailable:
            guard Set(c.allKeys) == [.status, .reason] else { throw ContractError.invalidValue }
            self = .unavailable(try c.decode(UnavailabilityReason.self, forKey: .reason))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let energy):
            try c.encode(Status.available, forKey: .status)
            try c.encode(energy, forKey: .energy)
        case .unavailable(let reason):
            try c.encode(Status.unavailable, forKey: .status)
            try c.encode(reason, forKey: .reason)
        }
    }
}

extension LevelWindowResult {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, configuration, profile, epochOriginSample, frameIndex, source, input
        case unweighted, weighted, weightedPrecisionLimited, unweightedTiming, weightedTiming,
            filterHistorySource
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        guard c.contains(.weighted), c.contains(.weightedTiming), c.contains(.filterHistorySource)
        else {
            throw ContractError.invalidValue
        }
        let configuration = try c.decode(LevelConfiguration.self, forKey: .configuration)
        let profile = try c.decode(ProfileIdentity.self, forKey: .profile)
        guard profile == (try configuration.identity()) else {
            throw ContractError.invalidFingerprint
        }
        try self.init(
            configuration: configuration, profile: profile,
            epochOriginSample: c.decode(Int64.self, forKey: .epochOriginSample),
            frameIndex: c.decode(UInt64.self, forKey: .frameIndex),
            source: c.decode(SourceInterval.self, forKey: .source),
            input: c.decode(LevelInputDiagnostics.self, forKey: .input),
            unweighted: c.decode(LevelEnergyOutcome.self, forKey: .unweighted),
            weighted: c.decodeIfPresent(LevelEnergyOutcome.self, forKey: .weighted),
            weightedPrecisionLimited: c.decode(Bool.self, forKey: .weightedPrecisionLimited))
        guard try c.decode(AnalysisTiming.self, forKey: .unweightedTiming) == unweightedTiming,
            try c.decodeIfPresent(AnalysisTiming.self, forKey: .weightedTiming) == weightedTiming,
            try c.decodeIfPresent(SourceInterval.self, forKey: .filterHistorySource)
                == filterHistorySource
        else { throw ContractError.invalidTiming }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(configuration, forKey: .configuration)
        try c.encode(profile, forKey: .profile)
        try c.encode(epochOriginSample, forKey: .epochOriginSample)
        try c.encode(frameIndex, forKey: .frameIndex)
        try c.encode(source, forKey: .source)
        try c.encode(input, forKey: .input)
        try c.encode(unweighted, forKey: .unweighted)
        try c.encode(weighted, forKey: .weighted)
        try c.encode(weightedPrecisionLimited, forKey: .weightedPrecisionLimited)
        try c.encode(unweightedTiming, forKey: .unweightedTiming)
        try c.encode(weightedTiming, forKey: .weightedTiming)
        try c.encode(filterHistorySource, forKey: .filterHistorySource)
    }
}

/// Owned immutable window result. No borrowed PCM or mutable processor workspace is retained.
public struct LevelWindowResult: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let configuration: LevelConfiguration
    public let profile: ProfileIdentity
    public let epochOriginSample: Int64
    public let frameIndex: UInt64
    public let source: SourceInterval
    public let input: LevelInputDiagnostics
    public let unweighted: LevelEnergyOutcome
    /// nil means weighting was not requested, distinct from an unavailable weighted value.
    public let weighted: LevelEnergyOutcome?
    /// Sticky until explicit reset: a Float64 filter operation entered the subnormal range.
    public let weightedPrecisionLimited: Bool

    public var missingSampleCount: Int { configuration.windowLength - Int(source.sampleCount) }
    public var warmupSamplesRemainingAtWindowStart: Int64 {
        max(
            0,
            Int64(configuration.weighting.warmupSampleCount)
                - (source.startSample - epochOriginSample))
    }
    public var filterHistorySource: SourceInterval? {
        configuration.kWeighting == nil
            ? nil
            : try! SourceInterval(
                epoch: source.epoch, startSample: epochOriginSample,
                sampleCount: source.endSample - epochOriginSample, sampleRate: source.sampleRate)
    }
    /// Window-center-to-delivery buffering delay, excluding host compute/scheduling.
    /// The causal IIR's frequency-dependent phase is inspectable on configuration.kWeighting.
    public var unweightedTiming: AnalysisTiming {
        try! AnalysisTiming(
            source: source, includedSampleCount: source.sampleCount,
            effectiveDelaySeconds: source.durationSeconds / 2)
    }
    public var weightedTiming: AnalysisTiming? {
        weighted.map { value in
            try! AnalysisTiming(
                source: source, includedSampleCount: value.energy == nil ? 0 : source.sampleCount,
                effectiveDelaySeconds: source.durationSeconds / 2)
        }
    }
    public var peakAmplitude: MeasurementOutcome {
        switch unweighted {
        case .available(let energy): .available(try! ScalarEstimate(value: energy.scale))
        case .unavailable(let reason): .unavailable(reason)
        }
    }
    public var samplePeakDBFS: DigitalLevel {
        switch unweighted {
        case .available(let energy):
            energy.isZero ? .zeroEnergy : try! .finite(20 * log10(energy.scale))
        case .unavailable(let reason): .unavailable(reason)
        }
    }
    public var crestFactor: MeasurementOutcome { crest(logarithmic: false) }
    public var crestFactorDB: MeasurementOutcome { crest(logarithmic: true) }
    private func crest(logarithmic: Bool) -> MeasurementOutcome {
        switch unweighted {
        case .unavailable(let reason): return .unavailable(reason)
        case .available(let energy):
            guard !energy.isZero else { return .unavailable(.silence) }
            let value =
                logarithmic
                ? -10 * log10(energy.normalizedMeanSquare) : 1 / sqrt(energy.normalizedMeanSquare)
            return .available(try! ScalarEstimate(value: value))
        }
    }
    public var possibleClippingFraction: Double {
        Double(input.possibleClippingSampleCount) / Double(input.sampleCount)
    }

    init(
        configuration: LevelConfiguration, profile: ProfileIdentity, epochOriginSample: Int64,
        frameIndex: UInt64, source: SourceInterval, input: LevelInputDiagnostics,
        unweighted: LevelEnergyOutcome, weighted: LevelEnergyOutcome?,
        weightedPrecisionLimited: Bool
    ) throws {
        guard epochOriginSample >= 0, source.startSample >= epochOriginSample,
            (1...Int64(configuration.windowLength)).contains(source.sampleCount),
            source.sampleRate == Double(configuration.sampleRate),
            input.sampleCount == Int(source.sampleCount), input.nonfiniteSampleCount == 0
        else { throw ContractError.invalidValue }
        let displacement = frameIndex.multipliedReportingOverflow(
            by: UInt64(configuration.hopLength))
        let start = UInt64(epochOriginSample).addingReportingOverflow(displacement.partialValue)
        guard !displacement.overflow, !start.overflow,
            start.partialValue == UInt64(source.startSample)
        else { throw ContractError.invalidInterval }
        let complete = source.sampleCount == Int64(configuration.windowLength)
        if complete {
            guard let energy = unweighted.energy, energy.scale == input.finitePeakMagnitude,
                energy.isZero
                    || energy.normalizedMeanSquare >= (1 / Double(source.sampleCount))
                        * (1 - 64 * Double.ulpOfOne)
            else { throw ContractError.invalidValue }
        } else {
            guard unweighted == .unavailable(.insufficientData) else {
                throw ContractError.invalidValue
            }
        }
        if configuration.kWeighting == nil {
            guard weighted == nil, !weightedPrecisionLimited else {
                throw ContractError.invalidValue
            }
        } else {
            let warmup =
                source.startSample - epochOriginSample
                < Int64(configuration.weighting.warmupSampleCount)
            if !complete || warmup {
                guard weighted == .unavailable(.insufficientData) else {
                    throw ContractError.invalidValue
                }
            } else if weightedPrecisionLimited {
                guard weighted == .unavailable(.unsupportedRange) else {
                    throw ContractError.invalidValue
                }
            } else {
                guard weighted?.energy != nil else { throw ContractError.invalidValue }
            }
        }
        self.schemaVersion = 1
        self.configuration = configuration
        self.profile = profile
        self.epochOriginSample = epochOriginSample
        self.frameIndex = frameIndex
        self.source = source
        self.input = input
        self.unweighted = unweighted
        self.weighted = weighted
        self.weightedPrecisionLimited = weightedPrecisionLimited
    }

    /// Explicit adapter to the shared scalar contract. Warning arrays may allocate here;
    /// call outside the prepared kernel when collecting or publishing owned results.
    public func measurementResult(kind: MeasurementKind, unit: MeasurementUnit) throws
        -> MeasurementResult
    {
        let descriptor = try MeasurementDescriptor(
            kind: kind, unit: unit, algorithm: profile.identifier)
        let outcome: MeasurementOutcome
        switch kind {
        case .peakAmplitude: outcome = peakAmplitude
        case .meanSquare: outcome = unweighted.meanSquare
        case .rms: outcome = unweighted.rms
        case .levelDBFS: outcome = unweighted.digitalLevel.scalarOutcome
        case .crestFactor: outcome = unit == .decibelsRatio ? crestFactorDB : crestFactor
        case .clippingFraction:
            outcome = .available(
                try ScalarEstimate(value: possibleClippingFraction * (unit == .percent ? 100 : 1)))
        case .kWeightedEnergy: outcome = weighted?.meanSquare ?? .unavailable(.inapplicableTask)
        default: throw ContractError.invalidValue
        }
        let qualified: MeasurementOutcome
        if let estimate = outcome.estimate, input.possibleClippingSampleCount > 0 {
            qualified = .available(try ScalarEstimate(value: estimate.value, warnings: [.clipping]))
        } else {
            qualified = outcome
        }
        let timing =
            kind == .kWeightedEnergy ? (weightedTiming ?? unweightedTiming) : unweightedTiming
        return try MeasurementResult(
            measurement: descriptor, profile: profile, timing: timing, outcome: qualified)
    }
}
