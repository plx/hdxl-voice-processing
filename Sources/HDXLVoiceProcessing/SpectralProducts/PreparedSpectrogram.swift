import Foundation

/// Single-owner worker. All scratch is prepared; the worker retains no emitted columns.
/// Each epoch or distinct selection needs its own worker.
public final class PreparedSpectrogram<Sample: BinaryFloatingPoint & Sendable> {
    public let layout: SpectrogramLayout
    public let epochStartSample: Int64
    public let selectionProfile: ProfileIdentity?
    private let selection: MaskTimeline?
    private let framer: PCMFramer<Sample>
    private let window: PreparedWindow<Sample>
    private let transform: PreparedFourierTransform<Sample>
    private let spectrum: PreparedSpectrum<Sample>
    private var windowed: [Sample]
    private var bins: [FourierBin<Sample>]
    private var power: [Sample]
    private var lastMeasuredEnd: Int64
    private let diagnostics: WorkerDiagnostics

    public init(
        layout: SpectrogramLayout, epoch: StreamEpoch, startSample: Int64 = 0,
        selection: MaskTimeline? = nil, diagnosticMode: RuntimeDiagnosticMode = .disabled
    ) throws {
        let diagnostics = WorkerDiagnostics(mode: diagnosticMode.facadeMode)
        if let selection {
            // An opaque upstream filter/resampler identity cannot map the original samples
            // that influenced each analysis window. Same-grid channel selection is pointwise.
            guard layout.conditioning == nil else { throw ContractError.invalidConfiguration }
            guard selection.plan.source.epoch == epoch,
                selection.plan.source.sampleRate == layout.framing.window.sampleRate
            else {
                throw MaskError.unexpectedInterval
            }
            selectionProfile = try selection.plan.spectralSelectionIdentity()
        } else {
            selectionProfile = nil
        }
        self.selection = selection
        self.diagnostics = diagnostics
        self.layout = layout
        epochStartSample = startSample
        lastMeasuredEnd = startSample
        framer = try PCMFramer(
            configuration: layout.framing, epoch: epoch, startSample: startSample,
            diagnostics: diagnostics)
        window = framer.preparedWindow!
        transform = try PreparedFourierTransform(
            layout.spectrum.transform, diagnostics: diagnostics)
        spectrum = try PreparedSpectrum(layout.spectrum)
        windowed = .init(repeating: 0, count: layout.framing.window.sampleCount)
        bins = .init(repeating: FourierBin(real: 0), count: layout.spectrum.transform.realBinCount)
        power = .init(repeating: 0, count: bins.count)
    }

    @discardableResult
    public func process(
        _ samples: UnsafeBufferPointer<Sample>, interval: SourceInterval,
        emit: (BorrowedSpectrogramFrame<Sample>) -> Void
    ) throws -> FramingProcessReport {
        try framer.process(samples, interval: interval) {
            self.analyze($0, support: $1, emit: emit)
        }
    }

    @discardableResult
    public func finish(emit: (BorrowedSpectrogramFrame<Sample>) -> Void) throws -> FramingCompletion
    {
        try framer.finish { self.analyze($0, support: $1, emit: emit) }
    }

    private func analyze(
        _ samples: UnsafeBufferPointer<Sample>, support: PCMFrameSupport,
        emit: (BorrowedSpectrogramFrame<Sample>) -> Void
    ) {
        let source = support.source
        var metadata = DiagnosticMetadata()
        metadata.profileToken = 4101
        metadata.frameSequence = support.frameIndex
        metadata.sampleCount = UInt32(clamping: samples.count)
        let status: SpectralFrameStatus = diagnostics.withFrame(metadata, stage: .spectrogram) {
            if let reason = support.unavailability { return .unavailable(reason) }
            do {
                if let selection {
                    guard source.startSample >= selection.plan.source.startSample,
                        source.endSample <= selection.plan.source.endSample
                    else { return .unavailable(.excluded) }
                    guard try selection.eligibleRegion(containing: source) != nil else {
                        return .unavailable(.missingAcquisition)
                    }
                    guard try selection.selectedRegion(containing: source) != nil else {
                        return .unavailable(.excluded)
                    }
                }
                _ = try windowed.withUnsafeMutableBufferPointer {
                    try window.write(samples, into: $0)
                }
                try windowed.withUnsafeBufferPointer { input in
                    _ = try bins.withUnsafeMutableBufferPointer {
                        try transform.forwardReal(input, into: $0)
                    }
                }
                try bins.withUnsafeBufferPointer { input in
                    try power.withUnsafeMutableBufferPointer {
                        try spectrum.writePower(input, into: $0)
                    }
                }
                return power.withUnsafeBufferPointer { full in
                    let supported = UnsafeBufferPointer(
                        rebasing: full.prefix(layout.frequency.count))
                    return bins.withUnsafeBufferPointer { transformed in
                        supported.withSpectralScalars(
                            doubles: { values in
                                transformed.withMemoryRebound(to: FourierBin<Double>.self) {
                                    Self.classify(values, transformed: $0)
                                }
                            },
                            floats: { values in
                                transformed.withMemoryRebound(to: FourierBin<Float>.self) {
                                    Self.classify(values, transformed: $0)
                                }
                            })
                    }
                }
            } catch {
                return .unavailable(.analysisFailure)
            }
        }
        let additional =
            status.isMeasured ? source.endSample - max(lastMeasuredEnd, source.startSample) : 0
        if status.isMeasured { lastMeasuredEnd = source.endSample }
        let info = SpectralFrameInfo(
            epochStartSample: epochStartSample, frameIndex: support.frameIndex,
            source: source, selectionProfile: selectionProfile, status: status,
            newlyCoveredSamples: additional,
            weight: status.isMeasured ? (layout.weighting == .equalFrames ? 1 : additional) : 0)
        power.withUnsafeBufferPointer {
            let values = UnsafeBufferPointer(
                start: $0.baseAddress, count: status.isMeasured ? layout.frequency.count : 0)
            emit(BorrowedSpectrogramFrame(layout: layout, info: info, binPower: values))
        }
    }

    private static func classify<Value>(
        _ powers: UnsafeBufferPointer<Value>, transformed: UnsafeBufferPointer<FourierBin<Value>>
    ) -> SpectralFrameStatus {
        var hasEnergy = false
        for index in powers.indices {
            if powers[index] > 0 {
                hasEnergy = true
            } else if transformed[index].real != 0 || transformed[index].imaginary != 0 {
                // A finite, nonzero coefficient can square to zero in the selected precision.
                return .unavailable(.analysisFailure)
            }
        }
        return hasEnergy ? .measured : .noEnergy
    }

}
