/// Owned scalar metadata. Kernel scratch and unbounded frame history are not retained.
public enum ScheduledFrameValue: Sendable, Hashable {
    case levels(LevelWindowResult)
    case pitch(raw: YINFrameResult, tracked: YINTrackedFrameResult?)
    case cpps(CPPSFrameResult)
    case hnr(HNRAnalysisResult)
}

public enum ScheduledMetric: String, Sendable, Hashable, Codable {
    case meanSquare, rms, peakAmplitude, crestFactor, levelDBFS, clippingFraction, kWeightedEnergy
    case fundamentalFrequency, trackedFundamentalFrequency, cpp, cpps, harmonicToNoiseRatio
}

/// Owned scalar export retaining population evidence and complete dependency
/// support, independently from the selected metric's native measurement window.
public struct ScheduledMeasurementExport: Sendable, Hashable {
    public let result: MeasurementResult
    public let origin: AnalysisScheduleOrigin
    public let dependencyTiming: AnalysisTiming
    public let dependencyCoverage: AnalysisCoverageCounts
    public let mask: AnalysisMaskProvenance?
    public let frameCenterSecondsFromOrigin: Double
    public let workerBatchingUpperBoundSeconds: Double
}

/// Original acquisition support and analysis continuity are both retained. The
/// native value uses the zero-based continuity clock; `timing` uses acquisition
/// coordinates. Cepstral placement remains separate from dependency support.
public struct ScheduledFrame: Sendable, Hashable {
    public let schedule: ProfileIdentity
    public let origin: AnalysisScheduleOrigin
    public let value: ScheduledFrameValue
    public let timing: AnalysisTiming
    /// Coverage of the complete dependency support in `timing.source`.
    public let coverage: AnalysisCoverageCounts
    /// Nil explicitly means acquired input without speech/phonation annotations.
    public let mask: AnalysisMaskProvenance?
    public let frameCenterSecondsFromOrigin: Double
    /// Additional bounded source tiling, separate from the kernel's reported delay.
    /// This is an upper bound, not measured end-to-end callback or display latency.
    public let workerBatchingUpperBoundSeconds: Double

    public var algorithm: ScheduledAlgorithm {
        switch value {
        case .levels: .levels
        case .pitch: .yin
        case .cpps: .cpps
        case .hnr: .hnr
        }
    }

    public func export(_ metric: ScheduledMetric) throws -> ScheduledMeasurementExport {
        try ScheduledMeasurementExport(
            result: measurementResult(metric), origin: origin,
            dependencyTiming: timing, dependencyCoverage: coverage, mask: mask,
            frameCenterSecondsFromOrigin: frameCenterSecondsFromOrigin,
            workerBatchingUpperBoundSeconds: workerBatchingUpperBoundSeconds)
    }

    /// Scalar-only projection. Use export to retain mask and dependency coverage.
    /// Explicit owned scalar export; warnings/encoding can allocate. This operation
    /// is outside the prepared worker's scratch-reuse guarantee.
    public func measurementResult(_ metric: ScheduledMetric) throws -> MeasurementResult {
        let native: MeasurementResult
        switch (value, metric) {
        case (.levels(let value), .meanSquare):
            native = try value.measurementResult(
                kind: .meanSquare, unit: .normalizedSquaredAmplitude)
        case (.levels(let value), .rms):
            native = try value.measurementResult(kind: .rms, unit: .normalizedAmplitude)
        case (.levels(let value), .peakAmplitude):
            native = try value.measurementResult(kind: .peakAmplitude, unit: .normalizedAmplitude)
        case (.levels(let value), .crestFactor):
            native = try value.measurementResult(kind: .crestFactor, unit: .dimensionless)
        case (.levels(let value), .levelDBFS):
            native = try value.measurementResult(kind: .levelDBFS, unit: .decibelsFullScale)
        case (.levels(let value), .clippingFraction):
            native = try value.measurementResult(kind: .clippingFraction, unit: .fraction)
        case (.levels(let value), .kWeightedEnergy):
            native = try value.measurementResult(
                kind: .kWeightedEnergy, unit: .normalizedSquaredAmplitude)
        case (.pitch(let raw, _), .fundamentalFrequency):
            native = try raw.measurementResult()
        case (.pitch(_, let tracked?), .trackedFundamentalFrequency):
            native = try tracked.measurementResult()
        case (.cpps(let value), .cpp):
            native = try value.rawCPP.measurementResult()
        case (.cpps(let value), .cpps):
            native = try value.measurementResult()
        case (.hnr(let value), .harmonicToNoiseRatio):
            native = try value.measurementResult()
        default: throw AnalysisScheduleError.invalidConfiguration
        }
        return try MeasurementResult(
            measurement: native.measurement, profile: schedule,
            timing: origin.mappedTiming(native.timing), outcome: native.outcome)
    }
}

public struct AnalysisScheduleProcessReport: Sendable, Hashable {
    public let consumedSourceSamples: Int
    public let emittedFrames: Int
    public let isCancelled: Bool
}

/// Counts unique source input once; overlapping frame supports are never summed.
/// Native completion records retain partial-window and unavailable outcomes.
public struct AnalysisScheduleCompletion: Sendable, Hashable {
    public let schedule: ProfileIdentity
    public let origin: AnalysisScheduleOrigin
    public let observedSource: SourceInterval
    public let coverage: AnalysisCoverageCounts
    public let mask: AnalysisMaskProvenance?
    public let emittedFrames: UInt64
    public let levels: LevelCompletion?
    public let pitch: YINCompletion?
    public let cpps: CPPSCompletion?
    public let hnrInterval: HNRCompletion?
    public let hnrStream: HNRStreamingCompletion?
    public let isCancelled: Bool
}

/// A reset discards pending analysis, not the fact that its input was acquired.
/// Missing acquisition is separate; nil means its extent is unknown/unreported.
public struct AnalysisScheduleReset: Sendable, Hashable {
    public let previousOrigin: AnalysisScheduleOrigin
    public let nextOrigin: AnalysisScheduleOrigin
    public let observedSource: SourceInterval
    public let dispatchedSourceSamples: Int64
    public let pendingSourceSamplesDiscarded: Int
    public let missingSource: SourceInterval?
    public let reason: ResetReason
}
