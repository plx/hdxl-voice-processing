import Foundation

public enum YINVoicingStatus: String, Sendable, Hashable, Codable {
    case voiced, uncertain, unvoiced, unavailable
}

/// A raw local dip or the retained global fallback. Periodicity is an algorithm
/// statistic (max(0, 1-error)), never a calibrated probability or quality score.
public struct YINCandidate: Sendable, Hashable {
    public let integerLag: Int
    public let unboundedPeriodSamples: Double
    public let periodSamples: Double
    public let frequencyHz: Double
    public let normalizedError: Double
    public let periodicity: Double
    public let isLocalMinimum: Bool
    public let isGlobalMinimum: Bool
    public let isInRange: Bool
    public let isThresholdQualified: Bool
    /// The explicit numerical boundary rule was applied, even if already exact.
    public let isBoundaryCanonicalized: Bool
}

/// Small owned result; detailed candidates and curves are borrowed separately.
public struct YINFrameResult: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let frameIndex: UInt64
    public let timing: AnalysisTiming
    public let requiredSampleCount: Int
    public let status: YINVoicingStatus
    public let observation: YINCandidate?
    public let selectedCandidateIndex: Int?
    public let unavailability: UnavailabilityReason?
    public let normalizationPeak: Double?
    public let rms: Double?

    /// Explicit allocation/persistence boundary. An uncertain estimate stays
    /// available with lowConfidence; missing pitch is never represented by 0 Hz.
    public func measurementResult() throws -> MeasurementResult {
        let outcome: MeasurementOutcome
        if let observation {
            outcome = .available(
                try ScalarEstimate(
                    value: observation.frequencyHz, confidence: observation.periodicity,
                    warnings: status == .uncertain ? [.lowConfidence] : []))
        } else {
            guard let unavailability else { throw ContractError.invalidValue }
            outcome = .unavailable(unavailability)
        }
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .fundamentalFrequency, unit: .hertz, algorithm: profile.identifier),
            profile: profile, timing: timing, outcome: outcome)
    }
}

public enum YINIntermediate: String, Sendable, Hashable, CaseIterable {
    case scaledSquaredDifference, cumulativeMeanNormalizedDifference
}

/// All buffers are valid only during the synchronous callback. Full unsupported
/// or uncertain frames retain their diagnostics; partial frames expose empty arrays.
public struct BorrowedYINOutput {
    public let result: YINFrameResult
    public let candidates: UnsafeBufferPointer<YINCandidate>
    private let difference: UnsafeBufferPointer<Double>
    private let cmnd: UnsafeBufferPointer<Double>

    package init(
        result: YINFrameResult, candidates: UnsafeBufferPointer<YINCandidate>,
        difference: UnsafeBufferPointer<Double>, cmnd: UnsafeBufferPointer<Double>
    ) {
        self.result = result
        self.candidates = candidates
        self.difference = difference
        self.cmnd = cmnd
    }
    public func values(_ stage: YINIntermediate) -> UnsafeBufferPointer<Double> {
        switch stage {
        case .scaledSquaredDifference: difference
        case .cumulativeMeanNormalizedDifference: cmnd
        }
    }
    public func exportCandidates(maximumCount: Int) throws -> [YINCandidate] {
        guard candidates.count <= maximumCount else {
            throw ContractError.intermediateBudgetExceeded
        }
        return Array(candidates)
    }
    public func export(stages: Set<YINIntermediate>, policy: IntermediateOutputPolicy) throws
        -> [IntermediateSnapshot]
    {
        var remaining = policy.maximumScalarCount
        var snapshots: [IntermediateSnapshot] = []
        for stage in YINIntermediate.allCases where stages.contains(stage) {
            let data = values(stage)
            guard data.count <= remaining else { throw ContractError.intermediateBudgetExceeded }
            remaining -= data.count
            if !data.isEmpty {
                snapshots.append(
                    try IntermediateSnapshot(
                        stage: VersionedIdentifier(name: "yin-" + stage.rawValue, version: 1),
                        source: result.timing.source, xUnit: .samples,
                        yUnit: stage == .scaledSquaredDifference
                            ? .normalizedSquaredAmplitude : .dimensionless,
                        xOrigin: 0, xStep: 1, values: Array(data)))
            }
        }
        return snapshots
    }
}

public struct YINExecutionStatistics: Sendable, Hashable {
    /// Owned buffers, including candidate records; excludes opaque FFT setup tables.
    public let preparedBufferBytes: Int
    public let fftLength: Int
    public let analyzedFrameCount: UInt64
    public let directlyRecomputedLagCount: UInt64
    public let scalarFallbackFrameCount: UInt64
}
