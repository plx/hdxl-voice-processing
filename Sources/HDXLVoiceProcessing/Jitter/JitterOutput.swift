import Foundation

public enum JitterEstimateStatus: String, Sendable, Hashable, Codable {
    case available, unavailable, notRequested
}

/// Fixed-size worker output; conversion to the shared scalar persistence contract
/// is explicit. Unavailable and unrequested values are never numerical zero.
public struct JitterEstimate: Sendable, Hashable, Encodable {
    public let variant: JitterVariant
    public let unit: MeasurementUnit
    public let status: JitterEstimateStatus
    public let value: Double?
    public let unavailability: UnavailabilityReason?

    init(
        variant: JitterVariant, value: Double?, unavailable: UnavailabilityReason?, requested: Bool
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

/// Counts describe overlapping predicates, not a partition. For example, an
/// excluded out-of-bounds interval can contribute to both rejection counts.
public struct JitterRejectionCounts: Sendable, Hashable, Encodable {
    public internal(set) var excluded = 0
    public internal(set) var discontinuity = 0
    public internal(set) var unreliable = 0
    public internal(set) var missingAcquisition = 0
    public internal(set) var invalidInput = 0
    public internal(set) var silence = 0
    public internal(set) var belowMinimum = 0
    public internal(set) var aboveMaximum = 0
    public internal(set) var bothAdjacentRatios = 0
    public internal(set) var ratioPairs = 0
    public internal(set) var discontinuousPairs = 0

    mutating func add(_ reasons: JitterPeriodRejections) {
        if reasons.contains(.excluded) { excluded += 1 }
        if reasons.contains(.discontinuity) { discontinuity += 1 }
        if reasons.contains(.unreliable) { unreliable += 1 }
        if reasons.contains(.missingAcquisition) { missingAcquisition += 1 }
        if reasons.contains(.invalidInput) { invalidInput += 1 }
        if reasons.contains(.silence) { silence += 1 }
    }
}

public struct JitterCoverage: Sendable, Hashable, Encodable {
    /// Batch: full supplied sequence. Rolling: retained complete periods plus
    /// the immediate preceding context, not the lifetime observation count.
    public let inputPeriodCount: Int
    public let selectedPeriodCount: Int
    public let acceptedPeriodCount: Int
    /// Denominator membership differs from the accepted numerator neighborhoods.
    public let meanPeriodCount: Int
    public let acceptedPairCount: Int
    public let acceptedRAPNeighborhoodCount: Int
    public let acceptedPPQ5NeighborhoodCount: Int
    public let candidatePairCount: Int
    public let candidateRAPNeighborhoodCount: Int
    public let candidatePPQ5NeighborhoodCount: Int
    public let analyzedDurationSeconds: Double
    public let acceptedPeriodDurationSeconds: Double
    public let meanPeriodSeconds: Double?
    public let rejections: JitterRejectionCounts

    /// Fraction of query time covered by bounded, reliable, complete periods.
    /// This is distinct from source acquisition coverage and mean-period selection.
    public var durationCoverage: Double {
        analyzedDurationSeconds > 0
            ? min(1, acceptedPeriodDurationSeconds / analyzedDurationSeconds) : 0
    }
    public var pairCoverage: Double {
        candidatePairCount > 0 ? Double(acceptedPairCount) / Double(candidatePairCount) : 0
    }
    public var rapNeighborhoodCoverage: Double {
        candidateRAPNeighborhoodCount > 0
            ? Double(acceptedRAPNeighborhoodCount) / Double(candidateRAPNeighborhoodCount) : 0
    }
    public var ppq5NeighborhoodCoverage: Double {
        candidatePPQ5NeighborhoodCount > 0
            ? Double(acceptedPPQ5NeighborhoodCount) / Double(candidatePPQ5NeighborhoodCount) : 0
    }

    init(
        raw: JitterKernelResult, inputCount: Int, duration: Double,
        sourceRejections: JitterRejectionCounts
    ) {
        inputPeriodCount = inputCount
        selectedPeriodCount = raw.selectedPeriodCount
        acceptedPeriodCount = raw.boundedReliablePeriodCount
        meanPeriodCount = raw.meanPeriodCount
        acceptedPairCount = raw.pairCount
        acceptedRAPNeighborhoodCount = raw.rapCount
        acceptedPPQ5NeighborhoodCount = raw.ppq5Count
        candidatePairCount = raw.candidatePairCount
        candidateRAPNeighborhoodCount = raw.candidateRAPCount
        candidatePPQ5NeighborhoodCount = raw.candidatePPQ5Count
        analyzedDurationSeconds = duration
        acceptedPeriodDurationSeconds = raw.acceptedPeriodSeconds
        meanPeriodSeconds = raw.meanPeriodSeconds
        var counts = sourceRejections
        counts.belowMinimum = raw.belowMinimumCount
        counts.aboveMaximum = raw.aboveMaximumCount
        counts.bothAdjacentRatios = raw.bothRatioRejectedPeriodCount
        counts.ratioPairs = raw.rejectedRatioPairCount
        counts.discontinuousPairs = raw.discontinuousPairCount
        rejections = counts
    }
}

/// Owned fixed-size results. The complete export retains query bounds, larger
/// dependency timing, input provenance and coverage. It never retains input
/// buffers. Encodable export is not an untrusted archive-import API.
public struct JitterAnalysisResult: Sendable, Hashable, Encodable {
    public let schemaVersion: Int
    public let profile: ProfileIdentity
    public let applicability: JitterApplicability
    public let dependencyTiming: AnalysisTiming
    public let query: JitterQueryRange
    /// Exact integer query identity for the incremental sample-clock API.
    /// Arbitrary Double-bound batch queries leave this nil.
    public let sampleAlignedQuery: SourceInterval?
    public let inputProvenance: JitterInputProvenance
    public let coverage: JitterCoverage
    public let local: JitterEstimate
    public let absolute: JitterEstimate
    public let rap: JitterEstimate
    public let ppq5: JitterEstimate
    public let ddp: JitterEstimate

    /// Approximate absolute display coordinate; exact source identity remains the
    /// integer source interval plus the relative query. Supplied anchors survive.
    public var queryCenterSourceSeconds: Double {
        let center =
            sampleAlignedQuery.map {
                Double($0.startSample - dependencyTiming.source.startSample) / $0.sampleRate
                    + $0.durationSeconds / 2
            } ?? query.centerSeconds
        return
            (dependencyTiming.sourceStartSeconds
            ?? Double(dependencyTiming.source.startSample) / dependencyTiming.source.sampleRate)
            + center
    }

    public func estimate(_ variant: JitterVariant) -> JitterEstimate {
        switch variant {
        case .local: local
        case .absolute: absolute
        case .rap: rap
        case .ppq5: ppq5
        case .ddp: ddp
        }
    }

    /// Scalar interoperability allocates warning/serialization storage. Its timing
    /// covers the full dependency, like other context-dependent estimators. Keep
    /// this typed report when persisting query/coverage or plotting query center.
    public func measurementResult(
        _ variant: JitterVariant, unit requestedUnit: MeasurementUnit? = nil
    ) throws -> MeasurementResult {
        let estimate = estimate(variant)
        guard estimate.status != .notRequested else { throw JitterError.measurementNotRequested }
        let unit = requestedUnit ?? variant.unit
        guard variant.measurementKind.accepts(unit) else { throw ContractError.invalidUnit }
        let outcome: MeasurementOutcome
        if let value = estimate.value {
            var warnings: [MeasurementWarning] = []
            if applicability == .exploratoryRolling { warnings.append(.exploratoryApplicability) }
            if coverage.durationCoverage < 1
                || coverage.acceptedPeriodCount < coverage.selectedPeriodCount
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
        raw: JitterKernelResult, configuration: JitterConfiguration, identity: ProfileIdentity,
        timing: AnalysisTiming, query: JitterQueryRange, provenance: JitterInputProvenance,
        inputCount: Int, sourceRejections: JitterRejectionCounts,
        sourceUnavailability: UnavailabilityReason?, requested: JitterRequestedVariants,
        sampleAlignedQuery: SourceInterval? = nil
    ) {
        schemaVersion = 1
        profile = identity
        applicability = configuration.applicability
        dependencyTiming = timing
        self.query = query
        self.sampleAlignedQuery = sampleAlignedQuery
        inputProvenance = provenance
        coverage = JitterCoverage(
            raw: raw, inputCount: inputCount,
            duration: sampleAlignedQuery?.durationSeconds ?? query.durationSeconds,
            sourceRejections: sourceRejections)
        func unavailable(_ variant: JitterVariant) -> UnavailabilityReason {
            if timing.includedSampleCount == 0 && timing.source.sampleCount > 0 { return .excluded }
            if let sourceUnavailability, raw.boundedReliablePeriodCount == 0 {
                return sourceUnavailability
            }
            if raw.selectedPeriodCount > 0 && raw.unreliablePeriodCount == raw.selectedPeriodCount {
                if sourceRejections.excluded == raw.selectedPeriodCount { return .excluded }
                if sourceRejections.invalidInput > 0 { return .invalidInput }
                if sourceRejections.missingAcquisition > 0 { return .missingAcquisition }
                if sourceRejections.silence == raw.selectedPeriodCount { return .silence }
                if sourceRejections.discontinuity > 0 { return .discontinuity }
                return .lowConfidence
            }
            if raw.boundedReliablePeriodCount < variant.minimumConsecutivePeriodCount {
                if raw.belowMinimumCount + raw.aboveMaximumCount > 0 { return .unsupportedRange }
                return .insufficientData
            }
            if raw.discontinuousPairCount > 0 { return .discontinuity }
            if raw.rejectedRatioPairCount > 0 { return .lowConfidence }
            return .insufficientData
        }
        func estimate(_ variant: JitterVariant) -> JitterEstimate {
            let value = timing.includedSampleCount == 0 ? nil : raw.value(variant)
            return JitterEstimate(
                variant: variant, value: value,
                unavailable: value == nil ? unavailable(variant) : nil,
                requested: requested.contains(.init(variant)))
        }
        local = estimate(.local)
        absolute = estimate(.absolute)
        rap = estimate(.rap)
        ppq5 = estimate(.ppq5)
        ddp = estimate(.ddp)
    }
}

public struct JitterExecutionStatistics: Sendable, Hashable {
    public let preparedBufferBytes: Int
    public let analyzedQueryCount: UInt64
    public let lastInputPeriodCount: Int
}
