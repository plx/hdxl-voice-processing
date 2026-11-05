# A09 YIN evidence

Implementation begins from main `599d11a2cd987f41016e0b2a4db1b249fe292416`.
The profile and numerical budgets were committed before the independent oracle
and native implementation. Boundary canonicalization was clarified from preliminary
oracle roundoff before any Swift estimator existed; no native result supplied a
golden or enlarged a tolerance. The [reference contract](../../Tools/YIN/README.md)
and [decision #117](https://github.com/plx/hdxl-voice-processing/issues/117) distinguish
this fixed-time steps 2–5 profile from the original paper's neighboring-time step 6.

## Independent numerical and streaming comparisons

The retained catalog has 54 cases, 430 complete frames and 54 explicit partial
tails. Its 106 artifacts comprise 51 original synthetic Float64 WAVs, 54 reference
JSON files and a manifest. Three cases read existing licensed PVQD excerpts;
their references inherit the source attribution and do not supply human pitch
labels. Two cases explicitly round input to Float32 before Double computation.
The complete provenance inventory contains 567 fixtures.

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
then requires 108 native comparisons with 968 raw, tracked and streamed frames.

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
