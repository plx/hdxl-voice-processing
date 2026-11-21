import Foundation

/// A snapshot may have measured linear zeros and incomplete time coverage simultaneously.
public struct LongTermSpectrum: Sendable, Hashable, Encodable {
    public let layout: SpectrogramLayout
    public let selectionProfile: ProfileIdentity?
    public let selectionCoverage: SpectralSelectionCoverage?
    public let timing: AnalysisTiming
    public let status: SpectralFrameStatus
    public let measuredFrames: UInt64
    public let unavailableFrames: [UnavailabilityReason: UInt64]
    public let totalWeight: Int64
    public let meanBinPower: [Double]
    public let warnings: [MeasurementWarning]

    public func value(at bin: Int, presentation: SpectrumPresentation = .binPower)
        -> MeasurementOutcome
    {
        guard (0..<layout.frequency.count).contains(bin) else {
            return .unavailable(.unsupportedRange)
        }
        if case .unavailable(let reason) = status { return .unavailable(reason) }
        return presentation.convert(power: meanBinPower[bin], spacing: layout.frequency.step)
    }
}

/// Streaming weighted mean, O(bins) retained storage. Accepts borrowed frames or decoded exports.
/// Unavailable rows may be omitted when replaying the mean; they contribute to reason counts only.
public final class LongTermSpectrumAccumulator {
    public let layout: SpectrogramLayout
    public let epoch: StreamEpoch
    public let startSample: Int64
    public let selectionProfile: ProfileIdentity?
    private let diagnostics: WorkerDiagnostics
    private var means: [Double]
    private var coveredSamples: Int64 = 0
    private var totalWeight: Int64 = 0
    private var measuredFrames: UInt64 = 0
    private var unavailable: [UnavailabilityReason: UInt64] = [:]
    private var previousIndex: UInt64?
    private var previousEnd: Int64
    private var lastMeasuredEnd: Int64
    private var hasEnergy = false
    private var partialTailEnd: Int64?

    public init(
        layout: SpectrogramLayout, epoch: StreamEpoch, startSample: Int64 = 0,
        selectionProfile: ProfileIdentity? = nil, diagnosticMode: RuntimeDiagnosticMode = .disabled
    ) throws {
        guard startSample >= 0 else { throw ContractError.invalidInterval }
        self.layout = layout
        self.epoch = epoch
        self.startSample = startSample
        self.selectionProfile = selectionProfile
        previousEnd = startSample
        lastMeasuredEnd = startSample
        diagnostics = WorkerDiagnostics(mode: diagnosticMode.facadeMode)
        means = .init(repeating: 0, count: layout.frequency.count)
    }

    public func append<Sample>(_ row: BorrowedSpectrogramFrame<Sample>) throws {
        try row.binPower.withSpectralScalars(
            doubles: { try append(layout: row.layout, info: row.info, values: $0) },
            floats: { try append(layout: row.layout, info: row.info, values: $0) })
    }

    public func append(_ row: SpectrogramFrame) throws {
        try row.binPower.withUnsafeBufferPointer {
            try append(layout: row.layout, info: row.info, values: $0)
        }
    }

    private func append<Sample: BinaryFloatingPoint>(
        layout rowLayout: SpectrogramLayout, info: SpectralFrameInfo,
        values: UnsafeBufferPointer<Sample>
    ) throws {
        guard rowLayout == layout, info.selectionProfile == selectionProfile else {
            throw ContractError.invalidFingerprint
        }
        guard partialTailEnd == nil, info.source.epoch == epoch,
            info.epochStartSample == startSample,
            previousIndex.map({ $0 < info.frameIndex }) ?? true
        else { throw FramingError.unexpectedInterval }
        let source = info.source
        guard source.endSample >= previousEnd else { throw FramingError.unexpectedInterval }
        let newlyCovered = source.endSample - max(source.startSample, lastMeasuredEnd)
        if info.status.isMeasured {
            guard info.newlyCoveredSamples == newlyCovered else {
                throw ContractError.invalidCoverage
            }
            // Weights and union counts cannot exceed the representable span of this epoch.
            let (newWeight, overflow) = totalWeight.addingReportingOverflow(info.weight)
            guard !overflow else { throw ContractError.arithmeticOverflow }
            let fraction = Double(info.weight) / Double(newWeight)
            var metadata = DiagnosticMetadata()
            metadata.frameSequence = info.frameIndex
            metadata.sampleCount = UInt32(clamping: values.count)
            diagnostics.withFrame(metadata, stage: .longTermSpectrum) {
                for i in values.indices {
                    let power = Double(values[i])
                    // Pick the nearer endpoint for stability when weights are highly asymmetric.
                    if fraction <= 0.5 {
                        means[i] += (power - means[i]) * fraction
                    } else {
                        means[i] =
                            power + (means[i] - power) * (Double(totalWeight) / Double(newWeight))
                    }
                }
            }
            lastMeasuredEnd = source.endSample
            coveredSamples += newlyCovered
            totalWeight = newWeight
            measuredFrames += 1
            hasEnergy = hasEnergy || info.status == .measured
        } else if case .unavailable(let reason) = info.status {
            unavailable[reason, default: 0] += 1
        }
        if info.status == .unavailable(.insufficientData) { partialTailEnd = source.endSample }
        previousIndex = info.frameIndex
        previousEnd = max(previousEnd, source.endSample)
    }

    /// Supply the entire observed interval to count offsets, gaps and discarded tails in coverage.
    public func snapshot(observedSource: SourceInterval, selection: MaskTimeline? = nil) throws
        -> LongTermSpectrum
    {
        guard observedSource.epoch == epoch, observedSource.startSample == startSample,
            observedSource.sampleRate == layout.framing.window.sampleRate,
            observedSource.endSample >= previousEnd
        else {
            throw FramingError.unexpectedInterval
        }
        guard partialTailEnd == nil || observedSource.endSample == partialTailEnd else {
            throw FramingError.unexpectedInterval
        }
        let timing = try AnalysisTiming(source: observedSource, includedSampleCount: coveredSamples)
        if let selection, try selection.plan.spectralSelectionIdentity() != selectionProfile {
            throw ContractError.invalidFingerprint
        }
        let coverage =
            selectionProfile == nil || selection != nil
            ? try SpectralSelectionCoverage(
                observed: observedSource, measured: coveredSamples, selection: selection) : nil
        let status: SpectralFrameStatus
        if measuredFrames > 0 {
            status = hasEnergy ? .measured : .noEnergy
        } else {
            // Preserve the full histogram alongside the highest-priority reason.
            let reason =
                [
                    UnavailabilityReason.analysisFailure, .invalidInput, .missingAcquisition,
                    .excluded,
                ]
                .first { unavailable[$0] != nil } ?? .insufficientData
            status = .unavailable(reason)
        }
        return LongTermSpectrum(
            layout: layout, selectionProfile: selectionProfile, selectionCoverage: coverage,
            timing: timing, status: status,
            measuredFrames: measuredFrames, unavailableFrames: unavailable,
            totalWeight: totalWeight,
            meanBinPower: measuredFrames == 0 ? [] : means,
            warnings: coveredSamples < observedSource.sampleCount ? [.partialCoverage] : [])
    }
}
