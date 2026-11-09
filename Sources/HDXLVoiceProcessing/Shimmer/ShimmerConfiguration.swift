import CryptoKit
import Foundation

public enum ShimmerError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidInput, unexpectedContext, precisionMismatch
    case capacityExceeded, invalidState, reentrantCall, numericalFailure
    case measurementNotRequested
}

/// A task declaration, not an assertion that connected speech is sustained phonation.
public enum ShimmerApplicability: String, Sendable, Hashable, Codable {
    case sustainedPhonation, exploratoryRolling
}

public enum ShimmerVariant: String, Sendable, Hashable, Codable, CaseIterable {
    case local, db, apq3, apq5, apq11, dda

    public var measurementKind: MeasurementKind {
        switch self {
        case .local: .shimmerLocal
        case .db: .shimmerDB
        case .apq3: .shimmerAPQ3
        case .apq5: .shimmerAPQ5
        case .apq11: .shimmerAPQ11
        case .dda: .shimmerDDA
        }
    }

    public var unit: MeasurementUnit { self == .db ? .decibelsRatio : .fraction }

    public var minimumConsecutiveAmplitudeCount: Int {
        switch self {
        case .local, .db: 2
        case .apq3, .dda: 3
        case .apq5: 5
        case .apq11: 11
        }
    }
}

/// Amplitude extraction, statistical eligibility and applicability are serialized
/// independently. Supplied amplitudes must declare their own source provenance.
public struct ShimmerConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let arithmeticPrecision: AnalysisPrecision
    public let applicability: ShimmerApplicability
    public let rollingWindowSampleCount: Int?
    public let minimumPeriodSeconds: Double
    public let maximumPeriodSeconds: Double
    /// Used when extracting amplitudes from neighboring acoustic periods.
    public let maximumAdjacentPeriodFactor: Double
    /// Applied to every adjacent amplitude edge in each statistic's neighborhood.
    public let maximumAmplitudeFactor: Double
    public let definition: String
    public let amplitudeDefinition: String
    public let denominatorDefinition: String
    public let neighborhoodDefinition: String
    public let dbDefinition: String

    public static let maximumAmplitudeCount = 1_048_576
    public static let maximumRollingWindowSampleCount = 16_777_216

    public var rollingWindowDurationSeconds: Double? {
        rollingWindowSampleCount.map { Double($0) / Double(sampleRate) }
    }

    public init(
        sampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        applicability: ShimmerApplicability = .sustainedPhonation,
        rollingWindowSampleCount: Int? = nil,
        minimumPeriodSeconds: Double = 0.0001, maximumPeriodSeconds: Double = 0.02,
        maximumAdjacentPeriodFactor: Double = 1.3, maximumAmplitudeFactor: Double = 1.6
    ) throws {
        guard (4000...192_000).contains(sampleRate),
            minimumPeriodSeconds.isFinite, maximumPeriodSeconds.isFinite,
            0 < minimumPeriodSeconds, minimumPeriodSeconds < maximumPeriodSeconds,
            maximumPeriodSeconds <= 0.1, maximumAdjacentPeriodFactor.isFinite,
            (1...10).contains(maximumAdjacentPeriodFactor), maximumAmplitudeFactor.isFinite,
            (1...10).contains(maximumAmplitudeFactor)
        else { throw ShimmerError.invalidConfiguration }
        switch applicability {
        case .sustainedPhonation:
            guard rollingWindowSampleCount == nil else { throw ShimmerError.invalidConfiguration }
        case .exploratoryRolling:
            guard let rollingWindowSampleCount,
                (1...Self.maximumRollingWindowSampleCount).contains(rollingWindowSampleCount)
            else { throw ShimmerError.invalidConfiguration }
        }
        schemaVersion = 1
        self.sampleRate = sampleRate
        self.inputPrecision = inputPrecision
        arithmeticPrecision = .float64
        self.applicability = applicability
        self.rollingWindowSampleCount = rollingWindowSampleCount
        self.minimumPeriodSeconds = minimumPeriodSeconds
        self.maximumPeriodSeconds = maximumPeriodSeconds
        self.maximumAdjacentPeriodFactor = maximumAdjacentPeriodFactor
        self.maximumAmplitudeFactor = maximumAmplitudeFactor
        definition = "hdxl-shimmer-amplitude-statistics-v1"
        amplitudeDefinition = "hannRMSPointTwoNeighborPeriods"
        denominatorDefinition = "sourceEligibleSelectedAmplitudesExceptFinalIncludingZeros"
        neighborhoodDefinition = "completeConsecutivePositiveAmplitudesWithoutStitching"
        dbDefinition = "meanTwentyAbsoluteLog10AdjacentAmplitudeRatio"
    }

    public func identity() throws -> ProfileIdentity {
        try ProfileIdentity(
            identifier: VersionedIdentifier(
                name: definition + "-" + applicability.rawValue, version: 1),
            sha256: SHA256.hash(data: canonicalContractJSON(self)).map {
                String(format: "%02x", $0)
            }.joined())
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, sampleRate, inputPrecision, arithmeticPrecision, applicability
        case rollingWindowSampleCount, minimumPeriodSeconds, maximumPeriodSeconds
        case maximumAdjacentPeriodFactor, maximumAmplitudeFactor, definition
        case amplitudeDefinition, denominatorDefinition, neighborhoodDefinition, dbDefinition
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            applicability: c.decode(ShimmerApplicability.self, forKey: .applicability),
            rollingWindowSampleCount: c.decodeIfPresent(
                Int.self, forKey: .rollingWindowSampleCount),
            minimumPeriodSeconds: c.decode(Double.self, forKey: .minimumPeriodSeconds),
            maximumPeriodSeconds: c.decode(Double.self, forKey: .maximumPeriodSeconds),
            maximumAdjacentPeriodFactor: c.decode(
                Double.self, forKey: .maximumAdjacentPeriodFactor),
            maximumAmplitudeFactor: c.decode(Double.self, forKey: .maximumAmplitudeFactor))
        guard
            try c.decode(AnalysisPrecision.self, forKey: .arithmeticPrecision)
                == arithmeticPrecision,
            try c.decode(String.self, forKey: .definition) == definition,
            try c.decode(String.self, forKey: .amplitudeDefinition) == amplitudeDefinition,
            try c.decode(String.self, forKey: .denominatorDefinition) == denominatorDefinition,
            try c.decode(String.self, forKey: .neighborhoodDefinition) == neighborhoodDefinition,
            try c.decode(String.self, forKey: .dbDefinition) == dbDefinition
        else { throw ShimmerError.invalidConfiguration }
    }
}
