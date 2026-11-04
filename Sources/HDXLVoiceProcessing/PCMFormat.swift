/// The rate and channel count of a PCM source, independent of capture or UI frameworks.
///
/// Samples are normalized floating-point amplitudes. Algorithms declare their supported
/// rates, channel selection, and layout separately; this type does not imply resampling.
public struct PCMFormat: Sendable, Hashable, Codable {
    public let sampleRate: Double
    public let channelCount: Int
    public let encoding: PCMEncoding
    public let layout: PCMLayout

    public enum ValidationError: Error, Sendable, Equatable {
        case invalidSampleRate
        case invalidChannelCount
    }

    /// Creates a source format with a finite, positive rate and a positive channel count.
    public init(
        sampleRate: Double, channelCount: Int, encoding: PCMEncoding = .float32,
        layout: PCMLayout = .interleaved
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ValidationError.invalidSampleRate
        }
        guard channelCount > 0 else {
            throw ValidationError.invalidChannelCount
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.encoding = encoding
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sampleRate, channelCount, encoding, layout
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            sampleRate: c.decode(Double.self, forKey: .sampleRate),
            channelCount: c.decode(Int.self, forKey: .channelCount),
            encoding: c.decode(PCMEncoding.self, forKey: .encoding),
            layout: c.decode(PCMLayout.self, forKey: .layout))
    }
}

public enum PCMEncoding: String, Sendable, Hashable, Codable { case float32, float64 }
public enum PCMLayout: String, Sendable, Hashable, Codable { case interleaved, planar }
public enum AnalysisPrecision: String, Sendable, Hashable, Codable { case float32, float64 }
