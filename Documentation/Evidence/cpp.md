# A06 CPP evidence

Implementation based on main `912d7fbf6f854734940924b33b7480a14d67d60a`.
Initial numerical and kernel measurements were collected 2026-11-05 UTC on Mac13,1,
arm64, macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4 and Python 3.14.8. Physical
capture/device/thermal evidence remains [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
Exact estimator and reference-defect decisions are recorded in
[#107](https://github.com/plx/hdxl-voice-processing/issues/107).

## Independent numerical evidence

The reference family contains 216 cases plus its manifest: 19 constructed power
cepstra and all 197 selected upstream external frames. Fourteen unavailable frames
stay unavailable. The 202 usable inputs supply 1,414 profile comparisons and 2,222
external trials, including three external seeds for complete Theil. Forty speech
frames retain their source attribution; no new human recordings were collected.
The provenance inventory now covers 369 fixtures.

Pinned Praat 7.0.02 supplies peaks, least-squares fits and its exact `Robust` estimator.
Independent Python supplies the complete all-pair Theil median and residual checks.
Hand-derived small examples distinguish complete Siegel from the pinned first-n−1
variant. All native estimators are deterministic. Explicit exceptions preserve
32 constructed profile rows where Praat's randomized Theil selector is incompatible;
ordinary reference rows must still match every recorded seed. Neither native output
nor widened error budgets supplies a replacement golden.

Generator implementation SHA-256:
`8cde6e9e3945d0c75f5c6fb75d8c85a8e9a9ba80604353b835951fcec13b2bfc`.
Reference manifest SHA-256:
`3867b4acb558ce129b1705f4cfacb29bb4aa4a23471908c00f1a4f87432396df`.
A fresh candidate reproduced the committed manifest exactly and passed independent
offline verification. The [tooling guide](../../Tools/CPP/README.md) records trial
identities, bounded exception policy and frozen tolerances.

All 1,414 isolated comparisons passed. The largest consumed budget fraction was
**0.00018189894035458565**. Mathematical Theil matched its independent oracle exactly
on this host. Separate full-PCM comparisons passed for all 40 speech frames, checking
CPP, peak, background, slope/intercept, peak quefrency and four residual diagnostics.
Their largest consumed budget fraction was **0.05227198244028841**. These observations
are matrix-specific, not guarantees for arbitrary or ill-conditioned PCM.

Additional tests cover analytic lines/peaks/ties, finite floors, all four estimators,
invalid buffers/configuration/serialization, unsupported and insufficient support,
profile mismatch, borrowed ownership, explicit export budgets, reentry, raw zero
power versus silent PCM, low-periodicity PCM without an F0 gate, Float/Double chunk
equivalence, discontinuity reset, cancellation and balanced diagnostic spans.

## Initial isolated host measurements

All 53 workloads in the kernel group passed: **106 timing rows / 212 metric
distributions**, and **107 allocation rows / 749 metric distributions**. Each has
30 samples after three warmups. Binary inspection verifies that timing omits
allocator interposition and allocation mode uses the pinned interposer.

Selected 513-bin parabolic fit/search p99 values follow, in milliseconds for one
complete prepared call. This is already power-cepstral input, not a PCM pipeline.
Both patterns use 512 fit points; dense inputs add competing ripple peaks.

| Fit | Sparse ms | Dense ms |
| --- | ---: | ---: |
| Least squares | 0.007458 | 0.008167 |
| Pinned Praat robust | 1.920250 | 2.354875 |
| Complete Siegel | 1.901375 | 2.421125 |
| Complete Theil–Sen | 1.226625 | 1.206292 |

The pinned robust fit evaluates 261,121 slopes at this geometry. Its host cost can
exceed a 2 ms hop even before conditioning and FFT work. The accepted configuration
range is therefore not a promise that every recipe meets every real-time deadline.
Complete estimators retain their definitions; a cheaper fit or hop is an explicit
profile choice. Physical measurements and any resulting adjustment remain #74.

All **156 prepared heap histograms** in this group (52 non-export Runs × malloc
count/bytes/object count) have maximum zero. The explicit owned-diagnostics case
may allocate. The positive-control maxima are malloc count 2, bytes 4,120, frees 2,
object allocations 1, retains 2 and releases 3. ARC counters are reported without
claiming that prepared processing performs no retains/releases.

Kernel timing raw-distribution SHA-256:
`0ceaaa2af8ffe70a6b10c38d0e46cf97cc19936ba0a43f8ac524eda4894831c2`.
Kernel allocation raw-distribution SHA-256:
`48000f7187128d6b4467115314dc542d494adf5e548dace1edd3b9075f18b7ba`.

## Complete-pipeline protocol

The [77-workload matrix](../../Tools/CPP/README.md#host-performance-matrix) also
measures actual PCM-to-CPP processing for both source precisions, 16/48 kHz input,
1/60-second durations and whole-input 2 ms / preview 5/10 ms hops. Four separate
pipeline groups preserve the full workloads while bounding CI job duration.
Preparation/destruction, conversion and explicit export remain separately reported.

Each 60-second Run uses one warmup and ten measured complete operations. Other
measurements use three warmups and thirty operations. Every retained distribution
must have at least ten samples. A ten-sample p99 is effectively the sample maximum,
not a stable estimate of a population tail. Complete-batch throughput does not
measure individual capture deadlines or remove whole-input finalization delay.

The five-group CI workflow retains complete pipeline distributions, counts,
workspaces and allocation evidence. The pull request closing #35 records the
final run identities, numerical/local/hosted verification and artifact audit.
The kernel measurements above describe only their stated workloads; use the
complete-pipeline artifacts for source-input throughput and allocation results.
