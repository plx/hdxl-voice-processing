# A09 YIN evidence

Implementation begins from main `599d11a2cd987f41016e0b2a4db1b249fe292416`.
The profile and numerical budgets were committed before the independent oracle
and native implementation. Boundary canonicalization was clarified from preliminary
oracle roundoff before any Swift estimator existed; no native result supplied a
golden or enlarged a tolerance. The [reference contract](../../Tools/YIN/README.md)
and [decision #117](https://github.com/plx/hdxl-voice-processing/issues/117) distinguish
this fixed-time steps 2–5 profile from the original paper's neighboring-time step 6.

## Independent numerical and streaming comparisons

The initial catalog had 54 cases, 430 complete frames and 54 explicit partial
tails. Its 106 artifacts comprise 51 original synthetic Float64 WAVs, 54 reference
JSON files and a manifest. Three cases read existing licensed PVQD excerpts;
their references inherit the source attribution and do not supply human pitch
labels. Two cases explicitly round input to Float32 before Double computation.
At that point the complete provenance inventory contained 567 fixtures.

The independent Python oracle uses `math.fsum` on explicit squared differences.
Swift uses compensated scalar sums or FFT linear correlation with cancellation
recomputation. Each backend compares 484 frames, 195,048 difference cells and
14,994 candidate records, including every CMND cell, selection flag and status.
Both also compare all 484 tracker outcomes, then replay all frames through the
streaming PCM API with irregular chunks. Streaming matches every raw and tracked
field, candidate and curve from the independent comparisons.

Initial maximum fractions of the precommitted budgets:

| Backend | Difference | CMND/error/periodicity | Refined period | Hz |
| --- | ---: | ---: | ---: | ---: |
| Scalar | 1.76184e-6 | 8.88178e-7 | 1.42109e-8 | 5.68434e-11 |
| FFT | 5.86407e-6 | 0.0308258 | 1.78488e-5 | 1.13687e-9 |

A fraction ≤1 passes. Candidate indices/flags, support, selections and status
are exact. FFT directly recomputed 6,243 lags in this catalog. A separate
closed-form impulse/flat-CMND test exercises a complete scalar fallback.
The optional tracker changes one catalog selection per backend, with raw output
preserved and the full continuous voiced dependency interval retained.

Manifest SHA-256:
`a0c0477c220776f90ca5ad7ed7c9d26c10b31710aadb3826d025856573f30dd7`.
Oracle implementation SHA-256:
`ff8b4ff1d13de07c35f098b98352138d19d1ab73c4b92252935c10f174dd2265`.
`reference-regeneration.yml` regenerates independently, checks the manifest,
then requires the expanded 154 native comparisons with 1,342 raw, tracked and
streamed frames described below.

## Applicability and denominators

The clean tone and identifiable harmonic fixtures pass their original 10/20-cent
and ≥90% complete-frame voiced-coverage budgets. Difficult cases remain in the
manifest, including rejected and uncertain numeric results. Representative raw
outcomes below include one additional partial tail per case:

| Case | Full frames | Available | Voiced | Gross / octave errors | Fine-error denominator; maximum cents |
| --- | ---: | ---: | ---: | ---: | --- |
| Missing fundamental | 8 | 8 | 8 | 0 / 0 | 8; 0.0434 |
| Dominant second harmonic | 8 | 8 | 8 | 8 / 8 | 0; unavailable |
| Chirp | 14 | 14 | 14 | 0 / 0 | 14; 54.127 |
| Vibrato | 14 | 14 | 14 | 0 / 0 | 14; 51.070 |
| Octave jump | 14 | 14 | 12 | 2 / 2 | 12; 0.0288 |
| Synthetic breathy | 14 | 14 | 0 | 3 / 3 | 11; 304.589 |
| 0 dB SNR | 8 | 8 | 0 | 3 / 3 | 5; 39.411 |

Gross error is >20% relative Hz; octave errors are a separately reported subset.
Fine error is conditional on available non-gross estimates, never all frames.
An 8/8 complete-frame result is 8/9 when the unavailable tail is included.
Noise/fricative controls retain uncertain fallback frequencies but have zero
false-voiced frames. They have no target frequency, so fine error is undefined.
Real speech has unknown target truth. This is algorithm characterization, not
human-annotated performance, calibrated probability or a voice-health score.
Human evidence remains [#102](https://github.com/plx/hdxl-voice-processing/issues/102).

## Lifecycle, timing and ownership

Tests cover both source precisions, both backends, tracking off/on, three source
rates and both frequency ranges. Batch and irregular chunks preserve all fields.
Explicit gaps discard pending PCM and candidate history. Invalid chunks, clocks,
precision changes and skipped tracker grids leave state unchanged. Reentrancy is
rejected; cancellation inside full and partial callbacks preserves the current
borrow and stops later output. Ordinary reset reuses storage; reconfiguration
prepares before replacing it. Owned exports survive a later complete scratch
overwrite. Source positions near Int64.max use integer differences before clock
conversion; source and host anchors survive through raw and tracked outputs.

Tracker history timing is deliberately wider than raw current-frame timing.
Its delay is measured from the earlier dependency midpoint, with zero additional
lookahead. Hand-enumerated candidate paths check selection changes, uncertainty
resets and shared-result persistence. Bounded diagnostics tests verify sampled
and detailed Pitch/PitchTracking spans, FFT nesting, full/partial metadata,
balanced endings before consumers, reset epochs and callback cancellation.

## Initial host workload evidence

The [82-case matrix](../../Tools/YIN/README.md#benchmark-matrix-and-evidence-gates)
covers both requested ranges, 16/44.1/48 kHz, 5/10 ms requested hops, scalar/FFT,
tracking off/on, Float32 variants, low-floor tones, maximum supported geometry,
30-second silence/noise, and optional owned export. Its first release correctness
run passed 69,200 complete frames and 82 explicit partial tails with 256- versus
137-sample chunk replay. At the maximum 192 kHz/20 Hz/W=16384 geometry, two of four
full frames have unsupported range after interpolation; both backends retain that
outcome rather than widening the configured frequency range. All six 25 Hz
low-floor cases voice their 384 complete frames. Maximum owned buffer storage is
4,477,864 bytes, excluding input, object bookkeeping and opaque FFT setup tables.

Initial timing/allocation evidence was collected from clean commit
`e4ca508ad7a4322d095499b2be728e0e1f289f58` on 2026-11-05 UTC, Mac13,1 arm64,
macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4, Python 3.14.8.
The 16 kHz shard passes 32 timing rows / 64 metrics and 33 allocation rows /
231 metrics. For the two-second PCM Run operations, observed p99 is
33.210333–222.835459 ms for scalar and 10.959500–40.691417 ms for FFT across the
two ranges, hops and tracking choices. These are whole-batch processing times;
they are not single-frame or capture latency. Ten measured operations follow one
warmup: p99 is effectively the sample maximum, not a stable population-tail estimate.

All 48 prepared-run heap histograms (16 runs × malloc count/bytes/object count)
have zero maximum. The control records two mallocs, 4,120 bytes, one object,
two frees, two retains and three releases. ARC traffic is reported rather than
claimed absent. Owned exports are separately permitted to allocate. Timing uses
a separate binary with no allocator interposer; linkage is inspected in both modes.
The remaining matrix and final integration/review receipts belong to the implementing
PR. Physical-device, thermal and microphone latency evidence remains
[#74](https://github.com/plx/hdxl-voice-processing/issues/74).

Initial timing raw-distribution SHA-256:
`04f607c71bdb48909e8ab0fcad9917dd55ff2560a21091e59574e1c73beeee31`.
Initial allocation raw-distribution SHA-256:
`8322df7a8e5c236e6c15b0a34ff5ac236caf6bd5a65cd6fa912fe7aac23cd148`.

## First review: DC cancellation regression

GitHub's first review of `fa8dd74` was clean. The local `codex review` cross-check
found that the absolute FFT recomputation cutoff could retain small cancellation
errors for a tiny signal on a large DC offset; CMND normalization amplified them.
Independent regression fixtures reproduced 32 failed assertions on the old code,
including candidate threshold status and the downstream tracker history. Fifteen
FFT rows exceeded the original numerical budgets. The existing extremely small
1e-12 near-DC case had directly recomputed every lag and did not expose this gap.

The fix translates both FFT operands by the compensated reference-window mean,
whose contribution cancels algebraically from every difference. Original samples
remain available for direct recomputation; its bound now scales with the translated
amplitude. This reuses prepared scratch and changes neither scalar equations,
profile settings nor tolerances. It does not filter or alter the caller's PCM.

Nineteen new independent cases cover tones, noise and noisy tones at AC amplitudes
1e-3/1e-4/1e-5/1e-6 on DC 0.5, negative-offset Float32 variants, 48 kHz variants,
and a threshold-boundary case. All old numerical outputs, input bytes, profiles
and metrics were verified unchanged before promoting the expanded catalog.
The first-review catalog has **73 cases / 663 frames**, comprising 590 complete frames
and 73 partial tails, with 144 artifacts and 605 total provenance entries.

All 13 YIN Swift tests pass after the fix. Each backend now compares 261,928
difference cells and 21,745 candidates, plus all 663 raw/tracked/streamed frames.
Maximum FFT budget fractions are difference 5.29658e-6, CMND 0.0308258, period
2.96723e-5 and Hz 2.27374e-9. Every exact status/index/flag/support check passes.
FFT recomputes 5,187 lags and takes one full scalar fallback in this expanded
catalog. Both backends report six changed tracker selections. Eleven independent
oracle tests pass, including explicit no-pitch denominators and the new uncertain
threshold case. Initial performance results above predate this arithmetic fix;
the implementing PR retains subsequent performance and integration evidence.

First-review manifest SHA-256:
`41c4b2af7ca9312f2ea6dc2f93144eb4fe0d9bdb05520d548d1caf567b71fe8d`.
First-review oracle implementation SHA-256:
`8c902297e2babc933f06cb1a26a2e2e5e22bf0e4a610f883d17afd127f36f05f`.


## Second review: nonadjacent global minima

GitHub's second review of `bcdf752` was clean. The local cross-check found that
nonadjacent tied global minima could round differently under FFT, changing both
the global flag and the candidate set. The sparse 81-sample quantized regression
has exact CMND values of 7/8 at lags 4 and 7; lag 4 is retained only as the global
fallback. The old implementation chose lag 7 and omitted lag 4. A focused test
reproduced four failed assertions before the fix.

The ambiguity guard now compares the two smallest CMND values across the full
integer global-search range, in addition to its local and threshold checks.
Ambiguity triggers the existing counted full scalar recomputation before strict
selection. It adds no prepared buffer or output allocation, and changes no
profile, tie rule or numerical budget. This can increase fallback work, which
remains visible in execution statistics and the performance matrix.

Four new independently generated inputs retain the exact tie in Double and
Float32 and perturb it in both directions. They explicitly have no known pitch
label. All preceding PCM bytes, numerical values, profiles and metrics were
verified unchanged before promotion. The catalog now has **77 cases / 671
frames**, with 594 complete frames and 77 partial tails, 152 YIN artifacts and
613 total provenance records. Each backend compares 262,096 difference cells and
21,760 candidates, with every raw, tracked and streamed output checked. The
maximum numerical budget fractions are unchanged from the first-review fix.
The expanded FFT catalog directly recomputes 5,223 lags and takes 11 complete
scalar fallbacks: eight boundary-700 frames, one threshold frame and the two
exact quantized ties. Both perturbed cases retain strict ordering.

Current manifest SHA-256:
`1a55146753a64a4477f9a8f8dffbc6e3adb21a65e6fb162265d2a4549a9b7b4e`.
Current oracle implementation SHA-256:
`33672817b7addf110245e747a0b3caf8958511f76094133df349ce2161288362`.
