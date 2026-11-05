import Foundation

public struct CPPSFrameResult: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let sourceProfile: ProfileIdentity
    /// Original, unsmoothed CPP for the same frame center.
    public let rawCPP: CPPFrameResult
    /// Timing includes the union of dependencies used by temporal smoothing.
    public let context: CepstralFrameContext
    public let observation: CPPObservation?
    public let unavailability: UnavailabilityReason?
    public let temporalSupportFrameCount: Int
    public let usesSmoothingEdge: Bool
    public let lookaheadSeconds: Double

    public func measurementResult() throws -> MeasurementResult {
        let outcome: MeasurementOutcome
        if let observation {
            let warnings: [MeasurementWarning] =
                usesSmoothingEdge || context.usesBoundaryExtension ? [.partialCoverage] : []
            outcome = .available(
                try ScalarEstimate(value: observation.prominenceDB, warnings: warnings))
        } else {
            guard let unavailability else { throw ContractError.invalidValue }
            outcome = .unavailable(unavailability)
        }
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .cpps, unit: .decibelsRatio,
                algorithm: profile.identifier),
            profile: profile, timing: context.timing, outcome: outcome)
    }
}

public enum CPPSIntermediate: String, Sendable, Hashable, CaseIterable {
    case rawPower, preparedPower, timeSmoothedPower, smoothedPower
    case smoothedDB, backgroundDB, residualDB

    public var unit: MeasurementUnit {
        switch self {
        case .rawPower, .preparedPower, .timeSmoothedPower, .smoothedPower: .inverseSecondsSquared
        default: .decibelsRatio
        }
    }
}

/// Borrowed scratch valid only in the synchronous callback. It contains no display
/// smoothing. Unavailable final stages are empty, never leftover scratch values.
public struct BorrowedCPPSOutput {
    public let result: CPPSFrameResult
    public let quefrencyStepSeconds: Double
    public let powerIsTrendNormalized: Bool
    private let raw: UnsafeBufferPointer<Double>
    private let prepared: UnsafeBufferPointer<Double>
    private let temporal: UnsafeBufferPointer<Double>
    private let smoothed: UnsafeBufferPointer<Double>
    private let fit: BorrowedCPPOutput?

    package init(
        result: CPPSFrameResult, quefrencyStepSeconds: Double, powerIsTrendNormalized: Bool,
        raw: UnsafeBufferPointer<Double>, prepared: UnsafeBufferPointer<Double>,
        temporal: UnsafeBufferPointer<Double>, smoothed: UnsafeBufferPointer<Double>,
        fit: BorrowedCPPOutput?
    ) {
        self.result = result
        self.quefrencyStepSeconds = quefrencyStepSeconds
        self.powerIsTrendNormalized = powerIsTrendNormalized
        self.raw = raw
        self.prepared = prepared
        self.temporal = temporal
        self.smoothed = smoothed
        self.fit = fit
    }

    public func values(_ stage: CPPSIntermediate) -> UnsafeBufferPointer<Double> {
        switch stage {
        case .rawPower: raw
        case .preparedPower: prepared
        case .timeSmoothedPower: temporal
        case .smoothedPower: smoothed
        case .smoothedDB: fit?.values(.cepstralDB) ?? UnsafeBufferPointer(start: nil, count: 0)
        case .backgroundDB: fit?.values(.backgroundDB) ?? UnsafeBufferPointer(start: nil, count: 0)
        case .residualDB: fit?.values(.residualDB) ?? UnsafeBufferPointer(start: nil, count: 0)
        }
    }

    public func export(stages: Set<CPPSIntermediate>, policy: IntermediateOutputPolicy) throws
        -> [IntermediateSnapshot]
    {
        var remaining = policy.maximumScalarCount
        var output: [IntermediateSnapshot] = []
        for stage in CPPSIntermediate.allCases where stages.contains(stage) {
            let data = values(stage)
            guard data.count <= remaining else { throw ContractError.intermediateBudgetExceeded }
            remaining -= data.count
            if !data.isEmpty {
                let unit: MeasurementUnit =
                    powerIsTrendNormalized && stage != .rawPower
                        && stage.unit == .inverseSecondsSquared ? .dimensionless : stage.unit
                output.append(
                    try IntermediateSnapshot(
                        stage: VersionedIdentifier(name: "cpps-" + stage.rawValue, version: 1),
                        source: result.context.timing.source, xUnit: .seconds, yUnit: unit,
                        xOrigin: 0, xStep: quefrencyStepSeconds, values: Array(data)))
            }
        }
        return output
    }
}

/// Equal-weight mean over all frames of one independently conditioned interval.
/// Any unavailable frame makes this strict interval mean unavailable. Downstream
/// selected-region and rolling statistics have their own policies and identities.
public struct CPPSCompletion: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let source: SourceInterval
    public let frameCount: Int
    public let availableFrameCount: Int
    public let meanDB: Double?
    public let unavailability: UnavailabilityReason?
}
