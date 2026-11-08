import Foundation

public enum PulseStreamState: String, Sendable, Hashable, Codable {
    case accepting, finished, cancelled, failed
}

/// Bounded chunk collector for a declared complete interval or independent live
/// block. It emits once at finish, after every declared sample has arrived. F0 is
/// supplied during preparation; this object does not estimate or predict pitch.
/// Independent resets never carry a pulse or period into the next block.
public final class PreparedPulseStream<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: PulseConfiguration
    public let maximumSampleCount: Int
    public let maximumF0FrameCount: Int
    public private(set) var state: PulseStreamState = .accepting
    public private(set) var timing: AnalysisTiming
    public private(set) var contour: PulseF0Contour
    public private(set) var consumedSampleCount = 0
    public var nextInputSample: Int64 { timing.source.startSample + Int64(consumedSampleCount) }
    public var preparedBufferBytes: Int {
        worker.executionStatistics.preparedBufferBytes + samples.count * MemoryLayout<Sample>.stride
    }

    private let worker: PreparedPulseTracker<Sample>
    private let samples: UnsafeMutableBufferPointer<Sample>
    private var exclusions: [Range<Int>]
    private var completion: PulseAnalysisResult?
    private var busy = false

    public init(
        configuration: PulseConfiguration, contour: PulseF0Contour, timing: AnalysisTiming,
        maximumTrackingAttempts: Int, excludedSampleRanges: [Range<Int>] = []
    ) throws {
        try Self.validate(configuration, contour, timing, excludedSampleRanges)
        self.configuration = configuration
        self.contour = contour
        self.timing = timing
        self.exclusions = excludedSampleRanges
        maximumSampleCount = contour.sampleCount
        maximumF0FrameCount = contour.frequenciesHz.count
        worker = try PreparedPulseTracker(
            configuration: configuration, maximumSampleCount: contour.sampleCount,
            maximumF0FrameCount: contour.frequenciesHz.count,
            maximumTrackingAttempts: maximumTrackingAttempts)
        samples = .allocate(capacity: contour.sampleCount)
        samples.initialize(repeating: 0)
    }

    deinit {
        samples.deinitialize()
        samples.deallocate()
    }

    /// Validation is atomic: an invalid/gapped/overlapping chunk consumes nothing.
    /// Source indices remain integers even near Int64.max. Empty chunks are valid
    /// only at the exact next position, with the same epoch and sample rate.
    public func append(_ input: UnsafeBufferPointer<Sample>, interval: SourceInterval) throws {
        guard !busy else { throw PulseError.reentrantCall }
        guard state == .accepting else { throw PulseError.invalidState }
        guard interval.epoch == timing.source.epoch,
            interval.sampleRate == timing.source.sampleRate,
            interval.startSample == nextInputSample, interval.sampleCount == Int64(input.count),
            input.count <= contour.sampleCount - consumedSampleCount
        else { throw PulseError.unexpectedContext }
        guard input.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw PulseError.invalidInput
        }
        for i in input.indices { samples[consumedSampleCount + i] = input[i] }
        consumedSampleCount += input.count
    }

    /// An incomplete finish consumes nothing and remains resumable. Successful
    /// finish is idempotent and never redelivers the callback. Analysis or callback
    /// failure enters failed; reset is required before accepting more input.
    @discardableResult public func finish(emit: (BorrowedPulseOutput) throws -> Void) throws
        -> PulseAnalysisResult
    {
        guard !busy else { throw PulseError.reentrantCall }
        if state == .finished, let completion { return completion }
        guard state == .accepting else { throw PulseError.invalidState }
        guard consumedSampleCount == contour.sampleCount else { throw PulseError.insufficientData }
        busy = true
        defer { busy = false }
        do {
            try worker.analyze(
                UnsafeBufferPointer(start: samples.baseAddress, count: consumedSampleCount),
                contour: contour, timing: timing, excludedSampleRanges: exclusions
            ) { output in
                try emit(output)
                completion = output.result
            }
            guard let completion else { throw PulseError.numericalFailure }
            state = .finished
            return completion
        } catch {
            completion = nil
            state = .failed
            throw error
        }
    }

    /// Cancellation emits no partial sequence. No callback can cancel or reset
    /// while a borrowed result is in use; those calls fail as reentrant.
    public func cancel() throws {
        guard !busy else { throw PulseError.reentrantCall }
        if state == .cancelled { return }
        guard state == .accepting else { throw PulseError.invalidState }
        state = .cancelled
        consumedSampleCount = 0
    }

    /// A new contour/timing pair must fit the original prepared capacities.
    /// Validate before mutation; no samples, attempt history, or run IDs survive.
    public func reset(
        contour: PulseF0Contour, timing: AnalysisTiming, excludedSampleRanges: [Range<Int>] = []
    ) throws {
        guard !busy else { throw PulseError.reentrantCall }
        guard contour.sampleCount <= maximumSampleCount,
            contour.frequenciesHz.count <= maximumF0FrameCount
        else {
            throw PulseError.capacityExceeded
        }
        try Self.validate(configuration, contour, timing, excludedSampleRanges)
        try worker.reset()
        self.contour = contour
        self.timing = timing
        exclusions = excludedSampleRanges
        consumedSampleCount = 0
        completion = nil
        state = .accepting
    }

    private static func validate(
        _ configuration: PulseConfiguration, _ contour: PulseF0Contour,
        _ timing: AnalysisTiming, _ exclusions: [Range<Int>]
    ) throws {
        guard contour.sampleRate == configuration.sampleRate,
            contour.ceilingHz <= configuration.pitchCeilingHz,
            contour.frequenciesHz.allSatisfy({ $0 == 0 || $0 >= configuration.pitchFloorHz }),
            timing.source.sampleRate == Double(configuration.sampleRate),
            timing.source.sampleCount == Int64(contour.sampleCount)
        else { throw PulseError.unexpectedContext }
        var previousEnd = 0
        var excludedCount = 0
        for range in exclusions {
            guard !range.isEmpty, range.lowerBound >= previousEnd,
                range.upperBound <= contour.sampleCount
            else {
                throw PulseError.unexpectedContext
            }
            previousEnd = range.upperBound
            excludedCount += range.count
        }
        guard timing.includedSampleCount == Int64(contour.sampleCount - excludedCount) else {
            throw PulseError.unexpectedContext
        }
    }
}
