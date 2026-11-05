import Foundation

/// Pinned whole-interval centering, including floating-point endpoint behavior.
/// This grid intentionally differs from the preview's left-anchored integer grid.
public struct IntervalCepstrogramLayout: Sendable, Hashable, Codable {
    public let configuration: CepstrogramConfiguration
    public let resampling: IntervalConditioningLayout
    public let frameCount: Int
    public let firstCenterSeconds: Double?

    public init(configuration: CepstrogramConfiguration, inputSampleCount: Int) throws {
        guard configuration.previewHopLength == nil else {
            throw CepstrumError.invalidConfiguration
        }
        let layout = try IntervalConditioningLayout(
            configuration: configuration.conditioning,
            inputSampleCount: inputSampleCount)
        let dt = configuration.frame.quefrencyStepSeconds
        let duration = Double(layout.outputSampleCount) * dt
        let width = configuration.frame.physicalWidthSeconds
        let count =
            duration < width ? 0 : Int(floor((duration - width) / configuration.hopSeconds)) + 1
        self.configuration = configuration
        self.resampling = layout
        self.frameCount = count
        self.firstCenterSeconds =
            count == 0
            ? nil
            : layout.firstOutputCenterSeconds - 0.5 * dt + 0.5 * duration
                - 0.5 * Double(count) * configuration.hopSeconds + 0.5 * configuration.hopSeconds
    }
    public func centerSeconds(frameIndex: Int) throws -> Double {
        guard (0..<frameCount).contains(frameIndex), let firstCenterSeconds else {
            throw CepstrumError.unexpectedInterval
        }
        // The pinned reference uses a fused operation. Splitting the multiply/add
        // can move the nearest-sample decision by one at an exact half-sample boundary.
        return firstCenterSeconds.addingProduct(Double(frameIndex), configuration.hopSeconds)
    }
    public func firstAnalysisSampleIndex(frameIndex: Int) throws -> Int {
        let time =
            try centerSeconds(frameIndex: frameIndex) - configuration.frame.physicalWidthSeconds / 2
        let oneBased =
            (time - resampling.firstOutputCenterSeconds) / configuration.frame.quefrencyStepSeconds
            + 1
        return Int(oneBased.rounded(.toNearestOrAwayFromZero)) - 1
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case configuration, resampling, frameCount, firstCenterSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        let r = try c.decode(IntervalConditioningLayout.self, forKey: .resampling)
        guard c.contains(.firstCenterSeconds) else { throw CepstrumError.invalidConfiguration }
        try self.init(
            configuration: c.decode(CepstrogramConfiguration.self, forKey: .configuration),
            inputSampleCount: r.inputSampleCount)
        guard r == resampling, try c.decode(Int.self, forKey: .frameCount) == frameCount,
            try c.decodeIfPresent(Double.self, forKey: .firstCenterSeconds) == firstCenterSeconds
        else {
            throw CepstrumError.invalidConfiguration
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configuration, forKey: .configuration)
        try c.encode(resampling, forKey: .resampling)
        try c.encode(frameCount, forKey: .frameCount)
        try c.encode(firstCenterSeconds, forKey: .firstCenterSeconds)
    }
}

public struct CepstrogramCompletion: Sendable, Hashable {
    public let source: SourceInterval
    public let completeFrameCount: UInt64
    public let emittedFrameCount: UInt64
    public let unavailableFrameCount: UInt64
    public let isCancelled: Bool
}
