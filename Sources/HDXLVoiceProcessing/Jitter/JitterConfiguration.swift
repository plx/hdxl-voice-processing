import CryptoKit
import Foundation

public enum JitterError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidInput, unexpectedContext, precisionMismatch
    case capacityExceeded, invalidState, reentrantCall, numericalFailure
}

/// A declared analysis task. Rolling values can include natural F0 movement and
/// tracking errors; neither case is a diagnosis or a pleasantness score.
public enum JitterApplicability: String, Sendable, Hashable, Codable {
    case sustainedPhonation, exploratoryRolling
}

public enum JitterVariant: String, Sendable, Hashable, Codable, CaseIterable {
    case local, absolute, rap, ppq5, ddp

    public var measurementKind: MeasurementKind {
        switch self {
        case .local: .jitterLocal
        case .absolute: .jitterAbsolute
        case .rap: .jitterRAP
        case .ppq5: .jitterPPQ5
        case .ddp: .jitterDDP
        }
    }

    /// Relative outputs are normalized fractions. Converting to a display
    /// percentage requires an explicit multiplication by 100 and unit change.
    public var unit: MeasurementUnit { self == .absolute ? .seconds : .fraction }

    public var minimumConsecutivePeriodCount: Int {
        switch self {
        case .local, .absolute: 2
        case .rap, .ddp: 3
        case .ppq5: 5
        }
    }
}

/// Period eligibility and applicability participate in the numerical identity.
/// Timestamp/period arithmetic is always binary64. `inputPrecision` declares
/// the upstream PCM representation when the profile is used with pulse tracking.
public struct JitterConfiguration: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let sampleRate: Int
    public let inputPrecision: AnalysisPrecision
    public let arithmeticPrecision: AnalysisPrecision
    public let applicability: JitterApplicability
    public let rollingWindowSampleCount: Int?
    public let minimumPeriodSeconds: Double
    public let maximumPeriodSeconds: Double
    public let maximumAdjacentPeriodFactor: Double
    public let definition: String
    public let denominatorDefinition: String
    public let neighborhoodDefinition: String

    public static let maximumPeriodCount = 1_048_576
    public static let maximumRollingWindowSampleCount = 16_777_216

    public var rollingWindowDurationSeconds: Double? {
        rollingWindowSampleCount.map { Double($0) / Double(sampleRate) }
    }

    public init(
        sampleRate: Int, inputPrecision: AnalysisPrecision = .float64,
        applicability: JitterApplicability = .sustainedPhonation,
        rollingWindowSampleCount: Int? = nil,
        minimumPeriodSeconds: Double = 0.0001, maximumPeriodSeconds: Double = 0.02,
        maximumAdjacentPeriodFactor: Double = 1.3
    ) throws {
        guard (4000...192_000).contains(sampleRate),
            minimumPeriodSeconds.isFinite, maximumPeriodSeconds.isFinite,
            0 < minimumPeriodSeconds, minimumPeriodSeconds < maximumPeriodSeconds,
            maximumPeriodSeconds <= 0.1, maximumAdjacentPeriodFactor.isFinite,
            (1...10).contains(maximumAdjacentPeriodFactor)
        else { throw JitterError.invalidConfiguration }
        switch applicability {
        case .sustainedPhonation:
            guard rollingWindowSampleCount == nil else { throw JitterError.invalidConfiguration }
        case .exploratoryRolling:
            guard let rollingWindowSampleCount,
                (1...Self.maximumRollingWindowSampleCount).contains(rollingWindowSampleCount)
            else { throw JitterError.invalidConfiguration }
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
        definition = "hdxl-jitter-period-statistics-v1"
        denominatorDefinition = "separateMeanRejectBothAdjacentRatiosRetainOutsideQueryContext"
        neighborhoodDefinition = "completeConsecutivePeriodsWithinQueryWithoutStitching"
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
        case maximumAdjacentPeriodFactor, definition, denominatorDefinition, neighborhoodDefinition
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            sampleRate: c.decode(Int.self, forKey: .sampleRate),
            inputPrecision: c.decode(AnalysisPrecision.self, forKey: .inputPrecision),
            applicability: c.decode(JitterApplicability.self, forKey: .applicability),
            rollingWindowSampleCount: c.decodeIfPresent(Int.self, forKey: .rollingWindowSampleCount),
            minimumPeriodSeconds: c.decode(Double.self, forKey: .minimumPeriodSeconds),
            maximumPeriodSeconds: c.decode(Double.self, forKey: .maximumPeriodSeconds),
            maximumAdjacentPeriodFactor: c.decode(Double.self, forKey: .maximumAdjacentPeriodFactor))
        guard try c.decode(AnalysisPrecision.self, forKey: .arithmeticPrecision) == arithmeticPrecision,
            try c.decode(String.self, forKey: .definition) == definition,
            try c.decode(String.self, forKey: .denominatorDefinition) == denominatorDefinition,
            try c.decode(String.self, forKey: .neighborhoodDefinition) == neighborhoodDefinition
        else { throw JitterError.invalidConfiguration }
    }
}
