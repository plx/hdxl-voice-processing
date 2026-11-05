# A07 CPPS evidence

Implementation starts from main `a746cce0467e8582e2b0e206a7b799cc538694ac`.
Initial evidence was collected on 2026-11-05 UTC using Mac13,1, arm64,
macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4 and Python 3.14.8.
Physical/device/thermal evidence remains [#74](https://github.com/plx/hdxl-voice-processing/issues/74).

## Independent numerical evidence

The committed family contains **36 cases plus its manifest**. Eighteen constructed
PowerCepstrograms expose all raw/prepared/time-smoothed/final power cells and 222
raw/final CPP frame fits. An independent Python oracle integrates triangular basis
functions; the Swift implementation integrates piecewise-linear segments. Cases
cover activation thresholds, edges, singleton axes, affine planes, tilted peaks,
pretrend, disabled smoothing, 1/5 ms quefrency windows and tolerance extremes.

The other eighteen cases begin with actual PCM: synthetic controls, a 120 ms
buffer, licensed vowels, all-voiced and consonant-rich sentences, low-level speech,
and interrupted acquisition. Seventeen scoped cases pass **12,923 final CPPS
frame comparisons**, including independently conditioned acquired regions around
the annotated dropout. The deliberately unmasked dropout is retained as a failed
per-frame characterization, not counted as parity success. This distinction and
conditioning-stage diagnostics are tracked in
[#112](https://github.com/plx/hdxl-voice-processing/issues/112). Human task labels
remain provisional under [#102](https://github.com/plx/hdxl-voice-processing/issues/102).

No native-generated values or enlarged tolerances replace the independent
reference. Same-input power tolerance is 1e-10 absolute + 1e-11 relative; isolated
CPP/peak/background/intercept tolerance is 1e-8 dB, slope 1e-6 dB/s and quefrency
1e-12 s. Complete-PCM final CPPS uses 1e-4 dB, .01 dB/s and 1e-8 s budgets.
Counts, identities, status and indices are exact. The
[tooling guide](../../Tools/CPPS/README.md) defines the complete comparison policy.

Initial native isolated maximum consumed power-budget fraction was
**0.0006972308144491024**, and metric-budget fraction **0.00004773959005888173**.
The seventeen accepted complete-PCM cases consumed at most
**0.03116085238730193** of their final metric budgets. The unmasked dropout reached
**164.036032** times a final frame budget even though its whole-interval mean was
within budget; the report retains both observations. Raw unsmoothed full-PCM fits
are diagnostic here; their separately isolated strict gates remain in the CPP suite.

Reference manifest SHA-256:
`ff4afbbf0bdd1d24ee1de434947990a03f59fde58741ae7e928df2d00ab30577`.
Generator implementation SHA-256:
`7a148a68cdbe8afad21ddac4061341c447b2a6db9e7ddb0fec5eb113da73eb6b`.
Praat 7.0.02 is independently invoked with seed 7002; no reference binary/source is
redistributed. The provenance inventory includes 461 fixtures. Version-specific
pretrend and tolerance behavior is documented in
[#111](https://github.com/plx/hdxl-voice-processing/issues/111).

## Behavioral evidence

Tests compare whole/preview values across tiny and batch chunks, preserve explicit
short-tail unavailability, reject omitted input grids, prevent reentry and retain
borrowed buffers until callback return. Source discontinuities clear history.
Actual mask routing of three independent regions equals direct per-region PCM
analysis at the original large integer sample positions. Constructed matched
harmonic signals at 1x/0.25x amplitude differ by less than 1e-6 dB in CPPS; the
low-periodicity noise control is more than 5 dB lower. These are synthetic controls,
not calibrated intensity measurements or human phonation annotations.

Region-duration and equal-frame weighting have distinct identities and hand-derived
expected results. Rolling tests exercise expiry, missing acquisition, exclusion,
selection revision, unavailable latest frames, renewed-region freshness and union
coverage without double-counting overlapping support. Legitimate numerical zero
remains available. Diagnostic tests check numerical equality across modes, sampled
frame admission and balanced scopes ending before consumer callbacks.

Timing regressions preserve source/host anchors independently through disabled
and active smoothing, whole-interval and preview support, missing early anchors,
and sample positions above 2^54. Host rebasing retains exact integer anchors,
rounds fractional nanosecond offsets explicitly, and rejects clock underflow.

The full corpus remains enabled in debug, ordinary release, and optimized
address/thread sanitizer lanes. Required infrastructure follow-up
[#114](https://github.com/plx/hdxl-voice-processing/issues/114) added independent
optimized fault controls and accurate configuration metadata. The complete
pre-anchor-fix integration run (`7038a1fd1a`) passed 176 reported cases with each
sanitizer; its ThreadSanitizer PCM comparison took 2,119.459 seconds. This is a
development runtime observation, not a performance baseline. Final-head results
and both review paths are retained on PR #113.

## Initial host performance evidence

The [87-case protocol](../../Tools/CPPS/README.md#host-performance-matrix) measures
complete six-second PCM-to-CPPS plus rolling queries. Thirteen CI groups retain all
required hop/smoothing combinations, bounded 1–5 second windows, source precisions,
rates, whole/preview recipes, pretrend and optional diagnostic exports. Prepare and
Run are separate; timing and allocation use separately inspected binaries.

The initial local `h30-w1` group passed **12 timing rows / 24 metrics** and
**13 allocation rows / 91 metrics**. Each Run has ten measured operations after one
warmup. The six-second operation p99 was **811.384125–883.230041 ms** for 197 valid
frames, or **4.1187–4.4834 ms per frame amortized**. This is a throughput statistic,
not worst-case frame latency. P99 with ten samples is effectively the observed
maximum, not a population tail estimate. The recorded 256-sample-batch maximum
algorithmic delay was 66 ms; replay with 63-sample chunks reported 55.375 ms while
preserving exact values/counts. At a 30 ms hop all three requested time windows are
inactive under the pinned floor(width/step)>1 rule, which remains explicit in profile
identity and tests.

All **18 prepared heap histograms** in this initial group (six Runs × malloc
count/bytes/object count) have maximum zero. The positive control reports malloc
count 2, bytes 4,120, object allocations 1, frees 2, retains 2 and releases 3. ARC
traffic is reported without claiming it absent. Owned export rows elsewhere in the
matrix are explicitly permitted to allocate and their overhead is measured.

The 15 variant workloads also passed exact replay/count checks before measurement,
including 2,951 complete frames in each six-second whole-interval case and 2,122,281
exported scalars in each 591-frame owned-output case. Whole-interval scalar memory
ranges from 5,643,584 bytes (Double/16 kHz) to 19,795,264 bytes (Float/48 kHz),
excluding prepared input, record storage, opaque FFT tables and object overhead.
Smoothing and rolling storage remain bounded independently of duration.

Initial timing raw-distribution SHA-256:
`f7931abb1a801712c85aa8c23b63394303ded1003d3a468d0c33b05902a3ea44`.
Initial allocation raw-distribution SHA-256:
`1f2f636ded204da3517cb204b7538a89efdc6c6ad68d77c591c42f092f6f4955`.

Both raw and final fits use the pinned robust estimator: 261,121 slopes per fit at
513 bins. The configured 2 ms hop is therefore not an unconditional real-time
promise. Larger preview hops have distinct identities; no estimator or smoothing
definition is silently substituted to meet a deadline. Further matrix results and
reviewed-commit CI artifacts are linked from the implementing PR.
