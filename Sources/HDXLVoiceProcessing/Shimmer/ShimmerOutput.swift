import Foundation

public enum ShimmerEstimateStatus: String, Sendable, Hashable, Codable {
    case available, unavailable, notRequested
}

public struct ShimmerEstimate: Sendable, Hashable, Encodable {
    public let variant: ShimmerVariant
    public let unit: MeasurementUnit
    public let status: ShimmerEstimateStatus
    public let value: Double?
    public let unavailability: UnavailabilityReason?

    init(
        variant: ShimmerVariant, value: Double?, unavailable: UnavailabilityReason?, requested: Bool
    ) {
        self.variant = variant
        unit = variant.unit
        if !requested {
            status = .notRequested
            self.value = nil
            unavailability = nil
        } else if let value, value.isFinite, value >= 0 {
            status = .available
            self.value = value == 0 ? 0 : value
            unavailability = nil
        } else {
            status = .unavailable
            self.value = nil
            unavailability = unavailable ?? .analysisFailure
        }
    }
}

/// Predicates overlap. Counts of source observations and numerical edges are
/// separate and must not be summed as if they partitioned the input.
public struct ShimmerRejectionCounts: Sendable, Hashable, Encodable {
    public internal(set) var excluded = 0
    public internal(set) var discontinuity = 0
    public internal(set) var unreliable = 0
    public internal(set) var missingAcquisition = 0
    public internal(set) var invalidInput = 0
    public internal(set) var silence = 0
    public internal(set) var insufficientSupport = 0
    public internal(set) var periodExclusion = 0
    public internal(set) var belowMinimumPairs = 0
    public internal(set) var aboveMaximumPairs = 0
    public internal(set) var amplitudeRatioPairs = 0
    public internal(set) var zeroAmplitudePairs = 0
    public internal(set) var discontinuousPairs = 0

    mutating func add(_ reasons: ShimmerAmplitudeRejections) {
        if reasons.contains(.excluded) { excluded += 1 }
        if reasons.contains(.discontinuity) { discontinuity += 1 }
        if reasons.contains(.unreliable) { unreliable += 1 }
        if reasons.contains(.missingAcquisition) { missingAcquisition += 1 }
        if reasons.contains(.invalidInput) { invalidInput += 1 }
        if reasons.contains(.silence) { silence += 1 }
        if reasons.contains(.insufficientSupport) { insufficientSupport += 1 }
        if reasons.contains(.periodExclusion) { periodExclusion += 1 }
    }
}

public struct ShimmerCoverage: Sendable, Hashable, Encodable {
    public let inputAmplitudeCount: Int
    public let selectedAmplitudeCount: Int
    /// Source-eligible values, including zero. Numerator windows require positive values.
    public let acceptedAmplitudeCount: Int
    public let positiveAmplitudeCount: Int
    public let zeroAmplitudeCount: Int
    public let normalizationAmplitudeCount: Int
    /// Nil when no denominator exists or a positive mean is too small to represent.
    /// The scaled representation distinguishes those cases from actual zero energy.
    public let meanAmplitude: Double?
    public let normalizationScale: Double
    public let scaledMeanAmplitude: Double
    public let acceptedPairCount: Int
    public let acceptedAPQ3NeighborhoodCount: Int
    public let acceptedAPQ5NeighborhoodCount: Int
    public let acceptedAPQ11NeighborhoodCount: Int
    public let candidatePairCount: Int
    public let candidateAPQ3NeighborhoodCount: Int
    public let candidateAPQ5NeighborhoodCount: Int
    public let candidateAPQ11NeighborhoodCount: Int
    public let analyzedDurationSeconds: Double
    /// Nonoverlapping timestamp intervals between accepted adjacent amplitudes.
    public let acceptedPairDurationSeconds: Double
    public let rejections: ShimmerRejectionCounts

    public var durationCoverage: Double {
        analyzedDurationSeconds > 0
            ? min(1, acceptedPairDurationSeconds / analyzedDurationSeconds) : 0
    }
    public var pairCoverage: Double {
        candidatePairCount > 0 ? Double(acceptedPairCount) / Double(candidatePairCount) : 0
    }
    public var apq3NeighborhoodCoverage: Double {
        candidateAPQ3NeighborhoodCount > 0
            ? Double(acceptedAPQ3NeighborhoodCount) / Double(candidateAPQ3NeighborhoodCount) : 0
    }
    public var apq5NeighborhoodCoverage: Double {
        candidateAPQ5NeighborhoodCount > 0
            ? Double(acceptedAPQ5NeighborhoodCount) / Double(candidateAPQ5NeighborhoodCount) : 0
    }
    public var apq11NeighborhoodCoverage: Double {
        candidateAPQ11NeighborhoodCount > 0
            ? Double(acceptedAPQ11NeighborhoodCount) / Double(candidateAPQ11NeighborhoodCount) : 0
    }

    init(
        raw: ShimmerKernelResult, inputCount: Int, duration: Double,
        sourceRejections: ShimmerRejectionCounts
    ) {
        inputAmplitudeCount = inputCount
        selectedAmplitudeCount = raw.selectedAmplitudeCount
        acceptedAmplitudeCount = raw.acceptedAmplitudeCount
        positiveAmplitudeCount = raw.positiveAmplitudeCount
        zeroAmplitudeCount = raw.zeroAmplitudeCount
        normalizationAmplitudeCount = raw.normalizationCount
        meanAmplitude = raw.meanAmplitude
        normalizationScale = raw.normalizationScale
        scaledMeanAmplitude = raw.scaledMeanAmplitude
        acceptedPairCount = raw.pairCount
        acceptedAPQ3NeighborhoodCount = raw.apq3Count
        acceptedAPQ5NeighborhoodCount = raw.apq5Count
        acceptedAPQ11NeighborhoodCount = raw.apq11Count
        candidatePairCount = raw.candidatePairCount
        candidateAPQ3NeighborhoodCount = raw.candidateAPQ3Count
        candidateAPQ5NeighborhoodCount = raw.candidateAPQ5Count
        candidateAPQ11NeighborhoodCount = raw.candidateAPQ11Count
        analyzedDurationSeconds = duration
        acceptedPairDurationSeconds = raw.acceptedPairSeconds
        var counts = sourceRejections
        counts.belowMinimumPairs = raw.belowMinimumPairCount
        counts.aboveMaximumPairs = raw.aboveMaximumPairCount
        counts.amplitudeRatioPairs = raw.amplitudeRatioPairCount
        counts.zeroAmplitudePairs = raw.zeroAmplitudePairCount
        counts.discontinuousPairs = raw.discontinuousPairCount
        rejections = counts
    }
}

/// Fixed-size owned results with explicit query, upstream timing and provenance.
/// Encodable export is not an untrusted archive-import API.
public struct ShimmerAnalysisResult: Sendable, Hashable, Encodable {
    public let schemaVersion: Int
    public let profile: ProfileIdentity
    public let applicability: ShimmerApplicability
    public let dependencyTiming: AnalysisTiming
    public let query: ShimmerQueryRange
    public let sampleAlignedQuery: SourceInterval?
    public let inputProvenance: ShimmerInputProvenance
    public let coverage: ShimmerCoverage
    public let local: ShimmerEstimate
    public let db: ShimmerEstimate
    public let apq3: ShimmerEstimate
    public let apq5: ShimmerEstimate
    public let apq11: ShimmerEstimate
    public let dda: ShimmerEstimate

    public var queryCenterSourceSeconds: Double {
        let center =
            sampleAlignedQuery.map {
                Double($0.startSample - dependencyTiming.source.startSample) / $0.sampleRate + $0
                    .durationSeconds / 2
            } ?? query.centerSeconds
        return
            (dependencyTiming.sourceStartSeconds
            ?? Double(dependencyTiming.source.startSample) / dependencyTiming.source.sampleRate)
            + center
    }

    public func estimate(_ variant: ShimmerVariant) -> ShimmerEstimate {
        switch variant {
        case .local: local
        case .db: db
        case .apq3: apq3
        case .apq5: apq5
        case .apq11: apq11
        case .dda: dda
        }
    }

    /// Scalar persistence allocates warning/serialization storage. Retain this
    /// typed report to preserve the query coordinates and normalization population.
    public func measurementResult(
        _ variant: ShimmerVariant, unit requestedUnit: MeasurementUnit? = nil
    ) throws -> MeasurementResult {
        let estimate = estimate(variant)
        guard estimate.status != .notRequested else { throw ShimmerError.measurementNotRequested }
        let unit = requestedUnit ?? variant.unit
        guard variant.measurementKind.accepts(unit) else { throw ContractError.invalidUnit }
        let outcome: MeasurementOutcome
        if let value = estimate.value {
            var warnings: [MeasurementWarning] = []
            if applicability == .exploratoryRolling { warnings.append(.exploratoryApplicability) }
            if coverage.durationCoverage < 1
                || coverage.acceptedAmplitudeCount < coverage.selectedAmplitudeCount
            {
                warnings.append(.partialCoverage)
            }
            outcome = .available(
                try ScalarEstimate(
                    value: unit == .percent ? value * 100 : value, warnings: warnings))
        } else {
            outcome = .unavailable(estimate.unavailability ?? .analysisFailure)
        }
        return try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: variant.measurementKind, unit: unit, algorithm: profile.identifier),
            profile: profile, timing: dependencyTiming, outcome: outcome)
    }

    public func canonicalJSON() throws -> Data { try canonicalContractJSON(self) }

    init(
        raw: ShimmerKernelResult, configuration: ShimmerConfiguration, identity: ProfileIdentity,
        timing: AnalysisTiming, query: ShimmerQueryRange, provenance: ShimmerInputProvenance,
        inputCount: Int, sourceRejections: ShimmerRejectionCounts,
        sourceUnavailability: UnavailabilityReason?, requested: ShimmerRequestedVariants,
        sampleAlignedQuery: SourceInterval? = nil
    ) {
        schemaVersion = 1
        profile = identity
        applicability = configuration.applicability
        dependencyTiming = timing
        self.query = query
        self.sampleAlignedQuery = sampleAlignedQuery
        inputProvenance = provenance
        coverage = ShimmerCoverage(
            raw: raw, inputCount: inputCount,
            duration: sampleAlignedQuery?.durationSeconds ?? query.durationSeconds,
            sourceRejections: sourceRejections)
        func unavailable(_ variant: ShimmerVariant) -> UnavailabilityReason {
            if timing.includedSampleCount == 0 && timing.source.sampleCount > 0 { return .excluded }
            if let sourceUnavailability, raw.acceptedAmplitudeCount == 0 {
                return sourceUnavailability
            }
            if raw.selectedAmplitudeCount > 0
                && raw.unreliableAmplitudeCount == raw.selectedAmplitudeCount
            {
                if sourceRejections.excluded == raw.selectedAmplitudeCount { return .excluded }
                if sourceRejections.invalidInput > 0 { return .invalidInput }
                if sourceRejections.missingAcquisition > 0 { return .missingAcquisition }
                if sourceRejections.silence == raw.selectedAmplitudeCount { return .silence }
                if sourceRejections.discontinuity > 0 { return .discontinuity }
                if sourceRejections.insufficientSupport > 0 { return .insufficientData }
                if sourceRejections.periodExclusion > 0 { return .unsupportedRange }
                return .lowConfidence
            }
            if (raw.acceptedAmplitudeCount > 0 && raw.positiveAmplitudeCount == 0)
                || (raw.normalizationCount > 0 && raw.normalizationScale == 0)
            {
                return .silence
            }
            if raw.positiveAmplitudeCount < variant.minimumConsecutiveAmplitudeCount {
                return .insufficientData
            }
            if raw.belowMinimumPairCount + raw.aboveMaximumPairCount > 0 {
                return .unsupportedRange
            }
            if raw.discontinuousPairCount > 0 { return .discontinuity }
            if raw.amplitudeRatioPairCount > 0 { return .lowConfidence }
            if raw.zeroAmplitudePairCount > 0 { return .silence }
            return .insufficientData
        }
        func estimate(_ variant: ShimmerVariant) -> ShimmerEstimate {
            let value = timing.includedSampleCount == 0 ? nil : raw.value(variant)
            return ShimmerEstimate(
                variant: variant, value: value,
                unavailable: value == nil ? unavailable(variant) : nil,
                requested: requested.contains(.init(variant)))
        }
        local = estimate(.local)
        db = estimate(.db)
        apq3 = estimate(.apq3)
        apq5 = estimate(.apq5)
        apq11 = estimate(.apq11)
        dda = estimate(.dda)
    }
}

public struct ShimmerExecutionStatistics: Sendable, Hashable {
    public let preparedBufferBytes: Int
    public let analyzedQueryCount: UInt64
    public let lastInputAmplitudeCount: Int
}
