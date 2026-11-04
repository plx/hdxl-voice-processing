import Foundation

public enum UnavailabilityReason: String, Sendable, Hashable, Codable, CaseIterable {
    case insufficientData, silence, clipping, unsupportedRange, inapplicableTask
    case lowConfidence, invalidInput, discontinuity, analysisFailure, cancelled
}

/// Warnings preserve an inspectable numeric estimate without presenting it as unqualified.
public enum MeasurementWarning: String, Sendable, Hashable, Codable {
    case clipping, lowConfidence, partialCoverage, exploratoryApplicability
}

public struct ScalarEstimate: Sendable, Hashable, Codable {
    public let value: Double
    /// Algorithm-defined confidence, not a probability of voice health or pleasantness.
    public let confidence: Double?
    public let warnings: [MeasurementWarning]

    public init(value: Double, confidence: Double? = nil, warnings: [MeasurementWarning] = [])
        throws
    {
        guard value.isFinite else { throw ContractError.invalidValue }
        if let confidence {
            guard confidence.isFinite, (0...1).contains(confidence) else {
                throw ContractError.invalidConfidence
            }
        }
        self.value = value == 0 ? 0 : value
        self.confidence = confidence.map { $0 == 0 ? 0 : $0 }
        self.warnings = Array(Set(warnings)).sorted { $0.rawValue < $1.rawValue }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case value, confidence, warnings }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            value: c.decode(Double.self, forKey: .value),
            confidence: c.decodeIfPresent(Double.self, forKey: .confidence),
            warnings: c.decode([MeasurementWarning].self, forKey: .warnings))
    }
}

/// Unavailability carries no number. A valid zero requires an explicit finite estimate.
public enum MeasurementOutcome: Sendable, Hashable, Codable {
    case available(ScalarEstimate)
    case unavailable(UnavailabilityReason)

    public var estimate: ScalarEstimate? {
        if case .available(let value) = self { return value }
        return nil
    }

    private enum Status: String, Codable { case available, unavailable }
    private enum CodingKeys: String, CodingKey, CaseIterable { case status, estimate, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        switch try c.decode(Status.self, forKey: .status) {
        case .available:
            guard !c.contains(.reason) else { throw ContractError.invalidValue }
            self = .available(try c.decode(ScalarEstimate.self, forKey: .estimate))
        case .unavailable:
            guard !c.contains(.estimate) else { throw ContractError.invalidValue }
            self = .unavailable(try c.decode(UnavailabilityReason.self, forKey: .reason))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .available(let estimate):
            try c.encode(Status.available, forKey: .status)
            try c.encode(estimate, forKey: .estimate)
        case .unavailable(let reason):
            try c.encode(Status.unavailable, forKey: .status)
            try c.encode(reason, forKey: .reason)
        }
    }
}

/// An owned, immutable one-dimensional intermediate with explicit stage, axes, and support.
/// Result construction enforces the shared scalar budget. This type retains no processor scratch.
public struct IntermediateSnapshot: Sendable, Hashable, Codable {
    public let stage: VersionedIdentifier
    public let source: SourceInterval
    public let xUnit: MeasurementUnit
    public let yUnit: MeasurementUnit
    public let xOrigin: Double
    public let xStep: Double
    public let values: [Double]

    public init(
        stage: VersionedIdentifier, source: SourceInterval, xUnit: MeasurementUnit,
        yUnit: MeasurementUnit,
        xOrigin: Double, xStep: Double, values: [Double]
    ) throws {
        guard !values.isEmpty, values.allSatisfy(\.isFinite), xOrigin.isFinite,
            xStep.isFinite, xStep > 0,
            (xOrigin + Double(values.count - 1) * xStep).isFinite
        else { throw ContractError.invalidValue }
        self.stage = stage
        self.source = source
        self.xUnit = xUnit
        self.yUnit = yUnit
        self.xOrigin = xOrigin == 0 ? 0 : xOrigin
        self.xStep = xStep
        self.values = values.map { $0 == 0 ? 0 : $0 }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case stage, source, xUnit, yUnit, xOrigin, xStep, values
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            stage: c.decode(VersionedIdentifier.self, forKey: .stage),
            source: c.decode(SourceInterval.self, forKey: .source),
            xUnit: c.decode(MeasurementUnit.self, forKey: .xUnit),
            yUnit: c.decode(MeasurementUnit.self, forKey: .yUnit),
            xOrigin: c.decode(Double.self, forKey: .xOrigin),
            xStep: c.decode(Double.self, forKey: .xStep),
            values: c.decode([Double].self, forKey: .values))
    }
}

/// Scalar measurements carry provenance even when no numeric value is available.
public struct MeasurementResult: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let measurement: MeasurementDescriptor
    public let profile: ProfileIdentity
    public let timing: AnalysisTiming
    public let outcome: MeasurementOutcome
    public let intermediatePolicy: IntermediateOutputPolicy
    public let intermediates: [IntermediateSnapshot]

    public init(
        measurement: MeasurementDescriptor, profile: ProfileIdentity, timing: AnalysisTiming,
        outcome: MeasurementOutcome, intermediatePolicy: IntermediateOutputPolicy = .disabled,
        intermediates: [IntermediateSnapshot] = []
    ) throws {
        if case .available = outcome, timing.includedSampleCount == 0 {
            throw ContractError.invalidCoverage
        }
        var remaining = intermediatePolicy.maximumScalarCount
        for snapshot in intermediates {
            guard snapshot.source.epoch == timing.source.epoch else {
                throw ContractError.invalidInterval
            }
            guard snapshot.values.count <= remaining else {
                throw ContractError.intermediateBudgetExceeded
            }
            remaining -= snapshot.values.count
        }
        self.schemaVersion = 1
        self.measurement = measurement
        self.profile = profile
        self.timing = timing
        self.outcome = outcome
        self.intermediatePolicy = intermediatePolicy
        self.intermediates = intermediates
    }

    public func canonicalJSON() throws -> Data { try canonicalContractJSON(self) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, measurement, profile, timing, outcome, intermediatePolicy, intermediates
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw ContractError.unsupportedSchemaVersion(version) }
        try self.init(
            measurement: c.decode(MeasurementDescriptor.self, forKey: .measurement),
            profile: c.decode(ProfileIdentity.self, forKey: .profile),
            timing: c.decode(AnalysisTiming.self, forKey: .timing),
            outcome: c.decode(MeasurementOutcome.self, forKey: .outcome),
            intermediatePolicy: c.decode(
                IntermediateOutputPolicy.self, forKey: .intermediatePolicy),
            intermediates: c.decode([IntermediateSnapshot].self, forKey: .intermediates))
    }
}
