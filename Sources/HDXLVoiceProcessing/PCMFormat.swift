/// The rate and channel count of a PCM source, independent of capture or UI frameworks.
///
/// Samples are normalized floating-point amplitudes. Algorithms declare their supported
/// rates, channel selection, and layout separately; this type does not imply resampling.
public struct PCMFormat: Sendable, Hashable {
    public let sampleRate: Double
    public let channelCount: Int

    public enum ValidationError: Error, Sendable, Equatable {
        case invalidSampleRate
        case invalidChannelCount
    }

    /// Creates a source format with a finite, positive rate and a positive channel count.
    public init(sampleRate: Double, channelCount: Int) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ValidationError.invalidSampleRate
        }
        guard channelCount > 0 else {
            throw ValidationError.invalidChannelCount
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}
