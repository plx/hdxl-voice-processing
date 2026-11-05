// Deliberate race in a separate development-only capability process.
import Dispatch

private final class RacyStorage: @unchecked Sendable {
    let pointer = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    init() { pointer.initialize(to: 0) }
    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
}

private func provokeRace() {
    let storage = RacyStorage()
    let ready = DispatchSemaphore(value: 0)
    let start = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    for _ in 0..<2 {
        finished.enter()
        DispatchQueue.global().async {
            ready.signal()
            start.wait()
            for index in 0..<100_000 {
                storage.pointer.pointee &+= index &+ 1
            }
            finished.leave()
        }
    }
    // Both workers exist before either enters the deliberately unsynchronized
    // region. There is no happens-before edge between their memory accesses.
    ready.wait()
    ready.wait()
    start.signal()
    start.signal()
    finished.wait()
    print("Unexpected success:", storage.pointer.pointee)
}

provokeRace()
