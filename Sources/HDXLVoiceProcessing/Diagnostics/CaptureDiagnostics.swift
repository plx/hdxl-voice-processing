/// Single-producer value storage, constructed before capture starts.
/// Copy through the production handoff, or read after capture has stopped. Do not
/// concurrently read this value from a worker. No signposter or sink is reachable.
package struct CaptureDiagnostics: Equatable, Sendable {
    package private(set) var callbacks: UInt64 = 0
    package private(set) var droppedFrames: UInt64 = 0
    package private(set) var lastHostTimestamp: UInt64 = 0
    package private(set) var largestBlock: UInt32 = 0

    package init() {}

    /// Timestamp is supplied by the host callback; this function does not read a clock.
    @inline(never)
    package mutating func record(frames: UInt32, hostTimestamp: UInt64, dropped: Bool) {
        callbacks = saturatingAdd(callbacks)
        if dropped { droppedFrames = saturatingAdd(droppedFrames, UInt64(frames)) }
        lastHostTimestamp = hostTimestamp
        largestBlock = max(largestBlock, frames)
    }
}
