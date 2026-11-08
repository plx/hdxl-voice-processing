import Foundation

public struct HNRUnavailableFrame: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let frameIndex: UInt64
    public let timing: AnalysisTiming
    public let centerSourceSeconds: Double
    public let reason: UnavailabilityReason

    public func measurementResult() throws -> MeasurementResult {
        try MeasurementResult(
            measurement: MeasurementDescriptor(
                kind: .harmonicToNoiseRatio, unit: .decibelsRatio,
                algorithm: profile.identifier), profile: profile, timing: timing,
            outcome: .unavailable(reason))
    }
}

public enum BorrowedHNRAnalysisOutput {
    case frame(BorrowedHNROutput)
    case unavailable(HNRUnavailableFrame)

    /// Owned scalar metadata; candidate and correlation buffers are not copied.
    public var result: HNRAnalysisResult {
        switch self {
        case .frame(let output): .frame(output.result)
        case .unavailable(let output): .unavailable(output)
        }
    }
}

public enum HNRAnalysisResult: Sendable, Hashable {
    case frame(HNRFrameResult)
    case unavailable(HNRUnavailableFrame)

    public var dependencyTiming: AnalysisTiming {
        switch self {
        case .frame(let frame): frame.dependencyTiming
        case .unavailable(let frame): frame.timing
        }
    }

    /// Zero-based continuity coordinates when used by the shared schedule.
    public var centerSourceSeconds: Double {
        switch self {
        case .frame(let frame): frame.centerSourceSeconds
        case .unavailable(let frame): frame.centerSourceSeconds
        }
    }

    public func measurementResult() throws -> MeasurementResult {
        switch self {
        case .frame(let frame): try frame.measurementResult()
        case .unavailable(let frame): try frame.measurementResult()
        }
    }
}

/// Whole-interval accounting. Reference presentation and uncapped finite means
/// have explicit, different denominators. Numerical unity is never silently omitted
/// from an ordinary full-population mean.
public struct HNRCompletion: Sendable, Hashable {
    public let profile: ProfileIdentity
    public let source: SourceInterval
    public let completeGridFrameCount: Int
    public let emittedSlotCount: Int
    public let availableFrameCount: Int
    public let unavailableFrameCount: Int
    public let finiteDecibelFrameCount: Int
    public let reportingLimitFrameCount: Int
    public let numericalZeroNoiseFrameCount: Int
    public let lowConfidenceFrameCount: Int
    /// Selected observations whose acquired local frame contains clipping.
    public let clippedFrameCount: Int
    public let observedSampleCount: Int64
    public let finiteUncappedMeanDB: Double?
    public let referencePresentationMeanDB: Double?
    public let isCancelled: Bool
    public let unavailability: UnavailabilityReason?

    public var observedCoverage: Double {
        source.sampleCount == 0 ? 0 : Double(observedSampleCount) / Double(source.sampleCount)
    }
    public var frameCoverage: Double {
        emittedSlotCount == 0 ? 0 : Double(availableFrameCount) / Double(emittedSlotCount)
    }
    /// Mean of available observations when every selected observation is finite
    /// and analysis was not cancelled. Missing frames remain in coverage counts.
    public var meanDB: Double? {
        !isCancelled && numericalZeroNoiseFrameCount == 0 ? finiteUncappedMeanDB : nil
    }
}

/// A complete contiguous interval is required before analysis: global relative
/// silence depends on its last sample. Append never concatenates across a gap.
/// All storage is prepared once; emitted frames borrow the kernel's bounded scratch.
public final class PreparedIntervalHNR<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: HNRConfiguration
    public let layout: HNRIntervalLayout
    public private(set) var timing: AnalysisTiming
    public private(set) var receivedSampleCount = 0
    public var identity: ProfileIdentity { worker.identity }
    public var source: SourceInterval { timing.source }
    public var preparedBufferBytes: Int {
        samples.count * MemoryLayout<Sample>.stride + worker.executionStatistics.preparedBufferBytes
    }
    private let samples: UnsafeMutableBufferPointer<Sample>
    private let worker: PreparedHNR<Sample>
    private var busy = false
    private enum State { case prepared, finished, cancelled, failed }
    private var state = State.prepared
    private var completion: HNRCompletion?

    public init(configuration: HNRConfiguration, timing: AnalysisTiming) throws {
        guard timing.source.sampleRate == Double(configuration.sampleRate),
            timing.includedSampleCount == timing.source.sampleCount,
            timing.source.sampleCount <= Int64(HNRConfiguration.maximumIntervalSampleCount)
        else { throw HNRError.unexpectedContext }
        self.configuration = configuration
        self.layout = try HNRIntervalLayout(
            configuration: configuration, sampleCount: Int(timing.source.sampleCount))
        self.timing = timing
        self.worker = try PreparedHNR(configuration)
        samples = .allocate(capacity: layout.sampleCount)
        samples.initialize(repeating: 0)
    }
    deinit {
        samples.deinitialize()
        samples.deallocate()
    }

    public func append(_ input: UnsafeBufferPointer<Sample>, interval: SourceInterval) throws {
        guard !busy else { throw HNRError.reentrantCall }
        guard state == .prepared else { throw HNRError.invalidState }
        guard interval.epoch == source.epoch, interval.sampleRate == source.sampleRate,
            interval.startSample == source.startSample + Int64(receivedSampleCount),
            interval.sampleCount == Int64(input.count),
            input.count <= samples.count - receivedSampleCount
        else { throw HNRError.unexpectedContext }
        for value in input where !value.isFinite { throw HNRError.invalidInput }
        for i in input.indices { samples[receivedSampleCount + i] = input[i] }
        receivedSampleCount += input.count
    }

    /// Repeated finish returns the same completion without repeating callbacks.
    /// An incomplete finish is recoverable by appending the remaining contiguous PCM.
    @discardableResult public func finish(emit: (BorrowedHNRAnalysisOutput) -> Void) throws
        -> HNRCompletion
    {
        guard !busy else { throw HNRError.reentrantCall }
        if let completion { return completion }
        guard state == .prepared else { throw HNRError.invalidState }
        guard receivedSampleCount == samples.count else { throw HNRError.insufficientData }
        busy = true
        defer { busy = false }
        var emitted = 0
        var available = 0
        var finite = 0
        var limits = 0
        var zeroNoise = 0
        var lowConfidence = 0
        var clipped = 0
        var observed: Int64 = 0
        var observedEnd = 0
        var finiteSum = HNRSum()
        var referenceSum = HNRSum()
        var firstUnavailable: UnavailabilityReason?
        do {
            if layout.frameCount == 0 {
                emitted = 1
                firstUnavailable = .insufficientData
                let shortTiming = try AnalysisTiming(
                    source: source, includedSampleCount: source.sampleCount,
                    sourceStartSeconds: timing.sourceStartSeconds,
                    hostStartNanoseconds: timing.hostStartNanoseconds,
                    completedHostNanoseconds: timing.completedHostNanoseconds,
                    effectiveDelaySeconds: max(
                        timing.effectiveDelaySeconds, source.durationSeconds / 2))
                emit(
                    .unavailable(
                        HNRUnavailableFrame(
                            profile: identity, frameIndex: 0, timing: shortTiming,
                            centerSourceSeconds: shortTiming.displayTimeSeconds,
                            reason: .insufficientData)))
            } else {
                let input = UnsafeBufferPointer(samples)
                let reference = try HNRNormalization(
                    input, timing: timing, definition: .wholeInterval)
                for index in 0..<layout.frameCount {
                    if state == .cancelled { break }
                    let frame = try layout.frame(at: index)
                    try worker.analyze(
                        UnsafeBufferPointer(rebasing: input[frame.support]), layout: frame,
                        normalization: reference
                    ) { output in
                        emitted += 1
                        if let estimate = output.result.selectedObservation {
                            available += 1
                            referenceSum.add(estimate.referenceReportingDecibels)
                            if let db = estimate.finiteDecibels {
                                finite += 1
                                finiteSum.add(db)
                            }
                            if estimate.status != .finite { limits += 1 }
                            if estimate.status == .numericalZeroNoise { zeroNoise += 1 }
                            if estimate.periodicity < 0.5 || estimate.status != .finite {
                                lowConfidence += 1
                            }
                            if output.result.hasClipping { clipped += 1 }
                            // Frames are monotone; count their acquired support union once.
                            observed += Int64(
                                max(
                                    0,
                                    frame.support.upperBound
                                        - max(observedEnd, frame.support.lowerBound)))
                            observedEnd = max(observedEnd, frame.support.upperBound)
                        } else if firstUnavailable == nil {
                            firstUnavailable = output.result.unavailability
                        }
                        emit(.frame(output))
                    }
                }
            }
        } catch {
            if state != .cancelled { state = .failed }
            throw error
        }
        let cancelled = state == .cancelled
        let reason: UnavailabilityReason? =
            cancelled
            ? .cancelled
            : (zeroNoise > 0
                ? .unsupportedRange
                : (available == 0 ? firstUnavailable ?? .insufficientData : nil))
        let result = HNRCompletion(
            profile: identity, source: source, completeGridFrameCount: layout.frameCount,
            emittedSlotCount: emitted, availableFrameCount: available,
            unavailableFrameCount: emitted - available,
            finiteDecibelFrameCount: finite, reportingLimitFrameCount: limits,
            numericalZeroNoiseFrameCount: zeroNoise, lowConfidenceFrameCount: lowConfidence,
            clippedFrameCount: clipped, observedSampleCount: observed,
            finiteUncappedMeanDB: finite == 0 ? nil : finiteSum.value / Double(finite),
            referencePresentationMeanDB: available == 0
                ? nil : referenceSum.value / Double(available),
            isCancelled: cancelled, unavailability: reason)
        completion = result
        if !cancelled { state = .finished }
        return result
    }

    /// A new independent interval with the same capacity; all old samples must be
    /// replaced before another finish. Reset never joins the old and new timelines.
    public func reset(timing: AnalysisTiming) throws {
        guard !busy else { throw HNRError.reentrantCall }
        guard timing.source.sampleRate == source.sampleRate,
            timing.source.sampleCount == source.sampleCount,
            timing.includedSampleCount == timing.source.sampleCount
        else { throw HNRError.unexpectedContext }
        self.timing = timing
        receivedSampleCount = 0
        completion = nil
        state = .prepared
    }

    /// Safe inside emit: the current borrow remains valid until the callback exits.
    public func cancel() {
        if state == .prepared { state = .cancelled }
    }
}
