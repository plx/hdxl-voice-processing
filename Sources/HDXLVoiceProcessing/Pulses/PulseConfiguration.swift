import CryptoKit
import Foundation

public enum PulseError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidContour, invalidInput, precisionMismatch
    case invalidBufferSize, capacityExceeded, unexpectedContext, invalidState
    case reentrantCall, insufficientData, numericalFailure
}

/// Both definitions wait for their complete declared input. Independent blocks
/// deliberately reset anchoring and cannot imply cycle continuity between blocks.
public enum PulseSupportDefinition: String, Sendable, Hashable, Codable {
    case completeInterval
    case independentlyAnchoredBlock
}

/// Waveform-matching recipe; the supplied F0 contour is a separate input.
/// Period eligibility limits do not alter the tracker's 0.8–1.25 period search.
public struct PulseConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let arithmeticPrecision: AnalysisPrecision
    public let pitchFloorHz: Double
    public let pitchCeilingHz: Double
    public let minimumPeriodSeconds: Double
    public let maximumPeriodSeconds: Double
    public let maximumAdjacentPeriodFactor: Double
    public let support: PulseSupportDefinition
    public let definition: String
    public let seedDefinition: String
    public let correlationDefinition: String
    public let interpolationDefinition: String
    public let amplitudeDefinition: String
    public let minimumReliableCurvature: Double
    public let minimumRelativeVariation: Double

    public static let maximumInputSampleCount = 16_777_216
    public static let maximumContourFrameCount = 1_048_576
    public static let maximumTrackingAttemptCount = 1_048_576

    public var maximumCorrelationSampleCount: Int {
        Int(ceil(Double(sampleRate) / pitchFloorHz)) + 3
    }
    public var maximumCandidateLagCount: Int {
        Int(ceil(0.45 * Double(sampleRate) / pitchFloorHz)) + 5
    }

    public init(
        sampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        pitchFloorHz: Double = 20, pitchCeilingHz: Double = 700,
        minimumPeriodSeconds: Double = 0.0001, maximumPeriodSeconds: Double = 0.02,
        maximumAdjacentPeriodFactor: Double = 1.3,
        support: PulseSupportDefinition = .completeInterval
    ) throws {
        guard (4000...192_000).contains(sampleRate), pitchFloorHz.isFinite,
            pitchCeilingHz.isFinite, pitchFloorHz >= 20, pitchFloorHz < pitchCeilingHz,
            pitchCeilingHz <= Double(sampleRate) / 4,
            minimumPeriodSeconds.isFinite, maximumPeriodSeconds.isFinite,
            0 < minimumPeriodSeconds, minimumPeriodSeconds < maximumPeriodSeconds,
            maximumPeriodSeconds <= 0.1, maximumAdjacentPeriodFactor.isFinite,
            (1...10).contains(maximumAdjacentPeriodFactor)
        else { throw PulseError.invalidConfiguration }
        schemaVersion = 1
        self.sampleRate = sampleRate
        self.inputPrecision = inputPrecision
        arithmeticPrecision = .float64
        self.pitchFloorHz = pitchFloorHz
        self.pitchCeilingHz = pitchCeilingHz
        self.minimumPeriodSeconds = minimumPeriodSeconds
        self.maximumPeriodSeconds = maximumPeriodSeconds
        self.maximumAdjacentPeriodFactor = maximumAdjacentPeriodFactor
        self.support = support
        definition = "hdxl-acoustic-pulses-waveform-cc-v1"
        seedDefinition = "voicedIntervalMidpointAbsoluteExtremumParabola"
        correlationDefinition =
            "observedPairsFusedDotScaleSubnormalProductFiniteLagTableRightNeighborPeak"
        interpolationDefinition = "threePointParabolaGeometricRangeFallback"
        amplitudeDefinition = "hannRMSPointTwoNeighborPeriods"
        minimumReliableCurvature = 128 * Double.ulpOfOne
        minimumRelativeVariation = 64 * Double.ulpOfOne
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(name: definition + "-" + support.rawValue, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sampleRate, inputPrecision, arithmeticPrecision
        case pitchFloorHz, pitchCeilingHz, minimumPeriodSeconds, maximumPeriodSeconds
        case maximumAdjacentPeriodFactor, support, definition, seedDefinition
        case correlationDefinition, interpolationDefinition, amplitudeDefinition
        case minimumReliableCurvature, minimumRelativeVariation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            pitchFloorHz: c.decode(Double.self, forKey: .pitchFloorHz),
            pitchCeilingHz: c.decode(Double.self, forKey: .pitchCeilingHz),
            minimumPeriodSeconds: c.decode(Double.self, forKey: .minimumPeriodSeconds),
            maximumPeriodSeconds: c.decode(Double.self, forKey: .maximumPeriodSeconds),
            maximumAdjacentPeriodFactor: c.decode(
                Double.self, forKey: .maximumAdjacentPeriodFactor),
            support: c.decode(PulseSupportDefinition.self, forKey: .support))
        guard
            try c.decode(AnalysisPrecision.self, forKey: .arithmeticPrecision)
                == arithmeticPrecision,
            try c.decode(String.self, forKey: .definition) == definition,
            try c.decode(String.self, forKey: .seedDefinition) == seedDefinition,
            try c.decode(String.self, forKey: .correlationDefinition) == correlationDefinition,
            try c.decode(String.self, forKey: .interpolationDefinition) == interpolationDefinition,
            try c.decode(String.self, forKey: .amplitudeDefinition) == amplitudeDefinition,
            try c.decode(Double.self, forKey: .minimumReliableCurvature)
                == minimumReliableCurvature,
            try c.decode(Double.self, forKey: .minimumRelativeVariation) == minimumRelativeVariation
        else { throw PulseError.invalidConfiguration }
    }
}
