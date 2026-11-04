# Bootstrap evidence

Issue #14, collected 2026-11-04 on arm64 macOS 27.0.1 (26A434), Xcode 27.0
(27A266a), Apple Swift 6.4 (swiftlang-6.4.0.34.1). SDKs: macOS/iOS/iOS Simulator 27.0.

`bash Tools/verify.sh` passed: formatting, debug build, five Swift Testing tests
(including eight parameterized invalid-input cases), independent core consumer,
and manifest/link checks. `PCMFormat` rejects nonfinite/nonpositive sample rates
and nonpositive channel counts, preserves source settings, and crosses a task
boundary as an immutable value. The core-only debug executable was 65,184 bytes
on this host. This size is informational, not an algorithm performance baseline.

`bash Tools/build-ios.sh` passed for all three products for generic iOS Simulator,
including arm64 and x86_64 compilation. This is build evidence, not a simulator
test run or physical microphone validation. Product graph checks found no external
runtime dependencies; the core consumer did not link SwiftUI or audio frameworks.

Initial sandboxed attempts could not write compiler caches. The same verification
commands succeeded with normal Xcode/Swift cache access. Clean CI execution and
optimized/sanitizer coverage are added in #19. Physical validation remains #74.
