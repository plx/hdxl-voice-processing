# A01 framing and window evidence

Issue: [#24](https://github.com/plx/hdxl-voice-processing/issues/24). Local working-tree
validation on 2026-11-04; the leaf PR records final hosted runs and both reviewer
outcomes before merge. These observations are host evidence, not physical-device
qualification or a performance budget.

The measurements below retain the original 65,536-sample maximum. The subsequent
capacity extension in [#165](https://github.com/plx/hdxl-voice-processing/issues/165)
raises the shared bound to 131,072 samples and reruns the six maximum-size benchmark
cases with independent geometry checks. The historical p99 table is unchanged.

## Correctness and numerical provenance

- Debug, release, Address Sanitizer, and Thread Sanitizer lanes passed 55 xUnit
  test cases each, with no failures/errors. The 18 new test functions cover window
  definitions/gains, padding, aliases, typed precision, integer eligibility, all
  relevant boundary positions, seeded and adversarial partitions, gaps, lifecycle,
  maximum prepared support, Int64 limits, cancellation borrow lifetime, and diagnostics.
- 71 Python tests passed, including malformed reference/export rejection, exact
  metadata checks, numerical regeneration tolerance, positive allocation controls,
  and zero-maximum allocation checks. Workflow syntax and offline consumer/product
  boundary checks passed. Existing smoke timing/allocation workflows still pass
  after explicitly isolating their benchmark target.
- Gaussian2 coefficients for N=1,2,3,4,5,17,1000 agree with pinned Praat 7.0.02 and
  an original 70-digit Decimal oracle to absolute error 5e-15. Fresh CLI regeneration
  was checked independently of Swift tests; no reference implementation is bundled.
- Gaussian fixture SHA-256: `199390ba80b01906ee7cbe0ce6d3c7c9faf83daaa921dacaf23f6e1f227a351b`.
  The inventory contains 82 original fixture artifacts; runtime dependencies/resources
  remain unchanged.

## Host performance

Measured on `Mac13,1`, `arm64`, macOS `27.0.1`,
Xcode 27.0 / Swift 6.4, in release mode. Timing collection began
`2026-11-04T17:15:07.690195+00:00`. Inputs are original deterministic ramps, generated before
measurement. Each workload uses three warmups and up to 30 measured iterations;
the validator requires at least ten samples per metric. Full histograms are retained.

All 88 configurations and 440 workloads passed in ordinary timing mode (880 metrics).
Allocation mode passed 441 workloads including its positive control (3,087 metrics).
The 352 steady-state workloads have **zero maximum malloc count, malloc bytes, and
object-allocation count across all 1,056 corresponding histograms**. ARC retains
and releases are reported separately and are not assumed zero. Preparation is
expected to allocate. The control observed maximum malloc count
2, malloc bytes 4120,
object allocations 1, retains 2,
releases 3, and frees 2.

Representative ordinary-timing p99 **milliseconds per measured batch**:

| Configuration | Prepare (1) | Window writes (100) | Resets (100) | Whole input | 17-sample chunks |
| --- | ---: | ---: | ---: | ---: | ---: |
| Float64 / 16 kHz / N800 H32 | 0.3327 | 2.2098 | 0.0223 | 9.7607 | 10.0681 |
| Float32 / 44.1 kHz / N2205 H88 | 0.6869 | 5.6764 | 0.0200 | 26.3641 | 27.3145 |
| Float64 / 48 kHz / N2400 H96 | 0.8314 | 6.0950 | 0.0234 | 28.5939 | 30.0607 |
| Float64 / 16 kHz / N65536 H32 | 17.8288 | 159.7443 | 0.0188 | 18.3133 | 19.6884 |

The first three rows process one second of input; the maximum-support row processes
65,856 samples (4.116 seconds). Window/reset columns explicitly batch 100 operations;
framework scaling is one. Whole-input/chunked costs include validation, framing,
window application, checksum observation, and finish, with reset outside measurement.
Preparation includes window coefficients, identities, scratch, and temporary cleanup.
These p99 values describe this host/run; the raw distributions retain variability.
Allocation-instrumented durations must not be substituted for ordinary timing.

Evidence under `Benchmarks/.build/artifacts/framing-{timing,allocation}/` includes
host/toolchain, exact configuration identities, requested/actual window/hop sizes,
precision, input duration, units, operation counts, histograms, p99 and command records.
The compressed raw timing capture SHA-256 is `2341337ea0e6827e735b37248552c2464d1270a77845df822f27bf25236af839`; allocation capture
SHA-256 is `b43969669e7adcba81b033020c1a6f2a2f49d20ebca00d358e9e0d61133b3cef`. Framework units are explicitly nanoseconds/raw
counts to avoid automatic K/M presentation; JSON scaling remains one (#82).

Reproduce using [Tools/Framing/README.md](../../Tools/Framing/README.md). The dedicated
framing workflow repeats both modes, and reference regeneration includes the Gaussian
oracle. Workloads are registered under #25 and frame-copy instrumentation under #18.
Public grid/tail/window convention review is tracked by #91 under #73. Physical
capture/performance evidence remains deferred under #74 with owner authorization.
