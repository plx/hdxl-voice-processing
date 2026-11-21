import Foundation

public enum SWIPEPrimeVoicingStatus: String, Sendable, Hashable, Codable {
    case voiced, uncertain, unvoiced, unavailable
}

/// A discrete candidate; nil strength means an undefined required window norm.
/// A numerical zero or negative strength remains a number, never missing data.
public struct SWIPEPrimeCandidate: Sendable, Hashable, Encodable {
    public let frequencyHz: Double
    public let pitchStrength: Double?
}

/// The winning candidate and its optional period-axis refinement. Strength is
/// signed, uncalibrated, and may be outside 0...1; it is not a probability.
public struct SWIPEPrimeObservation: Sendable, Hashable, Encodable {
    public let candidateIndex: Int
    public let discreteFrequencyHz: Double
    public let frequencyHz: Double
    public let discretePitchStrength: Double
    public let pitchStrength: Double
    public let isRefined: Bool
    public let isThresholdQualified: Bool
}

public struct SWIPEPrimeFrameResult: Sendable, Hashable, Encodable {
    public let profile: ProfileIdentity
    public let frameIndex: UInt64
    public let timing: AnalysisTiming
    public let requiredSampleCount: Int
    public let status: SWIPEPrimeVoicingStatus
    public let observation: SWIPEPrimeObservation?
    /// Explains missing output, or the lowConfidence warning of an uncertain
    /// available estimate. Use unavailability when only missing results matter.
    public let qualityReason: UnavailabilityReason?
    public let normalizationPeak: Double?
    public let rms: Double?
    public var unavailability: UnavailabilityReason? { observation == nil ? qualityReason : nil }
    public var selectedCandidateIndex: Int? { observation?.candidateIndex }

    /// Explicit persistence boundary. Signed strength stays in the typed result;
    /// the generic bounded confidence field is absent rather than clipped.
    public func measurementResult() throws -> MeasurementResult {
        let outcome: MeasurementOutcome
        if let observation {
            outcome = .available(
                try ScalarEstimate(
                    value: observation.frequencyHz, confidence: nil,
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

/// Borrowed scalar storage valid only during the synchronous output callback.
/// candidateIndices identifies the evaluated slots of candidateStrengths; other
/// slots are nil by construction, not additional failed measurements.
public struct BorrowedSWIPEPrimeWindow {
    public let length: Int
    public let offset: Int
    public let magnitude: UnsafeBufferPointer<Double>
    public let loudness: UnsafeBufferPointer<Double>
    public let candidateIndices: UnsafeBufferPointer<Int>
    public let candidateStrengths: UnsafeBufferPointer<Double?>
}

public struct SWIPEPrimeWindowSnapshot: Sendable, Hashable, Encodable {
    public let length: Int
    public let offset: Int
    public let magnitude: [Double]
    public let loudness: [Double]
    public let candidateIndices: [Int]
    public let candidateStrengths: [Double?]
}

public struct SWIPEPrimeKernelSnapshot: Sendable, Hashable, Encodable {
    public let candidateIndex: Int
    public let coefficients: [Double]
}

/// Owned diagnostic export. Frequency axes are explicit because the auditory
/// grid and inclusive candidate endpoints are not uniform in hertz.
public struct SWIPEPrimeIntermediateSnapshot: Sendable, Hashable, Encodable {
    public let result: SWIPEPrimeFrameResult
    public let candidateFrequenciesHz: [Double]
    public let erbFrequenciesHz: [Double]
    public let candidateStrengths: [Double?]
    public let windows: [SWIPEPrimeWindowSnapshot]
    public let kernels: [SWIPEPrimeKernelSnapshot]
}

/// Every pointer is valid only during emit. Full silence/uncertain/unavailable
/// frames retain diagnostics; partial frames expose no intermediate cells.
public struct BorrowedSWIPEPrimeOutput {
    public let result: SWIPEPrimeFrameResult
    public let candidateFrequenciesHz: UnsafeBufferPointer<Double>
    public let erbFrequenciesHz: UnsafeBufferPointer<Double>
    public let candidateStrengths: UnsafeBufferPointer<Double?>
    public let windows: UnsafeBufferPointer<BorrowedSWIPEPrimeWindow>
    package let kernelCoefficients: UnsafeBufferPointer<Double>

    public func kernel(candidateIndex: Int) throws -> UnsafeBufferPointer<Double> {
        guard candidateFrequenciesHz.indices.contains(candidateIndex) else {
            throw ContractError.invalidValue
        }
        return UnsafeBufferPointer(
            start: kernelCoefficients.baseAddress?.advanced(
                by: candidateIndex * erbFrequenciesHz.count),
            count: erbFrequenciesHz.count)
    }

    public func exportCandidates(maximumCount: Int) throws -> [SWIPEPrimeCandidate] {
        guard candidateStrengths.count <= maximumCount else {
            throw ContractError.intermediateBudgetExceeded
        }
        return candidateStrengths.indices.map {
            SWIPEPrimeCandidate(
                frequencyHz: candidateFrequenciesHz[$0], pitchStrength: candidateStrengths[$0])
        }
    }

    /// Counts every copied axis/strength/coefficient/index slot, including nil
    /// strength slots. Metadata and collection bookkeeping are outside this scalar
    /// budget. Validate the entire request before allocating any copied arrays.
    public func exportIntermediates(
        policy: IntermediateOutputPolicy, kernelCandidateIndices: [Int] = []
    ) throws -> SWIPEPrimeIntermediateSnapshot {
        var remaining = policy.maximumScalarCount
        func reserve(_ count: Int) throws {
            guard count <= remaining else { throw ContractError.intermediateBudgetExceeded }
            remaining -= count
        }
        try reserve(candidateFrequenciesHz.count)
        try reserve(erbFrequenciesHz.count)
        try reserve(candidateStrengths.count)
        for window in windows {
            try reserve(window.magnitude.count)
            try reserve(window.loudness.count)
            try reserve(window.candidateIndices.count)
            try reserve(window.candidateStrengths.count)
        }
        for index in kernelCandidateIndices {
            guard candidateFrequenciesHz.indices.contains(index) else {
                throw ContractError.invalidValue
            }
            try reserve(erbFrequenciesHz.count)
        }
        return try SWIPEPrimeIntermediateSnapshot(
            result: result, candidateFrequenciesHz: Array(candidateFrequenciesHz),
            erbFrequenciesHz: Array(erbFrequenciesHz),
            candidateStrengths: Array(candidateStrengths),
            windows: windows.map {
                SWIPEPrimeWindowSnapshot(
                    length: $0.length, offset: $0.offset, magnitude: Array($0.magnitude),
                    loudness: Array($0.loudness), candidateIndices: Array($0.candidateIndices),
                    candidateStrengths: Array($0.candidateStrengths))
            },
            kernels: kernelCandidateIndices.map {
                try SWIPEPrimeKernelSnapshot(
                    candidateIndex: $0, coefficients: Array(kernel(candidateIndex: $0)))
            })
    }
}

public struct SWIPEPrimeExecutionStatistics: Sendable, Hashable {
    /// Owned scalar, index, optional-strength, and borrowed-view storage; includes
    /// transform scratch, excludes object bookkeeping and opaque vDSP setup tables.
    public let preparedBufferBytes: Int
    public let windowCount: Int
    public let candidateCount: Int
    public let erbBinCount: Int
    public let analyzedFrameCount: UInt64
}

public struct SWIPEPrimeCompletion: Sendable, Hashable {
    public let framing: FramingCompletion
    public let isCancelled: Bool
}
