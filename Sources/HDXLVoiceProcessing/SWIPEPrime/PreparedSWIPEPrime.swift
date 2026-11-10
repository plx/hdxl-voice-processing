import Foundation

/// Synchronous single-owner frame estimator. Prepare on an analysis worker, not
/// a capture callback. Valid calls reuse bounded storage; no PCM is retained.
public final class PreparedSWIPEPrime<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: SWIPEPrimeConfiguration
    public let identity: ProfileIdentity
    public let layout: SWIPEPrimeLayout
    private let kernels: SWIPEPrimeBuffer<Double>
    private let samples: SWIPEPrimeBuffer<Double>
    private let strengths: SWIPEPrimeBuffer<Double?>
    private let windows: [SWIPEPrimeWindowStorage]
    private let windowViews: [BorrowedSWIPEPrimeWindow]
    private let lowerWindowIndices: [Int]
    private let upperWindowIndices: [Int]
    private let diagnostics: WorkerDiagnostics
    private var busy = false
    private var analyzedFrames: UInt64 = 0

    public var executionStatistics: SWIPEPrimeExecutionStatistics {
        let layoutBytes =
            (layout.candidateFrequenciesHz.count + layout.erbFrequenciesHz.count)
            * MemoryLayout<Double>.stride
            + layout.windowLengths.count * MemoryLayout<Int>.stride
            + layout.candidateWindows.count * MemoryLayout<SWIPEPrimeWindowMixture>.stride
        return SWIPEPrimeExecutionStatistics(
            preparedBufferBytes: kernels.bytes + samples.bytes + strengths.bytes + layoutBytes
                + windows.reduce(0) { $0 + $1.preparedBytes }
                + windowViews.count * MemoryLayout<BorrowedSWIPEPrimeWindow>.stride
                + (lowerWindowIndices.count + upperWindowIndices.count) * MemoryLayout<Int>.stride,
            windowCount: windows.count, candidateCount: layout.candidateFrequenciesHz.count,
            erbBinCount: layout.erbFrequenciesHz.count, analyzedFrameCount: analyzedFrames)
    }

    public convenience init(_ configuration: SWIPEPrimeConfiguration) throws {
        try self.init(configuration, diagnostics: WorkerDiagnostics())
    }
    package init(_ configuration: SWIPEPrimeConfiguration, diagnostics: WorkerDiagnostics) throws {
        guard
            (Sample.self == Float.self && configuration.inputPrecision == .float32)
                || (Sample.self == Double.self && configuration.inputPrecision == .float64)
        else { throw SWIPEPrimeError.precisionMismatch }
        let layout = SWIPEPrimeLayout(configuration: configuration)
        self.configuration = configuration
        self.identity = try configuration.identity()
        self.layout = layout
        self.diagnostics = diagnostics
        kernels = try SWIPEPrimeNumerics.prepareKernels(layout: layout)
        samples = SWIPEPrimeBuffer(count: layout.requiredSampleCount, repeating: 0)
        strengths = SWIPEPrimeBuffer(count: layout.candidateFrequenciesHz.count, repeating: nil)
        let windows = try layout.windowLengths.map {
            try SWIPEPrimeWindowStorage(
                length: $0, layout: layout, sampleRate: configuration.sampleRate,
                diagnostics: diagnostics)
        }
        self.windows = windows
        self.windowViews = windows.map(\.borrowed)
        self.lowerWindowIndices = layout.candidateWindows.map { mixture in
            layout.windowLengths.firstIndex(of: mixture.lowerLength)!
        }
        self.upperWindowIndices = layout.candidateWindows.map { mixture in
            mixture.upperWeight == 0
                ? -1 : layout.windowLengths.firstIndex(of: mixture.upperLength)!
        }
    }

    /// Timing describes exactly the acquired mono samples. No padding supplies
    /// observations. Invalid input is rejected before touching previous results.
    public func analyze(
        _ input: UnsafeBufferPointer<Sample>, timing: AnalysisTiming, frameIndex: UInt64 = 0,
        emit: (BorrowedSWIPEPrimeOutput) -> Void
    ) throws {
        guard !busy else { throw SWIPEPrimeError.reentrantCall }
        guard input.count <= configuration.requiredSampleCount else {
            throw SWIPEPrimeError.invalidBufferSize
        }
        guard timing.source.sampleCount == Int64(input.count),
            timing.source.sampleRate == Double(configuration.sampleRate),
            timing.includedSampleCount == timing.source.sampleCount
        else { throw SWIPEPrimeError.unexpectedContext }
        for value in input where !value.isFinite { throw SWIPEPrimeError.invalidInput }
        let resolvedTiming = try AnalysisTiming(
            source: timing.source, includedSampleCount: timing.includedSampleCount,
            sourceStartSeconds: timing.sourceStartSeconds,
            hostStartNanoseconds: timing.hostStartNanoseconds,
            completedHostNanoseconds: timing.completedHostNanoseconds,
            effectiveDelaySeconds: max(
                timing.effectiveDelaySeconds, configuration.algorithmicDelaySeconds))
        busy = true
        defer { busy = false }
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 44
        metadata.frameSequence = frameIndex
        metadata.sampleCount = UInt32(input.count)
        metadata.validity = input.count == configuration.requiredSampleCount ? .available : .warmup
        let summary = try diagnostics.withFrame(metadata) {
            try diagnostics.withInterval(.pitch) { try compute(input) }
        }
        let result = SWIPEPrimeFrameResult(
            profile: identity, frameIndex: frameIndex, timing: resolvedTiming,
            requiredSampleCount: configuration.requiredSampleCount, status: summary.status,
            observation: summary.observation, qualityReason: summary.reason,
            normalizationPeak: summary.peak, rms: summary.rms)
        let full = input.count == configuration.requiredSampleCount
        layout.candidateFrequenciesHz.withUnsafeBufferPointer { frequencies in
            layout.erbFrequenciesHz.withUnsafeBufferPointer { auditory in
                windowViews.withUnsafeBufferPointer { views in
                    emit(
                        BorrowedSWIPEPrimeOutput(
                            result: result,
                            candidateFrequenciesHz: UnsafeBufferPointer(
                                start: frequencies.baseAddress, count: full ? frequencies.count : 0),
                            erbFrequenciesHz: UnsafeBufferPointer(
                                start: auditory.baseAddress, count: full ? auditory.count : 0),
                            candidateStrengths: UnsafeBufferPointer(
                                start: strengths.values.baseAddress,
                                count: full ? strengths.values.count : 0),
                            windows: UnsafeBufferPointer(
                                start: views.baseAddress, count: full ? views.count : 0),
                            kernelCoefficients: UnsafeBufferPointer(
                                start: kernels.values.baseAddress,
                                count: full ? kernels.values.count : 0)))
                }
            }
        }
    }

    private struct Summary {
        var status: SWIPEPrimeVoicingStatus
        var observation: SWIPEPrimeObservation?
        var reason: UnavailabilityReason?
        var peak: Double?
        var rms: Double?
    }

    private func compute(_ input: UnsafeBufferPointer<Sample>) throws -> Summary {
        guard input.count == samples.values.count else {
            return Summary(status: .unavailable, reason: .insufficientData)
        }
        var peak = 0.0
        var constant = true
        for value in input {
            peak = max(peak, abs(Double(value)))
            if value != input[0] { constant = false }
        }
        var energy = SWIPEPrimeSum()
        for index in input.indices {
            let value = peak == 0 ? 0 : Double(input[index]) / peak
            samples.values[index] = value
            energy.add(value * value)
        }
        let rms = peak * min(1, sqrt(energy.value / Double(input.count)))
        guard rms.isFinite else { throw SWIPEPrimeError.numericalFailure }
        for window in windows {
            try window.analyze(samples: samples.borrowed, kernels: kernels.borrowed)
        }
        var selected: Int?
        for candidate in strengths.values.indices {
            let mixture = layout.candidateWindows[candidate]
            let lower = windows[lowerWindowIndices[candidate]].strengths.values[candidate]
            var combined = lower
            if mixture.upperWeight > 0 {
                let upper = windows[upperWindowIndices[candidate]].strengths.values[candidate]
                if let lower, let upper {
                    combined = (1 - mixture.upperWeight) * lower + mixture.upperWeight * upper
                } else {
                    combined = nil
                }
            }
            strengths.values[candidate] = combined
            if let combined {
                if selected == nil || combined > strengths.values[selected!]! {
                    selected = candidate
                }
            }
        }
        analyzedFrames &+= 1
        if rms <= configuration.silenceRMSThreshold {
            return Summary(status: .unvoiced, reason: .silence, peak: peak, rms: rms)
        }
        if constant {
            return Summary(status: .unvoiced, reason: .lowConfidence, peak: peak, rms: rms)
        }
        guard let selected else {
            return Summary(status: .unavailable, reason: .analysisFailure, peak: peak, rms: rms)
        }
        let observation = SWIPEPrimeNumerics.refine(
            frequencies: layout.candidateFrequenciesHz, strengths: strengths.borrowed,
            selected: selected, threshold: configuration.strengthThreshold)
        return Summary(
            status: observation.isThresholdQualified ? .voiced : .uncertain,
            observation: observation,
            reason: observation.isThresholdQualified ? nil : .lowConfidence, peak: peak, rms: rms)
    }
}
