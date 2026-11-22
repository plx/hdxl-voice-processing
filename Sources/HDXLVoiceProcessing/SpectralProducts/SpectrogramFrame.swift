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
        switch status {
        case .measured, .noEnergy, .unavailable(.analysisFailure):
            guard complete else { throw ContractError.invalidCoverage }
        case .unavailable(.insufficientData):
            let total = source.endSample - epochStartSample
            guard !complete, layout.framing.partialWindowPolicy == .emitUnavailable,
                try frameIndex == layout.framing.completeFrameCount(observedSampleCount: total)
            else {
                throw ContractError.invalidCoverage
            }
        case .unavailable(.excluded), .unavailable(.missingAcquisition):
            guard complete, selectionProfile != nil else { throw ContractError.invalidCoverage }
        case .unavailable: throw ContractError.invalidValue
        }
        if status.isMeasured && newlyCoveredSamples != source.sampleCount {
            let hop = Int64(layout.framing.hopLength)
            guard newlyCoveredSamples > 0, newlyCoveredSamples.isMultiple(of: hop),
                UInt64(newlyCoveredSamples / hop) <= frameIndex
            else { throw ContractError.invalidCoverage }
        }
        guard layout.conditioning == nil || selectionProfile == nil else {
            throw ContractError.invalidConfiguration
        }
        guard source.sampleRate == layout.framing.window.sampleRate, start == source.startSample,
            source.sampleCount > 0, source.sampleCount <= Int64(layout.framing.window.sampleCount),
            (0...source.sampleCount).contains(newlyCoveredSamples),
            status.isMeasured
                ? (newlyCoveredSamples > 0
                    && weight == (layout.weighting == .equalFrames ? 1 : newlyCoveredSamples))
                : (weight == 0 && newlyCoveredSamples == 0)
        else { throw ContractError.invalidCoverage }
    }
}

extension SpectralFrameInfo {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case epochStartSample, frameIndex, source, selectionProfile, status, newlyCoveredSamples,
            weight
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let source = try c.decode(SourceInterval.self, forKey: .source)
        let origin = try c.decode(Int64.self, forKey: .epochStartSample)
        let status = try c.decode(SpectralFrameStatus.self, forKey: .status)
        let coverage = try c.decode(Int64.self, forKey: .newlyCoveredSamples)
        let weight = try c.decode(Int64.self, forKey: .weight)
        guard (0...source.startSample).contains(origin), source.sampleCount > 0,
            (0...source.sampleCount).contains(coverage),
            status.isMeasured
                ? (coverage > 0 && (weight == 1 || weight == coverage))
                : (coverage == 0 && weight == 0)
        else { throw ContractError.invalidCoverage }
        self.init(
            epochStartSample: origin, frameIndex: try c.decode(UInt64.self, forKey: .frameIndex),
            source: source,
            selectionProfile: try c.decodeIfPresent(
                ProfileIdentity.self, forKey: .selectionProfile),
            status: status, newlyCoveredSamples: coverage, weight: weight)
    }
}

extension UnsafeBufferPointer where Element: BinaryFloatingPoint {
    /// PreparedWindow admits exactly these two sample types. Dispatch once per column so
    /// copying or widening bins can use the concrete scalar implementation.
    func withSpectralScalars<Result>(
        doubles: (UnsafeBufferPointer<Double>) throws -> Result,
        floats: (UnsafeBufferPointer<Float>) throws -> Result
    ) rethrows -> Result {
        if Element.self == Double.self { return try withMemoryRebound(to: Double.self, doubles) }
        precondition(Element.self == Float.self)
        return try withMemoryRebound(to: Float.self, floats)
    }
}

public struct BorrowedSpectrogramFrame<Sample: BinaryFloatingPoint & Sendable> {
    public let layout: SpectrogramLayout
    public let info: SpectralFrameInfo
    /// Valid only during the synchronous emission. Unavailable rows contain no values.
    public let binPower: UnsafeBufferPointer<Sample>

    public func owned() -> SpectrogramFrame {
        let values = binPower.withSpectralScalars(
            doubles: { Array($0) }, floats: { $0.map(Double.init) })
        return SpectrogramFrame(layout: layout, info: info, binPower: values)
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
        try info.validate(layout: layout)
        let expected = info.status.isMeasured ? layout.frequency.count : 0
        var entries = try c.nestedUnkeyedContainer(forKey: .binPower)
        guard entries.count == nil || entries.count == expected else {
            throw ContractError.invalidValue
        }
        var powers: [Double] = []
        powers.reserveCapacity(entries.count ?? 0)
        var hasEnergy = false
        while !entries.isAtEnd {
            guard powers.count < expected else { throw ContractError.invalidValue }
            let value = try entries.decode(Double.self)
            guard value.isFinite, value >= 0,
                layout.framing.window.precision != .float32 || Float(exactly: value) != nil
            else { throw ContractError.invalidValue }
            hasEnergy = hasEnergy || value > 0
            powers.append(value == 0 ? 0 : value)
        }
        guard powers.count == expected, hasEnergy == (info.status == .measured) else {
            throw ContractError.invalidValue
        }
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
