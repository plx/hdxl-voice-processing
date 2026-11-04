# Benchmark bootstrap evidence

Issue #17, verified 2026-11-04 on macOS 27.0.1 (26A434), Xcode 27.0
(27A266a), Swift 6.4, and CPython 3.14.8. The separate package accepts the
requested benchmark 1.38.0 release at
`def9afdba446b03efbbbcecb3b892e97e8294214`; Swift 6.4 selects its primary
tools-6.3 manifest. No alternative release or system jemalloc install was needed.

A clean detached checkout of `8be6f16bd1a834f62a318f559bfe70c70070144a`
ran both release modes with initially empty local build directories. SwiftPM
fetched the eight locked packages from its download cache and built the actual
executables. Environment artifacts report `workingTreeDirty: false` and framework
scaling factor one. Resolution remained byte-for-byte unchanged in both modes.

| Check | Observed result |
| --- | --- |
| Timing plugin discovery | Exactly `Smoke.GainEnergy` |
| Diagnostic discovery | Smoke plus `Capability.AllocationARC` |
| Timing linkage | No malloc interposer or jemalloc library/symbols |
| Diagnostic linkage | MallocInterposer dynamic library present; jemalloc absent |
| Optimized output, both modes | FNV checksum `b60cf45de1595748`; energy `86.15017700195312`; output changed from initial zero buffer |
| Timing JSON coverage | Two finite metrics: wall-clock and CPU time |
| Diagnostic JSON coverage | Fourteen metrics across smoke and positive control |
| Positive control p99 counters | 2 mallocs, 4,120 allocated bytes, 2 frees, 1 object allocation, 2 retains, 3 releases |
| Preallocated smoke counters | Zero malloc/ARC counts, with the positive control proving the backend is active |
| Baselines | Update, JSON read/export, and comparison against a new run succeeded in each mode |

Counts above are an observed capability example, not exact cross-toolchain
requirements. The verifier requires positive control counters, not these exact
numbers. No timing threshold or performance conclusion is derived from concurrent
development runs. JSON values describe a whole outer batch: 1,000 frames of
1,024 Float64 samples for smoke, one operation for the control.

The root verification wrapper passed all 20 Swift tests and the initial 24 Python tests,
formatting/provenance checks, independent consumer graph/link inspection, and
network-denied consumer execution. Workflow syntax passed checksum-pinned
actionlint. The separate benchmark smoke job and unsigned iOS product/consumer
checks are tracked on [PR #83](https://github.com/plx/hdxl-voice-processing/pull/83).
The [initial hosted run](https://github.com/plx/hdxl-voice-processing/actions/runs/41835878842)
passed all seven PR jobs. Downloaded benchmark artifacts confirmed clean checkouts,
factor-one units, the expected checksums, and positive diagnostic control counters.

Two upstream behaviors informed the wrapper: export can return success after a
sandbox write failure, so files and coverage must be validated; JSON normalization
with nontrivial framework scaling needs further confirmation (#82), so this
harness uses explicit batching with factor one. The scalar gain/energy kernel is
original benchmark scaffolding, not a shipped voice-analysis algorithm. Hardware
capture, device performance, thermal/energy evidence, and watch support remain
outside these host checks.

Local review subsequently caught two baseline-specific evidence failures: compare
performed two measurements, and an unsuccessful overwrite could read stale samples.
The corrected wrapper captures a fresh named baseline, validates its export, and
uses that same capture for comparison or atomic promotion. Two failure-path tests
cover a framework success with no write and a failed atomic replacement that
preserves the previous baseline (26 Python tests total). Post-fix baseline checks
are recorded in the PR verification summary.
