import Foundation

public enum CepstralStage: String, Sendable, Hashable, Codable, CaseIterable {
    case windowed, spectrumReal, spectrumImaginary, powerSpectrum, logPowerSpectrum
    case signedCepstrum, powerCepstrum

    public var xUnit: MeasurementUnit {
        switch self {
        case .windowed, .signedCepstrum, .powerCepstrum: .seconds
        default: .hertz
        }
    }
    public var yUnit: MeasurementUnit {
        switch self {
        case .windowed: .normalizedAmplitude
        case .spectrumReal, .spectrumImaginary: .normalizedAmplitudeSeconds
        case .powerSpectrum: .normalizedSquaredAmplitudeSecondsSquared
        case .logPowerSpectrum: .dimensionless
        case .signedCepstrum: .inverseSeconds
        case .powerCepstrum: .inverseSecondsSquared
        }
    }
    public var scaling: String {
        switch self {
        case .windowed:
            "observed-frame mean removed; unnormalized Gaussian2; trailing transform zeros"
        case .spectrumReal: "real component of dt times the unnormalized negative-exponent DFT"
        case .spectrumImaginary:
            "imaginary component of dt times the unnormalized negative-exponent DFT"
        case .powerSpectrum: "2 * (real squared + imaginary squared), including DC and Nyquist"
        case .logPowerSpectrum:
            "natural logarithm relative to one amplitude-squared second-squared; add 1e-300 except Nyquist"
        case .signedCepstrum: "fs times the 1/N inverse DFT of the even real log-power spectrum"
        case .powerCepstrum: "signed cepstrum squared; linear power, not dB"
        }
    }
    public func step(configuration: PowerCepstrumConfiguration) -> Double {
        xUnit == .seconds ? configuration.quefrencyStepSeconds : configuration.frequencyStepHz
    }
}

/// Frame coordinates are separate from dependency support. Whole-interval filtering
/// can depend on the complete input even when the displayed frame center is near its start.
/// `origin` identifies the separately conditioned continuity interval; offsets are relative
/// to it, preserving integer source identity even at very large absolute sample positions.
public struct CepstralFrameContext: Sendable, Hashable, Codable {
    public let origin: SourceInterval
    public let timing: AnalysisTiming
    public let frameIndex: UInt64
    public let firstAnalysisSampleIndex: Int64
    /// Supplied target-grid samples, excluding transform padding. FIR boundary
    /// extension is labelled separately and never increases original source coverage.
    public let suppliedAnalysisSampleCount: Int
    public let centerSecondsFromOrigin: Double
    public let usesBoundaryExtension: Bool

    public init(
        origin: SourceInterval, timing: AnalysisTiming, frameIndex: UInt64,
        firstAnalysisSampleIndex: Int64, suppliedAnalysisSampleCount: Int,
        centerSecondsFromOrigin: Double,
        usesBoundaryExtension: Bool = false
    ) throws {
        guard origin.sampleCount == 0, timing.source.epoch == origin.epoch,
            timing.source.sampleRate == origin.sampleRate,
            timing.source.startSample >= origin.startSample,
            firstAnalysisSampleIndex >= -1,
            (0...WindowSpecification.maximumSampleCount).contains(suppliedAnalysisSampleCount),
            centerSecondsFromOrigin.isFinite, centerSecondsFromOrigin >= 0
        else {
            throw CepstrumError.unexpectedInterval
        }
        self.origin = origin
        self.timing = timing
        self.frameIndex = frameIndex
        self.firstAnalysisSampleIndex = firstAnalysisSampleIndex
        self.suppliedAnalysisSampleCount = suppliedAnalysisSampleCount
        self.centerSecondsFromOrigin = centerSecondsFromOrigin == 0 ? 0 : centerSecondsFromOrigin
        self.usesBoundaryExtension = usesBoundaryExtension
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case origin, timing, frameIndex, firstAnalysisSampleIndex, suppliedAnalysisSampleCount,
            centerSecondsFromOrigin,
            usesBoundaryExtension
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            origin: c.decode(SourceInterval.self, forKey: .origin),
            timing: c.decode(AnalysisTiming.self, forKey: .timing),
            frameIndex: c.decode(UInt64.self, forKey: .frameIndex),
            firstAnalysisSampleIndex: c.decode(Int64.self, forKey: .firstAnalysisSampleIndex),
            suppliedAnalysisSampleCount: c.decode(Int.self, forKey: .suppliedAnalysisSampleCount),
            centerSecondsFromOrigin: c.decode(Double.self, forKey: .centerSecondsFromOrigin),
            usesBoundaryExtension: c.decode(Bool.self, forKey: .usesBoundaryExtension))
    }
}

/// A finite prefix of one stage. Incomplete stages carry a reason, never NaN/Inf or
/// artificial zero values. For an unfloored zero Nyquist, the log prefix is retained.
/// This view and its pointers are valid only inside the processing callback.
public struct BorrowedCepstralStage<Sample: BinaryFloatingPoint & Sendable> {
    public let stage: CepstralStage
    public let values: UnsafeBufferPointer<Sample>
    public let expectedCount: Int
    public let unavailability: UnavailabilityReason?
    public var isComplete: Bool { unavailability == nil && values.count == expectedCount }
}

/// Borrowed worker scratch, intentionally not Sendable. Do not retain this value or
/// any stage pointer after the callback. Owned exports are explicit and budgeted.
public struct BorrowedPowerCepstrum<Sample: BinaryFloatingPoint & Sendable> {
    public let configuration: PowerCepstrumConfiguration
    public let profile: ProfileIdentity
    public let context: CepstralFrameContext
    public let unavailability: UnavailabilityReason?
    private let stages: CepstralStorage<Sample>

    package init(
        configuration: PowerCepstrumConfiguration, profile: ProfileIdentity,
        context: CepstralFrameContext, unavailability: UnavailabilityReason?,
        stages: CepstralStorage<Sample>
    ) {
        self.configuration = configuration
        self.profile = profile
        self.context = context
        self.unavailability = unavailability
        self.stages = stages
    }
    public func stage(_ stage: CepstralStage) -> BorrowedCepstralStage<Sample> {
        let buffer = stages.buffer(stage)
        let count = stages.validCount(stage)
        return BorrowedCepstralStage(
            stage: stage,
            values: UnsafeBufferPointer(start: buffer.baseAddress, count: count),
            expectedCount: buffer.count,
            unavailability: count == buffer.count ? nil : unavailability)
    }
    /// Copies only requested finite stages, outside the prepared processing allocation claim.
    /// A partial logarithm has fewer bins; its status is preserved alongside the snapshot.
    public func export(stages requested: Set<CepstralStage>, policy: IntermediateOutputPolicy)
        throws
        -> [CepstralStageSnapshot]
    {
        var remaining = policy.maximumScalarCount
        var result: [CepstralStageSnapshot] = []
        for name in CepstralStage.allCases where requested.contains(name) {
            let view = stage(name)
            guard view.values.count <= remaining else {
                throw ContractError.intermediateBudgetExceeded
            }
            remaining -= view.values.count
            let snapshot: IntermediateSnapshot?
            if view.values.isEmpty {
                snapshot = nil
            } else {
                snapshot = try IntermediateSnapshot(
                    stage: VersionedIdentifier(name: "cepstrum-" + name.rawValue, version: 1),
                    source: context.timing.source, xUnit: name.xUnit, yUnit: name.yUnit,
                    xOrigin: 0, xStep: name.step(configuration: configuration),
                    values: view.values.map(Double.init))
            }
            result.append(
                CepstralStageSnapshot(
                    stage: name, expectedCount: view.expectedCount,
                    unavailability: view.unavailability, snapshot: snapshot))
        }
        return result
    }
}

/// Owned debug/export product, retaining availability separately from finite values.
public struct CepstralStageSnapshot: Sendable, Hashable {
    public let stage: CepstralStage
    public let expectedCount: Int
    public let unavailability: UnavailabilityReason?
    public let snapshot: IntermediateSnapshot?
}
