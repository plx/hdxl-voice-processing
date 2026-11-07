#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    /// After tap removal no new callback closure is published. Existing invocations
    /// may still retain the bridge even after its atomic admission flag clears. Keep
    /// the final reference on the control actor until those closures have released it;
    /// a quiescent flag alone would not cover the callback's ARC epilogue.
    @MainActor final class RetiredCaptureTap {
        var tap: PreparedCaptureTap?
        init(_ tap: PreparedCaptureTap) { self.tap = tap }

        static func releaseWhenUnreferenced(_ tap: PreparedCaptureTap) -> Task<
            CaptureTapFailure?, Never
        > {
            let owner = RetiredCaptureTap(tap)
            return Task { @MainActor in
                while !isKnownUniquelyReferenced(&owner.tap) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                let failure = owner.tap?.failure
                owner.tap = nil
                return failure
            }
        }
    }

#endif
