import Foundation

/// Finite estimates in explicit units. These are numerical fit diagnostics,
/// not confidence in vocal health, pleasantness, or an independent F0 estimate.
public struct CPPObservation: Sendable, Hashable {
    public let prominenceDB: Double
    public let peakQuefrencySeconds: Double
    /// 10*log10(power + 1e-30), relative to one inverse-second-squared.
    public let peakDB: Double
    public let backgroundDB: Double
    public let slopeDBPerSecond: Double
    public let interceptDB: Double
    public let residualMeanDB: Double
    public let residualRMSDB: Double
    public let residualMedianDB: Double
    public let residualMaximumAbsoluteDB: Double
    public let peakIsAtSearchBoundary: Bool
    /// The pinned bidirectional rule can average close competing/tied peak indices.
    public let usedBidirectionalTieRule: Bool
}

/// Small owned scalar result. It keeps timing and upstream identity even when
/// unavailable. Detailed arrays are separate opt-in exports of borrowed scratch.
public struct CPPFrameResult: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let sourceProfile: ProfileIdentity
    public let context: CepstralFrameContext
    public let layout: CPPLayout
    public let observation: CPPObservation?
    public let unavailability: UnavailabilityReason?

    /// Explicit export to the shared, strictly Codable measurement contract.
    /// This is outside the prepared allocation-free processing contract.
    public func measurementResult() throws -> MeasurementResult {
        let outcome: MeasurementOutcome
        if let observation {
            let warnings: [MeasurementWarning] =
                context.usesBoundaryExtension ? [.partialCoverage] : []
            outcome = .available(
                try ScalarEstimate(value: observation.prominenceDB, warnings: warnings))
        } else {
            guard let unavailability else { throw ContractError.invalidValue }
            outcome = .unavailable(unavailability)
        }
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .cpp, unit: .decibelsRatio,
                algorithm: profile.identifier),
            profile: profile, timing: context.timing, outcome: outcome)
    }
}

public enum CPPIntermediate: String, Sendable, Hashable, CaseIterable {
    case cepstralDB, backgroundDB, residualDB
}

/// Non-Sendable borrowed arrays, valid only during the synchronous callback.
/// The input power cepstrum is never modified. Fit diagnostics use only the
/// resolved fit bins; exported background/residual arrays cover the whole grid.
public struct BorrowedCPPOutput {
    public let result: CPPFrameResult
    private let decibels: UnsafeBufferPointer<Double>
    private let background: UnsafeBufferPointer<Double>
    private let residual: UnsafeBufferPointer<Double>

    package init(
        result: CPPFrameResult, decibels: UnsafeBufferPointer<Double>,
        background: UnsafeBufferPointer<Double>, residual: UnsafeBufferPointer<Double>
    ) {
        self.result = result
        self.decibels = decibels
        self.background = background
        self.residual = residual
    }
    /// Unavailable results expose empty arrays, never stale values from a prior frame.
    public func values(_ stage: CPPIntermediate) -> UnsafeBufferPointer<Double> {
        switch stage {
        case .cepstralDB: decibels
        case .backgroundDB: background
        case .residualDB: residual
        }
    }
    public func export(stages: Set<CPPIntermediate>, policy: IntermediateOutputPolicy) throws
        -> [IntermediateSnapshot]
    {
        var remaining = policy.maximumScalarCount
        var result: [IntermediateSnapshot] = []
        for stage in CPPIntermediate.allCases where stages.contains(stage) {
            let data = values(stage)
            guard data.count <= remaining else { throw ContractError.intermediateBudgetExceeded }
            remaining -= data.count
            if !data.isEmpty {
                result.append(
                    try IntermediateSnapshot(
                        stage: VersionedIdentifier(name: "cpp-" + stage.rawValue, version: 1),
                        source: self.result.context.timing.source, xUnit: .seconds,
                        yUnit: .decibelsRatio, xOrigin: 0,
                        xStep: self.result.layout.quefrencyStepSeconds, values: Array(data)))
            }
        }
        return result
    }
}
