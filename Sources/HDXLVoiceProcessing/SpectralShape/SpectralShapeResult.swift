import Foundation

public enum SpectralShapeDescriptor: String, Sendable, Codable, CaseIterable {
    case centroid, spread, flatness, rollOff, bandEnergyRatio, slope

    var kind: MeasurementKind {
        switch self {
        case .centroid: .spectralCentroid
        case .spread: .spectralSpread
        case .flatness: .spectralFlatness
        case .rollOff: .spectralRollOff
        case .bandEnergyRatio: .spectralBandEnergyRatio
        case .slope: .spectralSlope
        }
    }

    func unit(for coordinate: SpectralSlopeCoordinate) -> MeasurementUnit {
        switch self {
        case .centroid, .spread, .rollOff: .hertz
        case .flatness: .dimensionless
        case .bandEnergyRatio: .decibelsRatio
        case .slope: coordinate == .hertz ? .decibelsPerHertz : .decibelsPerOctave
        }
    }
}

public struct SpectralShapeScalar: Sendable, Hashable, Encodable {
    public let measurement: MeasurementDescriptor
    public let outcome: MeasurementOutcome
}

public struct SpectralBandEnergies: Sendable, Hashable, Encodable {
    public let unit: MeasurementUnit
    public let numerator: MeasurementOutcome
    public let denominator: MeasurementOutcome
}

/// Weighted least-squares diagnostics. Levels are dB relative to one FS² of bin power.
/// The RMS residual uses the sum of fit weights as its denominator.
public struct SpectralSlopeFit: Sendable, Hashable, Encodable {
    public internal(set) var candidateBins = 0
    public internal(set) var usedBins = 0
    public internal(set) var flooredBins = 0
    public internal(set) var firstFrequencyHz: Double?
    public internal(set) var lastFrequencyHz: Double?
    public internal(set) var meanCoordinate: Double?
    public internal(set) var levelAtMeanCoordinateDB: Double?
    public internal(set) var residualRMSDB: Double?
    public internal(set) var rSquared: Double?
}

public struct SpectralShapeResult: Sendable, Hashable, Encodable {
    public let configuration: SpectralShapeProfile
    public let profile: ProfileIdentity
    public let layout: SpectrogramLayout
    public let origin: SpectrumPresentationOrigin
    public let timing: AnalysisTiming
    public let selectionCoverage: SpectralSelectionCoverage?
    public let warnings: [MeasurementWarning]
    public internal(set) var centroid: SpectralShapeScalar?
    public internal(set) var spread: SpectralShapeScalar?
    public internal(set) var flatness: SpectralShapeScalar?
    public internal(set) var rollOff: SpectralShapeScalar?
    public internal(set) var bandEnergyRatio: SpectralShapeScalar?
    public internal(set) var slope: SpectralShapeScalar?
    public internal(set) var bandEnergies: SpectralBandEnergies?
    public internal(set) var fit: SpectralSlopeFit?

    public subscript(descriptor: SpectralShapeDescriptor) -> SpectralShapeScalar? {
        switch descriptor {
        case .centroid: centroid
        case .spread: spread
        case .flatness: flatness
        case .rollOff: rollOff
        case .bandEnergyRatio: bandEnergyRatio
        case .slope: slope
        }
    }

    /// Export one computed descriptor for shared session, delivery and visualization consumers.
    public func measurement(_ descriptor: SpectralShapeDescriptor) throws -> MeasurementResult? {
        guard let scalar = self[descriptor] else { return nil }
        var outcome = scalar.outcome
        if !warnings.isEmpty, let estimate = outcome.estimate {
            outcome = .available(try ScalarEstimate(value: estimate.value, warnings: warnings))
        }
        return try MeasurementResult(
            measurement: scalar.measurement, profile: profile, timing: timing, outcome: outcome)
    }
}

func spectralShapeEstimate(_ value: Double) -> MeasurementOutcome {
    guard value.isFinite, let estimate = try? ScalarEstimate(value: value) else {
        return .unavailable(.analysisFailure)
    }
    return .available(estimate)
}
