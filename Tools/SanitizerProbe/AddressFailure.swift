// Deliberate fault in a separate development-only capability process.
@inline(never)
func readReleasedStorage(_ pointer: UnsafeMutablePointer<Int>) -> Int {
    pointer.pointee
}

let storage = UnsafeMutablePointer<Int>.allocate(capacity: 1)
storage.initialize(to: 114)
storage.deinitialize(count: 1)
storage.deallocate()
print("Unexpected success:", readReleasedStorage(storage))
