import Foundation

/// A prepared amplitude reference with its complete acquired dependency. Values
/// are scaled before mean removal to avoid overflowing on large finite PCM.
public struct HNRNormalization: Sendable, Hashable {
    public let definition: HNRNormalizationDefinition
    public let inputPrecision: AnalysisPrecision
    public let timing: AnalysisTiming
    public let amplitudeScale: Double
    public let scaledMean: Double
    public let scaledMeanRemovedPeak: Double

    public init<Sample: BinaryFloatingPoint & Sendable>(
        _ input: UnsafeBufferPointer<Sample>, timing: AnalysisTiming,
        definition: HNRNormalizationDefinition
    ) throws {
        guard Sample.self == Float.self || Sample.self == Double.self else {
            throw HNRError.precisionMismatch
        }
        guard timing.source.sampleCount == Int64(input.count),
            timing.includedSampleCount == timing.source.sampleCount
        else { throw HNRError.unexpectedContext }
        var scale = 0.0
        for value in input {
            guard value.isFinite else { throw HNRError.invalidInput }
            scale = max(scale, abs(Double(value)))
        }
        var sum = HNRSum()
        if scale > 0 { for value in input { sum.add(Double(value) / scale) } }
        let mean = input.isEmpty ? 0 : sum.value / Double(input.count)
        var peak = 0.0
        if scale > 0 { for value in input { peak = max(peak, abs(Double(value) / scale - mean)) } }
        self.definition = definition
        self.inputPrecision = Sample.self == Float.self ? .float32 : .float64
        self.timing = timing
        self.amplitudeScale = scale
        self.scaledMean = mean
        self.scaledMeanRemovedPeak = peak
    }
}

public enum HNRPeakDisposition: String, Sendable, Hashable, Codable {
    case numericallyFlat, invalidInterpolation, discardedByCapacity, retained
    case nonpositiveRefinement
}

/// Candidates are ordered by integer lag, including rejected numerical peaks.
/// Periodicity is an estimator statistic, not a calibrated probability.
public struct HNRPeakCandidate: Sendable, Hashable {
    public let integerLag: Int
    public let curvature: Double
    public internal(set) var disposition: HNRPeakDisposition
    public internal(set) var initialPeriodSamples: Double?
    public internal(set) var initialPeriodicity: Double?
    public internal(set) var periodSamples: Double?
    public internal(set) var frequencyHz: Double?
    public internal(set) var estimate: HNRPeriodicityEstimate?
}

public struct HNRFrameResult: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let frameIndex: UInt64
    /// Acquired local windows; separate from the potentially much longer amplitude dependency.
    public let frameTiming: AnalysisTiming
    public let dependencyTiming: AnalysisTiming
    /// Relative to dependencyTiming.source, not necessarily the entire stream origin.
    public let centerSecondsFromNormalizationOrigin: Double
    public let centerSourceSeconds: Double
    public let strongestCandidateIndex: Int?
    public let selectedCandidateIndex: Int?
    public let strongestObservation: HNRPeriodicityEstimate?
    public let selectedObservation: HNRPeriodicityEstimate?
    public let unavailability: UnavailabilityReason?
    public let frameAmplitudeScale: Double
    public let normalizationAmplitudeScale: Double
    public let scaledNormalizationMean: Double
    public let scaledNormalizationPeak: Double
    public let scaledLocalMean: Double
    public let scaledLocalPeak: Double
    public let relativeIntensity: Double
    public let unvoicedStrength: Double
    public let hasClipping: Bool
    public let layout: HNRFrameLayout

    /// Persistence allocates. The full amplitude-reference dependency is retained;
    /// use centerSourceSeconds for plotting the actual frame's nominal position.
    /// An exact numerical zero-noise result has no finite scalar representation.
    public func measurementResult() throws -> MeasurementResult {
        let outcome: MeasurementOutcome
        if let selectedObservation, let db = selectedObservation.finiteDecibels {
            var warnings: [MeasurementWarning] = []
            if selectedObservation.periodicity < 0.5 || selectedObservation.status != .finite {
                warnings.append(.lowConfidence)
            }
            if hasClipping { warnings.append(.clipping) }
            outcome = .available(
                try ScalarEstimate(
                    value: db,
                    confidence: selectedObservation.periodicity, warnings: warnings))
        } else {
            outcome = .unavailable(unavailability ?? .unsupportedRange)
        }
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .harmonicToNoiseRatio, unit: .decibelsRatio,
                algorithm: profile.identifier), profile: profile, timing: dependencyTiming,
            outcome: outcome)
    }
}

/// Scratch views expire when the synchronous callback returns. Exporting is an
/// explicit allocation boundary; undefined correlation cells have separate flags.
public struct BorrowedHNROutput {
    public let result: HNRFrameResult
    public let candidates: UnsafeBufferPointer<HNRPeakCandidate>
    public let scaledWindowedSamples: UnsafeBufferPointer<Double>
    public let correlation: UnsafeBufferPointer<Double>
    public let correlationValidity: UnsafeBufferPointer<Bool>
    public let windowCorrelation: UnsafeBufferPointer<Double>
    public let signalCorrelation: UnsafeBufferPointer<Double>

    public func exportCandidates(maximumCount: Int) throws -> [HNRPeakCandidate] {
        guard candidates.count <= maximumCount else {
            throw ContractError.intermediateBudgetExceeded
        }
        return Array(candidates)
    }
}

public struct HNRExecutionStatistics: Sendable, Hashable {
    public let preparedBufferBytes: Int
    public let transformLength: Int
    public let analyzedFrameCount: UInt64
    public let directlyRecomputedEnergyLagCount: UInt64
}
