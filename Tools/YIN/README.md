# Fixed-time YIN reference contract

Issue #38 uses the independent Python route assigned in
[`Tools/Reference/ROUTES.md`](../Reference/ROUTES.md). The named profile is
`hdxl-yin-fixed-time-2002-steps2to5`, version 1. Its mathematical source is
de Cheveigné and Kawahara, JASA 111(4), 2002,
[DOI 10.1121/1.1458024](https://doi.org/10.1121/1.1458024)
([primary paper mirror](https://www.ee.columbia.edu/~dpwe/papers/deChevK02-yin.pdf)).
The Python oracle and Swift implementation are original implementations of the
equations. Neither copies third-party implementation code. Python 3.14.8 and its
standard library are developer tools only.

This profile includes the paper's fixed integration difference, cumulative-mean
normalization, threshold selection and parabolic refinement. It omits step 6's
neighboring-time best-local-estimate search. It claims neither original-author,
Aubio nor librosa implementation compatibility. Decision [#117](https://github.com/plx/hdxl-voice-processing/issues/117)
records that distinction and future evaluation. The optional causal tracker is a
separate layer, not step 6 and not a change to the raw estimator.

## Budgets fixed before oracle generation and native implementation

For identical Float32 or Float64 input values promoted to Double, compare every
scaled difference sample with **2e-10 × integrationLength absolute + 1e-12 relative**,
every CMND sample and interpolated error with **1e-9 absolute**, refined periods
with **2e-6 samples absolute**, and F0 with **0.001 Hz absolute**. Indices, support,
counts, candidate classification, selection and availability are exact. These are
numerical-equivalence budgets, not voice-health thresholds or guarantees for
ill-conditioned acoustic ground truth. The oracle uses `math.fsum` on explicit
squared differences; optimized native linear correlation is a separate route.
Very small FFT differences are recomputed directly to avoid cancellation.
Before correlation, the FFT backend translates both operands by the compensated
mean of the reference integration window. This translation cancels algebraically
in every squared difference; it does not change the PCM, RMS, normalization peak
or scalar definition. It avoids recovering a tiny AC difference by subtracting
large DC energies. Original normalized samples remain available for direct
recomputation, and the cancellation bound scales with the translated amplitude.
The original numerical budgets apply to this optimization without relaxation.

Known stationary pure tones with at least eight samples per period must have
**10 cents maximum absolute error** and **at least 90% voiced coverage** of
fully observed frames away
from the exact configured frequency boundaries. Clean identifiable harmonic and
missing-fundamental cases must have **20 cents maximum absolute error**, no
gross/octave errors, and at least **90% voiced coverage** of fully observed frames.
Partial-tail counts and coverage including those tails are reported separately.
Tests intentionally
dominated by an upper harmonic are ambiguity characterizations, not included in
that clean identifiable subset. Boundary, transitions, modulated, irregular,
noisy, breathy and fricative cases retain all frames and their outcomes; they do
not get converted into clean-tone success claims.

Evaluation reports expected/potential frames, available and voiced coverage,
unavailable reasons, fine absolute cents error, gross error (>20% relative Hz),
and octave error (within 20% of half or twice the target, also a gross error)
separately. Fine errors are conditional on non-gross available estimates, with
their denominator reported. Unknown real-speech truth is explicitly unknown.
No-pitch fixtures report false voiced frames. There is no human-label accuracy
claim; annotated voice/device follow-ups remain #102 and #74.

## Version 1 geometry and selection

- Mono finite PCM, explicit integer sample rate, Float32 or Float64 input and
  Double arithmetic. No automatic conditioning, resampling, demeaning or window
  taper. Input magnitude is normalized by the observed frame's maximum absolute
  value solely to bound arithmetic; the difference diagnostics are sums of
  squared differences in those normalized units. CMND is scale invariant.
- The requested frequency range is continuous and inclusive. Let `a=fs/fmax`,
  `b=fs/fmin`, `lo=floor(a)` and `hi=ceil(b)`. Valid configurations have `a>=4`,
  `hi>=lo+1`, at least one integer lag in a...b, and integration length `W>=hi`.
  The maximum evaluated lag is
  `hi+1`, including the interpolation neighbor. Full observed support is
  **W+hi+1 samples**. Zero-padding is only an internal convolution operation;
  it never supplies observed signal or extra periods.
- A frame starts at `epochStart + frameIndex*hopLength`. Its support is the full
  half-open observed interval. Its displayed center is the support midpoint;
  earliest delivery requires half that support duration after the center.
  Hop is a positive integer no larger than the support. Partial final frames
  are unavailable with insufficientData, or explicitly discarded by policy.
- For lags 1 through hi+1, compute `d[k]=sum((x[j]-x[j+k])^2, j=0..<W)`.
  Set d[0]=0, CMND[0]=1, and `CMND[k]=k*d[k]/sum(d[1...k])`.
  A zero denominator yields 1, never a perfect-periodicity claim.
- A local minimum at integer k in lo...hi has `CMND[k]<CMND[k-1]` and
  `CMND[k]<=CMND[k+1]`: the first point of an exact plateau wins. Its normalized
  parabolic vertex ordinate determines threshold eligibility. Positive
  curvature and a vertex offset within one sample are required; otherwise use
  the center ordinate. Clamp a negative interpolated error to zero. Period is
  independently refined with the same three-point vertex formula on **d**,
  not on CMND. Invalid curvature/offset leaves the integer period unchanged.
- Retain every local candidate, including refined candidates outside the exact
  range. Add the discrete global minimum over ceil(a)...floor(b) if it is not
  already a local candidate. Ties choose the smaller lag. Candidates report
  integer and refined period, Hz, normalized error, local/global provenance,
  range membership and threshold eligibility. Preserve the unbounded interpolated
  period separately. Within **2e-6 samples** of either continuous range boundary,
  canonicalize the period to that boundary and flag the adjustment. This is the
  already-frozen period-equivalence allowance, not a frequency acceptance margin.
  Outside that numerical band, never clamp a period into the range. The FFT path
  directly recomputes candidate-neighbor differences near this band before the
  boundary decision. This amendment follows the independent oracle's exact-50-Hz
  roundoff finding, before any native implementation; preliminary candidates
  remain unpromoted evidence, not accepted goldens.
- Select the smallest-lag **in-range local** candidate whose interpolated error
  is strictly below the configured threshold (default 0.1). Otherwise select
  the in-range candidate with the lowest error, ties by smaller lag, as an
  **uncertain** fallback. Apart from the explicit numerical canonicalization,
  do not clamp F0 to a boundary. If interpolation moves
  every candidate outside the exact range, report unsupportedRange and preserve
  diagnostics. This explicitly includes exact-boundary interpolation bias.
- A frame RMS at or below the configured unit-peak silence threshold (default
  1e-7) is unvoiced/silence. A nonzero constant signal is unvoiced/lowConfidence.
  Other fallback estimates remain available with a lowConfidence warning.
  Periodicity is `max(0, 1-error)`, a bounded algorithm statistic, not a
  calibrated probability, speech detector or quality score.

Frequency limits, integration and hop counts, threshold, silence threshold,
input/arithmetic precision, difference backend, refinement/selection/support
conventions, numerical boundary tolerance and tail policy participate in the
estimator's serialized identity.
No pitch result gates CPP/CPPS; callers retain their PCM and other measurements.

## Optional causal candidate continuity

The separately serialized tracker receives the complete raw candidate set.
On the first voiced frame, or after an uncertain/unavailable frame or a gap,
select the raw estimate. Otherwise score eligible in-range threshold-qualified
local candidates by `error + continuityWeight * abs(log2(Hz/previousHz))`.
The default weight is 0.05. Ties choose the smaller lag. The selected candidate
must still satisfy the estimator's threshold/range rules; tracking never fills
an unvoiced gap or invents a candidate. A changed choice is explicit and raw
selection remains available. The tracker adds no lookahead. Its dependency
interval extends back to the start of the current continuous voiced run, while
the raw frame retains its narrower actual support. Profile and tracker identity
are both retained. This is a causal continuity preference, not a calibrated
Viterbi model or a claim to correct octave ambiguity.

## Reproduction and performance

Generate candidates explicitly under `.build`; promotion and inventory updates
are separate reviewed actions. Goldens retain generator/input/profile hashes,
all difference/CMND values and candidates. Swift output never supplies expected
values. Closed-form and hand-enumerated anchors test the oracle itself.

Benchmarks cover 50–700 Hz and 25–2000 Hz at 16/44.1/48 kHz, 5/10 ms requested
hops (explicit nearest integer sample count), scalar/optimized backends, tracking
off/on, low-F0 full support, and long silence/noise. Prepared execution is
separate from construction and owned export. Retain hardware, toolchain,
precision, support/hop, input duration, counters, allocation and timing
distributions; amortized frame cost is not worst-case delivery latency.
Register results under #25 and the bounded Pitch stage instrumentation under #18.

```sh
python3 Tools/YIN/reference.py --output .build/yin-candidates
python3 Tools/YIN/verify.py .build/yin-candidates
python3 Tools/YIN/verify.py
python3 -m unittest discover -s Tools/Tests -p 'test_yin_reference.py'
```

The initial retained catalog has 54 cases and 484 frames (430 fully observed,
54 explicit partial tails). Three cases use bounded excerpts of the already
licensed PVQD corpus; their numerical references are not human pitch labels.
Original synthetic PCM is lossless Float64 WAV, including explicitly rounded
Float32 input cases. `manifest.json` retains raw and tracked evaluation summaries;
the global fixture inventory records every artifact and inherited attribution.

Local review cycle 1 expanded this to **73 cases and 663 frames** (590 complete,
73 partial), adding DC-offset tones, noise and noisy tones at intermediate AC/DC
ratios, negative-offset Float32 inputs, 48 kHz variants and a near-threshold
classification regression. All prior numerical values and inputs are unchanged;
their generator identity changes to include the expanded catalog. The new cases
use the same independently computed differences/CMND/candidates and fixed budgets.

Local review cycle 2 expanded the catalog to **77 cases and 671 frames** (594
complete, 77 partial). Four quantized inputs cover a nonadjacent global-minimum
tie, its Float32 equivalent, and positive/negative perturbations. The global
minimum can introduce a nonlocal boundary candidate, so its strict comparison
must also trigger direct recomputation when FFT results are ambiguous. Near ties
are not rounded into exact ties. All existing input bytes and numerical reference
outputs remain unchanged, with the expanded generator identity recorded.

## Benchmark matrix and evidence gates

`Benchmarks` remains an isolated development package. Its `YINBenchmarks` target
uses the existing pinned benchmark framework; core gains no dependency.
`YINWorkloadCheck` verifies every emitted frame/status denominator, repeated-run
and chunk invariance, actual support/delay, identities, input hashes, workspace,
scalar-fallback counters and owned-export volume before measurement.

The 82 configurations are divided into eight disjoint shards:

| Shard | Cases | Input and configuration |
| --- | ---: | --- |
| `rate16000`, `rate44100`, `rate48000` | 16 each | Two seconds of 125 Hz harmonics; Float64; both ranges, both requested hops, both backends, tracker off/on |
| `float32` | 16 | Same complete matrix at 48 kHz with Float32 input and Double arithmetic |
| `support` | 8 | Six two-second pure 25 Hz cases at all three rates/backends, 25–2000 Hz, 5 ms requested hop, tracking; two maximum-geometry cases at 192 kHz, 20–2000 Hz, W=16384, N=25985, 10 ms hop, both backends, tracking, four complete frames plus actual partial tail |
| `long-scalar`, `long-fft` | 4 each | Thirty seconds of silence and seeded noise at 48 kHz, 25–2000 Hz, 5 ms hop, tracking off/on |
| `export` | 2 | Two-second harmonic pipeline at 48 kHz, 50–700 Hz, 10 ms hop, FFT, tracking; Float32/Float64, copying all candidates/curves and serializing raw/tracked scalar results |

The low-floor cases characterize exact-boundary availability; they are not a
promise to voice every boundary frame. The maximum case exercises the largest
accepted integration length and lag support, beyond the requested speaking-range
matrix. The long cases check sustained empty/uncertain results without duration-
growing analysis or tracker storage. Their PCM is generated before measurement.

Each configuration has a `Prepare` operation (construct/destroy its worker) and a
`Run` operation (reset, consume all prepared PCM in 256-sample chunks, finalize,
and consume outputs). Export rows additionally copy and serialize; their timing
includes DSP and must not be called isolated serialization time. All encoded bytes
are consumed. The checker separately replays 137-sample chunks. Run checksum and
status comparisons exclude epoch-dependent JSON bytes, while export byte counts
and checksums remain observable evidence. Every run uses a fresh continuity epoch.

Prepare/control uses three warmups and up to 30 measured observations; Run uses
one warmup and 10 observations. Validation requires at least 10 samples for every
metric. A p99 from 10 samples is effectively their maximum, not a stable estimate
of a population tail. Timing and allocation binaries are separate, locked builds.
All non-export prepared Run heap-allocation maxima must be zero. The allocation
lane also requires positive malloc/object/ARC controls, so absent instrumentation
cannot pass as zero allocation. Owned export allocates explicitly. Diagnostics are
disabled for these measurements.

```sh
python3 Tools/YIN/benchmark.py timing --shard rate16000
python3 Tools/YIN/benchmark.py allocation --shard rate16000
# Repeat for rate44100, rate48000, float32, support, long-scalar, long-fft, export.
```

The wrapper records hardware/toolchain/commit, exact profiles and their hashes,
input bytes, support/hop/precision, prepared scalar/candidate/framer storage,
raw histograms, p99 exports, sample counts/maxima and allocation controls under
`Benchmarks/.build/artifacts/yin-<mode>-<shard>/`. Object bookkeeping and opaque
FFT setup tables are excluded from the reported prepared-buffer bytes; measured
heap counters cover their construction. Full-batch duration divided by frame
count is amortized cost, not worst individual-frame delivery latency. The tracked
history midpoint has a separate dependency delay despite zero added lookahead.
Host throughput is not a physical-device deadline or microphone-latency claim.
