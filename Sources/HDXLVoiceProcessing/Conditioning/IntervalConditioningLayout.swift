import Foundation

/// Whole-interval geometry, independent of PCM. Boundaries and rounding belong to this profile.
public struct IntervalConditioningLayout: Sendable, Hashable, Codable {
    public static let maximumInputSamples = 2_880_000
    public static let maximumOutputSamples = 4_194_304
    public let configuration: ConditioningConfiguration
    public let inputSampleCount: Int
    public let outputSampleCount: Int
    public let forwardTransformLength: Int?
    public let inverseTransformLength: Int?
    public let firstOutputCenterSeconds: Double
    public var sourceDurationSeconds: Double {
        Double(inputSampleCount) / Double(configuration.sourceSampleRate)
    }
    /// Whole-input filtering waits from the support midpoint to its end; compute time is separate.
    public var effectiveDelaySeconds: Double { sourceDurationSeconds / 2 }

    public init(configuration: ConditioningConfiguration, inputSampleCount: Int) throws {
        guard case .praat7WholeInterval = configuration.method else {
            throw ConditioningError.invalidQuality
        }
        guard (1...Self.maximumInputSamples).contains(inputSampleCount) else {
            throw ConditioningError.capacityExceeded
        }
        let fs = Double(configuration.sourceSampleRate)
        let target = Double(configuration.targetSampleRate)
        let duration = Double(inputSampleCount) / fs
        let equal = configuration.sourceSampleRate == configuration.targetSampleRate
        let twice = configuration.targetSampleRate == 2 * configuration.sourceSampleRate
        let count =
            equal
            ? inputSampleCount
            : twice
                ? 2 * inputSampleCount : Int((duration * target).rounded(.toNearestOrAwayFromZero))
        guard count > 0 else { throw ConditioningError.insufficientData }
        guard count <= Self.maximumOutputSamples else { throw ConditioningError.capacityExceeded }
        let forward: Int?
        let inverse: Int?
        if configuration.targetSampleRate < configuration.sourceSampleRate || twice {
            let length = try FourierConfiguration.lengthPadding(inputSampleCount + 2000)
            let inverseLength = twice ? 2 * length : length
            guard inverseLength <= FourierConfiguration.maximumLength else {
                throw ConditioningError.capacityExceeded
            }
            forward = length
            inverse = inverseLength
        } else {
            forward = nil
            inverse = nil
        }
        self.configuration = configuration
        self.inputSampleCount = inputSampleCount
        self.outputSampleCount = count
        self.forwardTransformLength = forward
        self.inverseTransformLength = inverse
        self.firstOutputCenterSeconds =
            equal || twice ? 0.5 / target : 0.5 * (duration - Double(count - 1) / target)
    }
    public func outputCenterSeconds(at index: Int) throws -> Double {
        guard (0..<outputSampleCount).contains(index) else { throw ContractError.invalidValue }
        return firstOutputCenterSeconds + Double(index)
            * (1 / Double(configuration.targetSampleRate))
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case configuration, inputSampleCount, outputSampleCount, forwardTransformLength
        case inverseTransformLength, firstOutputCenterSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard c.contains(.forwardTransformLength), c.contains(.inverseTransformLength) else {
            throw ContractError.invalidConfiguration
        }
        try self.init(
            configuration: c.decode(ConditioningConfiguration.self, forKey: .configuration),
            inputSampleCount: c.decode(Int.self, forKey: .inputSampleCount))
        guard try c.decode(Int.self, forKey: .outputSampleCount) == outputSampleCount,
            try c.decodeIfPresent(Int.self, forKey: .forwardTransformLength)
                == forwardTransformLength,
            try c.decodeIfPresent(Int.self, forKey: .inverseTransformLength)
                == inverseTransformLength,
            try c.decode(Double.self, forKey: .firstOutputCenterSeconds) == firstOutputCenterSeconds
        else { throw ContractError.invalidConfiguration }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configuration, forKey: .configuration)
        try c.encode(inputSampleCount, forKey: .inputSampleCount)
        try c.encode(outputSampleCount, forKey: .outputSampleCount)
        try c.encode(forwardTransformLength, forKey: .forwardTransformLength)
        try c.encode(inverseTransformLength, forKey: .inverseTransformLength)
        try c.encode(firstOutputCenterSeconds, forKey: .firstOutputCenterSeconds)
    }
}

/// Source support remains in original sample coordinates; output indices use the separate layout.
public struct ConditionedInterval: Sendable, Hashable, Codable {
    public let layout: IntervalConditioningLayout
    public let timing: AnalysisTiming
    public init(layout: IntervalConditioningLayout, source: SourceInterval) throws {
        guard source.sampleCount == Int64(layout.inputSampleCount),
            source.sampleRate == Double(layout.configuration.sourceSampleRate)
        else {
            throw ConditioningError.unexpectedInterval
        }
        self.layout = layout
        self.timing = try AnalysisTiming(
            source: source, includedSampleCount: source.sampleCount,
            effectiveDelaySeconds: layout.effectiveDelaySeconds)
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case layout, timing }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let layout = try c.decode(IntervalConditioningLayout.self, forKey: .layout)
        let timing = try c.decode(AnalysisTiming.self, forKey: .timing)
        try self.init(layout: layout, source: timing.source)
        guard timing == self.timing else { throw ContractError.invalidTiming }
    }
}
