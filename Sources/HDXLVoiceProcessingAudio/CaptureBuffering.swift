/// Prepared capture storage limits, independent of the native tap's requested size.
public struct CaptureBuffering: Sendable, Hashable {
    public let requestedTapFrames: UInt32
    public let maximumFramesPerChunk: UInt32
    public let slotCount: Int

    /// Requested frames are a hint. Larger delivered chunks become explicit gaps
    /// when they exceed the prepared transfer's maximum accepted size.
    public init(
        requestedTapFrames: UInt32 = 4096, maximumFramesPerChunk: UInt32 = 32_768,
        slotCount: Int = 16
    ) throws {
        guard (1...65_536).contains(requestedTapFrames),
            (1...65_536).contains(maximumFramesPerChunk),
            (2...4096).contains(slotCount), slotCount.nonzeroBitCount == 1
        else { throw CaptureIntegrationError.invalidConfiguration }
        self.requestedTapFrames = requestedTapFrames
        self.maximumFramesPerChunk = maximumFramesPerChunk
        self.slotCount = slotCount
    }
}
