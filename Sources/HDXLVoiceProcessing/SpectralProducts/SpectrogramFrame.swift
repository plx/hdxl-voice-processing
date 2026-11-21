import Foundation

public enum SpectralFrameStatus: Sendable, Hashable, Codable {
    case measured, noEnergy
    case unavailable(UnavailabilityReason)
    public var isMeasured: Bool {
        switch self {
        case .measured, .noEnergy: true
        case .unavailable: false
        }
    }
}

/// Unique coverage uses the union of the full eligible analysis windows, in grid order.
public struct SpectralFrameInfo: Sendable, Hashable, Codable {
    public let epochStartSample: Int64
    public let frameIndex: UInt64
    public let source: SourceInterval
    public let selectionProfile: ProfileIdentity?
    public let status: SpectralFrameStatus
    public let newlyCoveredSamples: Int64
    public let weight: Int64

    func validate(layout: SpectrogramLayout) throws {
        let start = try layout.framing.frameStartSample(
            ordinal: frameIndex, epochStart: epochStartSample)
        let complete = source.sampleCount == Int64(layout.framing.window.sampleCount)
        guard source.sampleRate == layout.framing.window.sampleRate, start == source.startSample,
            source.sampleCount > 0, source.sampleCount <= Int64(layout.framing.window.sampleCount),
            (0...source.sampleCount).contains(newlyCoveredSamples),
            complete == (status != .unavailable(.insufficientData)),
            status.isMeasured
                ? (newlyCoveredSamples > 0
                    && weight == (layout.weighting == .equalFrames ? 1 : newlyCoveredSamples))
                : (weight == 0 && newlyCoveredSamples == 0)
        else { throw ContractError.invalidCoverage }
    }
}

public struct BorrowedSpectrogramFrame<Sample: BinaryFloatingPoint & Sendable> {
    public let layout: SpectrogramLayout
    public let info: SpectralFrameInfo
    /// Valid only during the synchronous emission. Unavailable rows contain no values.
    public let binPower: UnsafeBufferPointer<Sample>

    public func owned() -> SpectrogramFrame {
        SpectrogramFrame(layout: layout, info: info, binPower: binPower.map(Double.init))
    }
}

/// Standalone array suitable for iteration, JSON-lines export, retention or independent LTAS replay.
public struct SpectrogramFrame: Sendable, Hashable, Codable {
    public let layout: SpectrogramLayout
    public let info: SpectralFrameInfo
    public let binPower: [Double]

    init(layout: SpectrogramLayout, info: SpectralFrameInfo, binPower: [Double]) {
        self.layout = layout
        self.info = info
        self.binPower = binPower
    }

    public func value(at bin: Int, presentation: SpectrumPresentation = .binPower)
        -> MeasurementOutcome
    {
        guard (0..<layout.frequency.count).contains(bin) else {
            return .unavailable(.unsupportedRange)
        }
        if case .unavailable(let reason) = info.status { return .unavailable(reason) }
        return presentation.convert(power: binPower[bin], spacing: layout.frequency.step)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case layout, info, binPower }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let layout = try c.decode(SpectrogramLayout.self, forKey: .layout)
        let info = try c.decode(SpectralFrameInfo.self, forKey: .info)
        let powers = try c.decode([Double].self, forKey: .binPower)
        try info.validate(layout: layout)
        guard powers.count == (info.status.isMeasured ? layout.frequency.count : 0),
            powers.allSatisfy({ $0.isFinite && $0 >= 0 }),
            !info.status.isMeasured || (powers.contains { $0 > 0 }) == (info.status == .measured)
        else { throw ContractError.invalidValue }
        self.init(layout: layout, info: info, binPower: powers)
    }
}

public enum SpectrumPresentationOrigin: Sendable, Hashable, Encodable {
    case frame(SpectralFrameInfo)
    case longTerm(
        timing: AnalysisTiming, selection: ProfileIdentity?, status: SpectralFrameStatus,
        totalWeight: Int64)
}

/// Explicit owned presentation for selected bins. Above-band queries retain their unavailable status.
public struct PresentedSpectrum: Sendable, Hashable, Encodable {
    public let layout: SpectrogramLayout
    public let origin: SpectrumPresentationOrigin
    public let presentation: SpectrumPresentation
    public let unit: MeasurementUnit
    public let firstBin: Int
    public let values: [MeasurementOutcome]

    init(
        layout: SpectrogramLayout, origin: SpectrumPresentationOrigin,
        presentation: SpectrumPresentation, bins: Range<Int>,
        value: (Int) -> MeasurementOutcome
    ) throws {
        guard bins.lowerBound >= 0, bins.count <= FourierConfiguration.maximumLength else {
            throw ContractError.intermediateBudgetExceeded
        }
        if case .decibels(let reference) = presentation, !reference.isFinite || reference <= 0 {
            throw ContractError.invalidConfiguration
        }
        self.layout = layout
        self.origin = origin
        self.presentation = presentation
        self.unit = presentation.unit
        self.firstBin = bins.lowerBound
        self.values = bins.map(value)
    }
}

extension SpectrogramFrame {
    public func presented(_ presentation: SpectrumPresentation, bins: Range<Int>) throws
        -> PresentedSpectrum
    {
        try PresentedSpectrum(
            layout: layout, origin: .frame(info), presentation: presentation, bins: bins
        ) {
            value(at: $0, presentation: presentation)
        }
    }
}

extension LongTermSpectrum {
    public func presented(_ presentation: SpectrumPresentation, bins: Range<Int>) throws
        -> PresentedSpectrum
    {
        try PresentedSpectrum(
            layout: layout,
            origin: .longTerm(
                timing: timing, selection: selectionProfile, status: status,
                totalWeight: totalWeight), presentation: presentation, bins: bins
        ) {
            value(at: $0, presentation: presentation)
        }
    }
}

extension SpectrogramFrame {
    /// Feed a decoded frame through the same borrowed-column pipeline as a live emission.
    public func withBorrowedFrame<Result>(
        _ body: (BorrowedSpectrogramFrame<Double>) throws -> Result
    ) rethrows -> Result {
        try binPower.withUnsafeBufferPointer {
            try body(BorrowedSpectrogramFrame(layout: layout, info: info, binPower: $0))
        }
    }
}
