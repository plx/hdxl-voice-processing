import Foundation

public enum LevelError: Error, Sendable, Equatable {
    case precisionMismatch, unexpectedInterval, invalidState, reentrantCall, nonfiniteResult
    case nonfiniteInput(LevelInputDiagnostics)

    public var unavailability: UnavailabilityReason {
        switch self {
        case .precisionMismatch, .nonfiniteInput: .invalidInput
        case .unexpectedInterval: .discontinuity
        case .invalidState, .reentrantCall, .nonfiniteResult: .analysisFailure
        }
    }
}

public enum LevelInputStatus: String, Sendable, Hashable, Codable {
    case empty, finite, atFullScale, overFullScale, nonfinite
}

/// Finite rail hits indicate possible clipping, not proof of physical ADC saturation.
/// Nonfinite diagnostics describe a rejected chunk; no partial numeric estimate is published.
public struct LevelInputDiagnostics: Sendable, Hashable, Codable {
    public let sampleCount: Int
    public let nanSampleCount: Int
    public let positiveInfinitySampleCount: Int
    public let negativeInfinitySampleCount: Int
    public let atFullScaleSampleCount: Int
    public let overFullScaleSampleCount: Int
    public let subnormalSampleCount: Int
    public let finitePeakMagnitude: Double?
    public var nonfiniteSampleCount: Int {
        nanSampleCount + positiveInfinitySampleCount + negativeInfinitySampleCount
    }
    public var finiteSampleCount: Int { sampleCount - nonfiniteSampleCount }
    public var possibleClippingSampleCount: Int {
        atFullScaleSampleCount + overFullScaleSampleCount
    }
    public var status: LevelInputStatus {
        if sampleCount == 0 { return .empty }
        if nonfiniteSampleCount > 0 { return .nonfinite }
        if overFullScaleSampleCount > 0 { return .overFullScale }
        if atFullScaleSampleCount > 0 { return .atFullScale }
        return .finite
    }
    public var isSilent: Bool {
        finiteSampleCount > 0 && nonfiniteSampleCount == 0 && finitePeakMagnitude == 0
    }

    init(
        sampleCount: Int, nan: Int = 0, positiveInfinity: Int = 0, negativeInfinity: Int = 0,
        atFullScale: Int, overFullScale: Int, subnormal: Int, finitePeakMagnitude: Double?
    ) throws {
        guard sampleCount >= 0, (0...sampleCount).contains(nan),
            (0...(sampleCount - nan)).contains(positiveInfinity),
            (0...(sampleCount - nan - positiveInfinity)).contains(negativeInfinity)
        else { throw ContractError.invalidValue }
        let finiteCount = sampleCount - nan - positiveInfinity - negativeInfinity
        guard (0...finiteCount).contains(atFullScale),
            (0...(finiteCount - atFullScale)).contains(overFullScale),
            (0...(finiteCount - atFullScale - overFullScale)).contains(subnormal),
            (finiteCount == 0) == (finitePeakMagnitude == nil)
        else { throw ContractError.invalidValue }
        if let peak = finitePeakMagnitude {
            guard peak.isFinite, peak >= 0,
                peak > 0 || subnormal == 0,
                (peak >= 1) == (atFullScale + overFullScale > 0),
                (peak > 1) == (overFullScale > 0)
            else { throw ContractError.invalidValue }
        }
        self.sampleCount = sampleCount
        self.nanSampleCount = nan
        self.positiveInfinitySampleCount = positiveInfinity
        self.negativeInfinitySampleCount = negativeInfinity
        self.atFullScaleSampleCount = atFullScale
        self.overFullScaleSampleCount = overFullScale
        self.subnormalSampleCount = subnormal
        self.finitePeakMagnitude = finitePeakMagnitude.map { $0 == 0 ? 0 : $0 }
    }

    public static func inspect<S: BinaryFloatingPoint>(_ samples: UnsafeBufferPointer<S>) throws
        -> Self
    {
        guard S.self == Float.self || S.self == Double.self else {
            throw LevelError.precisionMismatch
        }
        let threshold =
            S.self == Float.self ? Double(Float.leastNormalMagnitude) : Double.leastNormalMagnitude
        var nan = 0
        var positive = 0
        var negative = 0
        var at = 0
        var over = 0
        var subnormal = 0
        var peak: Double?
        for sample in samples {
            let value = Double(sample)
            if value.isNaN {
                nan += 1
            } else if value == .infinity {
                positive += 1
            } else if value == -.infinity {
                negative += 1
            } else {
                let magnitude = abs(value)
                peak = max(peak ?? 0, magnitude)
                if magnitude == 1 { at += 1 }
                if magnitude > 1 { over += 1 }
                if magnitude > 0 && magnitude < threshold { subnormal += 1 }
            }
        }
        return try Self(
            sampleCount: samples.count, nan: nan, positiveInfinity: positive,
            negativeInfinity: negative,
            atFullScale: at, overFullScale: over, subnormal: subnormal, finitePeakMagnitude: peak)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sampleCount, nanSampleCount, positiveInfinitySampleCount, negativeInfinitySampleCount
        case atFullScaleSampleCount, overFullScaleSampleCount, subnormalSampleCount,
            finitePeakMagnitude
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard c.contains(.finitePeakMagnitude) else { throw ContractError.invalidValue }
        try self.init(
            sampleCount: c.decode(Int.self, forKey: .sampleCount),
            nan: c.decode(Int.self, forKey: .nanSampleCount),
            positiveInfinity: c.decode(Int.self, forKey: .positiveInfinitySampleCount),
            negativeInfinity: c.decode(Int.self, forKey: .negativeInfinitySampleCount),
            atFullScale: c.decode(Int.self, forKey: .atFullScaleSampleCount),
            overFullScale: c.decode(Int.self, forKey: .overFullScaleSampleCount),
            subnormal: c.decode(Int.self, forKey: .subnormalSampleCount),
            finitePeakMagnitude: c.decodeIfPresent(Double.self, forKey: .finitePeakMagnitude))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(nanSampleCount, forKey: .nanSampleCount)
        try c.encode(positiveInfinitySampleCount, forKey: .positiveInfinitySampleCount)
        try c.encode(negativeInfinitySampleCount, forKey: .negativeInfinitySampleCount)
        try c.encode(atFullScaleSampleCount, forKey: .atFullScaleSampleCount)
        try c.encode(overFullScaleSampleCount, forKey: .overFullScaleSampleCount)
        try c.encode(subnormalSampleCount, forKey: .subnormalSampleCount)
        try c.encode(finitePeakMagnitude, forKey: .finitePeakMagnitude)
    }
}
