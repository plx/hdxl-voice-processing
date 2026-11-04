import Foundation

/// A one-time conversion. Subsequent frame starts use integer sample indices, not accumulated seconds.
public enum SampleCountRounding: String, Sendable, Hashable, Codable {
    case down, nearestAwayFromZero, up

    fileprivate var rule: FloatingPointRoundingRule {
        switch self {
        case .down: .down
        case .nearestAwayFromZero: .toNearestOrAwayFromZero
        case .up: .up
        }
    }
}

/// Records the binary64 seconds×rate conversion, including its quantization error.
/// A fixed rounded hop may differ from a requested time-grid hop; that error is explicit.
public struct SampleCountQuantization: Sendable, Hashable, Codable {
    public let requestedSeconds: Double
    public let sampleRate: Double
    public let rounding: SampleCountRounding
    public let sampleCount: Int
    public var actualSeconds: Double { Double(sampleCount) / sampleRate }
    public var errorSeconds: Double { actualSeconds - requestedSeconds }

    public init(
        seconds: Double, sampleRate: Double, rounding: SampleCountRounding = .nearestAwayFromZero
    ) throws {
        guard seconds.isFinite, seconds > 0, sampleRate.isFinite, sampleRate > 0 else {
            throw ContractError.invalidConfiguration
        }
        let product = seconds * sampleRate
        guard product.isFinite,
            let count = Int(exactly: product.rounded(rounding.rule)), count > 0,
            (Double(count) / sampleRate).isFinite
        else { throw ContractError.invalidConfiguration }
        self.requestedSeconds = seconds
        self.sampleRate = sampleRate
        self.rounding = rounding
        self.sampleCount = count
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case requestedSeconds, sampleRate, rounding, sampleCount, actualSeconds, errorSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            seconds: c.decode(Double.self, forKey: .requestedSeconds),
            sampleRate: c.decode(Double.self, forKey: .sampleRate),
            rounding: c.decode(SampleCountRounding.self, forKey: .rounding))
        guard try c.decode(Int.self, forKey: .sampleCount) == sampleCount,
            try c.decode(Double.self, forKey: .actualSeconds) == actualSeconds,
            try c.decode(Double.self, forKey: .errorSeconds) == errorSeconds
        else { throw ContractError.invalidConfiguration }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestedSeconds, forKey: .requestedSeconds)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(rounding, forKey: .rounding)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(actualSeconds, forKey: .actualSeconds)
        try c.encode(errorSeconds, forKey: .errorSeconds)
    }
}
