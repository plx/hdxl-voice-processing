# Shared scheduler bring-up evidence

Local development validation on 2026-11-06 used a Mac13,1, arm64, macOS 27.0.1
(26A434), Xcode 27.0 (27A266a) and Swift 6.4.0.34.1. These local runs preceded the
implementation commit; hosted PR artifacts identify the final tested commit/tree.

## Correctness and boundaries

The complete initial Debug lane passed 236 Swift cases, fixture/provenance checks,
the Python suite, package graph/offline checks and the independent Core consumer.
The final replay test was added afterward: the complete Release and AddressSanitizer
lanes passed all 237 cases, including 25 targeted scheduler tests. All 197 updated
Python tests passed. Every product and the independent consumer compiled/linked for
both iOS 27 Simulator and the unsigned device SDK. ThreadSanitizer and the remaining
hosted checks are merge gates recorded in the PR artifacts.

Scheduler checks include seeded random, single-sample, uneven and single-block input;
Float32/Float64 and both layouts; explicit channel conversion; actual PCM16 WAV decoding
and seeks; file/memory/transport parity with available CPPS at 16/44.1/48 kHz; finite
whole-interval and preview applicability; low-F0 support; empty/short/silent input;
exact large source positions and checked clocks; missing/unknown/terminal loss; selected
region boundaries and replay; weighted/tracked dependencies; idempotent finalization;
callback cancellation/reentrancy and independent batch failures.

## Prepared allocation evidence

All 20 explicit [light/full workloads](../../Tools/Scheduling/README.md) passed exact
per-lane value, availability and support-digest comparison against direct native kernels.
The verifier also checked 63/173/whole-source partitions and stable scratch across
reset/replay. Python independently checked the matrix, recipe/identity, masks,
support/availability arithmetic and K-weighting coefficient oracle budgets.

The allocation run retained 41 benchmark rows and 287 metric summaries, with 30 measured
observations per positive-control metric. All 60 prepared Run heap maxima were zero
(20 workloads × malloc-count, malloc-bytes and object-allocation counters). The deliberate
control recorded maximum malloc-count 2, malloc-bytes 4,120, object-allocation 1, free-count
2, retains 2 and releases 3. Allocator linkage was verified. Reported owned buffer budgets
ranged from 97,244 to 1,565,986 bytes; see the workload guide for exclusions.

These results cover core numerical scheduling, reset/replay and finish. They exclude
decoder/I/O, transfer copying, consumer-owned exports/history and opaque object/FFT
overhead. They do not establish process leak freedom or physical real-time performance.
Uninstrumented timing is collected separately by the scheduler CI workflow; each p99
covers one complete source-second Run, not a frame or capture-to-display latency.

Hosted artifacts retain exact workloads and PCM hashes, raw compressed distributions,
validated maxima/sample counts, p99 summaries, environment/toolchain, locked resolution,
commands and status. Physical latency, drift, thermal behavior and capture measurements
remain explicitly deferred to [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
Policy/default attention is tracked in [#123](https://github.com/plx/hdxl-voice-processing/issues/123).
