import Foundation

/// Fixed zero-phase FIR geometry. This preview is not the Praat whole-interval profile.
public struct PreviewConditioningLayout: Sendable, Hashable, Codable {
    /// Bounds relative integer arithmetic; absolute source origins may still approach Int64.max.
    public static let maximumInputSampleCount: Int64 = 1 << 48
    public static let maximumCoefficientCount = 1_048_576
    public let configuration: ConditioningConfiguration
    public let outputBlockCapacity: Int
    public let filterRadius: Int
    public var coefficientCount: Int { configuration.ratio.numerator * (2 * filterRadius + 1) }
    /// Includes the rightmost input sample's full acquisition interval, excluding output batching.
    public var maximumFilterLookaheadSeconds: Double {
        (Double(filterRadius) + 0.5) / Double(configuration.sourceSampleRate)
    }
    public init(configuration: ConditioningConfiguration, outputBlockCapacity: Int = 256) throws {
        guard case .streamingPreview(let lobes, _) = configuration.method else {
            throw ConditioningError.invalidQuality
        }
        guard (1...4096).contains(outputBlockCapacity) else {
            throw ConditioningError.capacityExceeded
        }
        let rate = Double(configuration.targetSampleRate) / Double(configuration.sourceSampleRate)
        let radius = Int(ceil(Double(lobes) / min(1, rate)))
        guard configuration.ratio.numerator * (2 * radius + 1) <= Self.maximumCoefficientCount
        else {
            throw ConditioningError.capacityExceeded
        }
        self.configuration = configuration
        self.outputBlockCapacity = outputBlockCapacity
        self.filterRadius = radius
    }
    /// Final count is floor(N * target/source), evaluated without a large product.
    public func outputSampleCount(inputSampleCount: Int64) throws -> Int64 {
        guard (0...Self.maximumInputSampleCount).contains(inputSampleCount) else {
            throw ConditioningError.capacityExceeded
        }
        let p = Int64(configuration.ratio.numerator)
        let q = Int64(configuration.ratio.denominator)
        return inputSampleCount / q * p + inputSampleCount % q * p / q
    }
    /// Exact zero-based source coordinate of target sample j: ((j + 1/2)Q/P - 1/2).
    /// Splitting into whole rational periods prevents multiplication overflow and clock drift.
    package func position(_ index: Int64) -> (left: Int64, remainder: Int64) {
        let p = Int64(configuration.ratio.numerator)
        let q = Int64(configuration.ratio.denominator)
        let small = (2 * (index % p) + 1) * q - p
        let denominator = 2 * p
        let remainder = ((small % denominator) + denominator) % denominator
        return (index / p * q + (small - remainder) / denominator, remainder)
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case configuration, outputBlockCapacity, filterRadius
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            configuration: c.decode(ConditioningConfiguration.self, forKey: .configuration),
            outputBlockCapacity: c.decode(Int.self, forKey: .outputBlockCapacity))
        guard try c.decode(Int.self, forKey: .filterRadius) == filterRadius else {
            throw ContractError.invalidConfiguration
        }
    }
}

/// Borrowed PCM support, with target indices kept separate from original source coordinates.
/// `usesBoundaryExtension` must be considered before treating this as measurement-ready PCM.
public struct PreviewConditionedBlock: Sendable, Hashable, Codable {
    public let layout: PreviewConditioningLayout
    /// Zero-length source interval identifying the start of this separately conditioned stream.
    public let origin: SourceInterval
    public let outputStartIndex: Int64
    public let outputSampleCount: Int
    public let deliveryInputSampleCount: Int64
    public let isFinalizing: Bool
    public let timing: AnalysisTiming
    public let usesLeadingZeroExtension: Bool
    public let usesTrailingZeroExtension: Bool
    public var usesBoundaryExtension: Bool { usesLeadingZeroExtension || usesTrailingZeroExtension }
    public var firstOutputCenterSeconds: Double {
        (Double(outputStartIndex) + 0.5) / Double(layout.configuration.targetSampleRate)
    }
    public init(
        layout: PreviewConditioningLayout, origin: SourceInterval,
        outputStartIndex: Int64, outputSampleCount: Int,
        deliveryInputSampleCount: Int64, isFinalizing: Bool
    ) throws {
        guard origin.sampleCount == 0,
            origin.sampleRate == Double(layout.configuration.sourceSampleRate),
            outputStartIndex >= 0, (1...layout.outputBlockCapacity).contains(outputSampleCount),
            deliveryInputSampleCount > 0
        else { throw ConditioningError.unexpectedInterval }
        let total = try layout.outputSampleCount(inputSampleCount: deliveryInputSampleCount)
        guard outputStartIndex <= total, Int64(outputSampleCount) <= total - outputStartIndex else {
            throw ConditioningError.unexpectedInterval
        }
        // Validate the entire delivered source extent before adding any relative offsets.
        _ = try SourceInterval(
            epoch: origin.epoch, startSample: origin.startSample,
            sampleCount: deliveryInputSampleCount, sampleRate: origin.sampleRate)
        let firstDependency =
            layout.configuration.preEmphasisFromHz != nil && outputStartIndex > 0
            ? outputStartIndex - 1 : outputStartIndex
        let lower = layout.position(firstDependency).left - Int64(layout.filterRadius)
        let upper =
            layout.position(outputStartIndex + Int64(outputSampleCount) - 1).left
            + Int64(layout.filterRadius) + 1
        guard isFinalizing || upper <= deliveryInputSampleCount else {
            throw ConditioningError.insufficientData
        }
        let clippedLower = max(0, lower)
        let clippedUpper = min(deliveryInputSampleCount, upper)
        let support = try SourceInterval(
            epoch: origin.epoch,
            startSample: origin.startSample + clippedLower,
            sampleCount: clippedUpper - clippedLower, sampleRate: origin.sampleRate)
        // Subtract in source-index space before converting to seconds. Long continuity
        // intervals must not erase a small delivery delay through floating cancellation.
        let firstPosition = layout.position(outputStartIndex)
        let fraction =
            Double(firstPosition.remainder) / Double(2 * layout.configuration.ratio.numerator)
        let delay = max(
            0,
            (Double(deliveryInputSampleCount - firstPosition.left) - 0.5 - fraction)
                / origin.sampleRate
                - Double(outputSampleCount - 1)
                / (2 * Double(layout.configuration.targetSampleRate)))
        self.layout = layout
        self.origin = origin
        self.outputStartIndex = outputStartIndex
        self.outputSampleCount = outputSampleCount
        self.deliveryInputSampleCount = deliveryInputSampleCount
        self.isFinalizing = isFinalizing
        self.timing = try AnalysisTiming(
            source: support, includedSampleCount: support.sampleCount,
            effectiveDelaySeconds: delay)
        self.usesLeadingZeroExtension = lower < 0
        self.usesTrailingZeroExtension = upper > deliveryInputSampleCount
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case layout, origin, outputStartIndex, outputSampleCount, deliveryInputSampleCount
        case isFinalizing, timing, usesLeadingZeroExtension, usesTrailingZeroExtension
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            layout: c.decode(PreviewConditioningLayout.self, forKey: .layout),
            origin: c.decode(SourceInterval.self, forKey: .origin),
            outputStartIndex: c.decode(Int64.self, forKey: .outputStartIndex),
            outputSampleCount: c.decode(Int.self, forKey: .outputSampleCount),
            deliveryInputSampleCount: c.decode(Int64.self, forKey: .deliveryInputSampleCount),
            isFinalizing: c.decode(Bool.self, forKey: .isFinalizing))
        guard try c.decode(AnalysisTiming.self, forKey: .timing) == timing,
            try c.decode(Bool.self, forKey: .usesLeadingZeroExtension) == usesLeadingZeroExtension,
            try c.decode(Bool.self, forKey: .usesTrailingZeroExtension) == usesTrailingZeroExtension
        else { throw ContractError.invalidTiming }
    }
}

public struct PreviewConditioningProcessReport: Sendable, Hashable {
    public let consumedSampleCount: Int
    public let emittedSampleCount: Int64
    public let isCancelled: Bool
}

/// Final counts include boundary-extended samples; zero output remains explicitly distinguishable.
public struct PreviewConditioningCompletion: Sendable, Hashable {
    public let source: SourceInterval
    public let outputSampleCount: Int64
    public var hasOutput: Bool { outputSampleCount > 0 }
    public let isCancelled: Bool
}
