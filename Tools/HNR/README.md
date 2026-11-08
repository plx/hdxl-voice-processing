# Independent HNR reference contract

Issue #39 supplies two distinct methods: accurate autocorrelation (AC) and forward
cross-correlation (CC). This contract is established before the native analyzers.
The reference executable is the existing pinned **Praat 7.0.02**, source revision
`6f3da9ef1d8cce0d5684afc104d02888dfc71b25`, with its exact binary hash and Python
3.14.8 environment in [the tool lock](../Reference/toolchain.json). Reference
programs and upstream implementation code are not part of the Swift package.

The method basis is [Boersma (1993)](https://www.fon.hum.uva.nl/paul/papers/Proceedings_1993.pdf),
particularly normalized/window-corrected correlation and tapered sinc peak
interpolation. The current [AC](https://praat.org/manual/Sound__To_Harmonicity__ac____.html)
and [CC](https://praat.org/manual/Sound__To_Harmonicity__cc____.html) commands have
different support and estimators. This is a current pinned recipe, not a claim of
historical-binary parity or identical HNR across methods. Implement the mathematics
independently; the [source-reuse policy](../../Documentation/ProvenancePolicy.md)
applies to all upstream code.

## Conventions that must remain visible

Let `fs` be the input rate, `fmin` the pitch floor, `P` the periods parameter, and
`dx = 1/fs`. The native implementation must preserve all profile settings and
distinguish input precision from Double calculation precision.

- AC uses an effective duration `P/fmin` and a physical Gaussian duration
  `2P/fmin`. CC compares rectangular sequences of duration `P/fmin`, allowing
  forward lags through approximately one longest period.
- The even comparison length is `N = 2 * (floor(windowDuration/dx)/2 - 1)`, where
  the inner division is integer division. With zero-based `j`, the AC window is
  `(exp(-12*((2*j+1-N)/(N+1))^2)-exp(-12))/(1-exp(-12))`. Its coordinate convention
  differs from the existing power-cepstrum window; substituting that window would
  silently change the profile.
- Local mean removal uses two longest periods around the frame center. The
  silence statistic uses a centered approximately one-period absolute peak,
  windowed in AC. Whole-interval peak normalization uses the maximum absolute
  sample after removing the whole-interval mean. It therefore has an offline
  dependency on the whole selected contiguous recording.
- AC divides the normalized correlation of the windowed signal by the normalized
  correlation of the window. CC divides the inner product of each fixed-length
  forward pair by the geometric mean of their energies. No YIN result or
  externally supplied F0 is required.
- Candidate search considers positive local maxima beginning at integer lag two,
  with a Nyquist ceiling and a floor-dependent upper lag. The reference candidate
  capacity is the larger of 15 and `floor((fs/2)/fmin)`, including the unvoiced
  candidate. Preliminary parabolic positions use depth-30 sinc strengths for
  retention; retained candidates use depth-700 sinc maximization.
- The pinned interpolation kernel uses a symmetric raised cosine with denominator
  **depth + 0.5**. The 1993 paper's side-dependent taper is not the same convention.
  Available samples bound depth independently on both sides. Correlation is even
  in lag. CC's uncomputed correlation tail is zero in the bounded interpolation
  domain; acquired forward support at interval boundaries must be retained.
- An estimated peak above one is reflected by `r -> 1/r`, as described by the
  method. The unreflected peak, reflection and final periodicity remain distinct
  diagnostics. Strongest periodicity competes with an unvoiced strength
  `max(0, 2 - localIntensity/silenceThreshold)`; a zero threshold disables this
  relative-silence competitor. This is not simply a hard amplitude cutoff.
- HNR is `10*log10(r/(1-r))`. Praat reports -150 dB for `r <= 1e-15`, +150 dB for
  `r > 1-1e-15`, and a -200 sentinel for an unvoiced frame. The protocol preserves
  raw output and separately labels unavailable and reporting-limit states.
  Neither +150 nor a floating-point `r == 1` establishes physical absence of noise.
- The grid fits complete nominal support symmetrically inside the whole input.
  AC uses nominal support `2P/fmin`; CC uses `(P+1)/fmin`. Frame count and center
  calculations retain the pinned binary64 operation order without an added epsilon.
  After computing the first center, frame `i` uses fused `first + i*hop`, with
  zero-based `i`. Sample mapping uses `floor(1 + (time - dx/2)/dx)`. Fusing the
  timestamp step matters: at 44.1 kHz, a nominal 0.185-second center can otherwise
  select the previous sample. The protocol verifies the exact external grid.
  Actual contributing sample indices and nominal center are separate metadata.
  No edge zeros become observed samples. Five milliseconds at 44.1 kHz is not an
  integer sample hop.

Raw candidates, selected outcomes, silence/exclusion and coverage must remain
separately inspectable. Native causal processing must use a separately identified
normalization/grid policy; an unknown future global maximum cannot be inferred.
Masks and acquisition gaps cannot be implemented by concatenating accepted PCM.
Window/profile choice, filtering, jitter and bandwidth affect HNR. The value is
not a universal health, pleasantness or physical-SNR score.

## Catalog and comparison policy

`catalog.py` currently defines 180 cases: 90 AC and 90 CC. Forty-six cases round
input to Float32 before lossless Float64 WAVE transport; all others retain Double
input. Both methods see exactly the same PCM for a paired case. The catalog covers:

- Low/high tones, harmonic/missing-fundamental signals, controlled noise, a stable
  all-pole filter with an unchanged source, clipping, transitions, amplitude steps,
  impulse, alternating samples, silence and DC.
- Polarity inversion, gain and constant offset, preserving actual rounded PCM.
- Five additional impulse gains per method preserve the external tool's numerical
  instability on an analytically flat correlation curve (see below).
- The full 48-configuration matrix of two methods × 16/44.1/48 kHz × 4.5/6 periods
  × 60/75 Hz floors × 5/10 ms hops.
- Exact-duration and fractional-grid boundaries, and 16 half-second excerpts from
  the separately licensed corpus at its original 44.1 kHz rate. No silent resampling
  or private voice recording is introduced.

`contract.py` freezes numerical comparison separately from reference regeneration.
Counts, indices, availability and limit states are exact; source-time axes allow
1e-12 seconds. Moderate values (absolute HNR at most 60 dB) allow 1e-4 dB. Outside
that range, the small periodic/noise energy fraction is compared with absolute
2e-14 plus relative 1e-4 error. This avoids demanding stable decimal digits from an
ill-conditioned logarithm near zero noise; high-HNR dB differences must still be
reported. A limit state cannot pass as an ordinary finite estimate.

These are numerical engineering tolerances, not clinical equivalence margins. The
absolute extreme-fraction allowance covers accumulated binary64 transform/dot and
peak-refinement roundoff; its relative term bounds uncertainty in the small energy
fraction. An independent direct-sum probe of the committed periodic saw agreed
with CC to approximately 8e-9 dB and AC periodicity to machine precision; at ~114 dB
the latter still differed by ~0.00024 dB. Future out-of-budget differences require
diagnosis and a documented convention change, not silent golden regeneration.

## Resolved peaks and a documented reference disagreement

The native profile uses `positiveLocalMaximumCurvature128Binary64Ulps-v1` from
`contract.py`. A positive local maximum must have
`(middle-left)+(middle-right) > 128*ulp(1)` (approximately 2.84e-14). Smaller
curvature is retained as a numerical rejection, not promoted into a periodicity
estimate. This is an explicit native resolution policy, not part of Praat's
candidate test or a new agreement tolerance. It rejects curvature at the scale
of accumulated binary64 correlation roundoff while preserving ordinary maxima,
including a legitimate two-sample tie. It is an engineering resolution floor,
not a universal error bound for all possible inputs.

A single impulse demonstrates why this distinction matters. Let its amplitude
be `A`, the local-mean length `K`, and the CC comparison length `N`. If the local
mean and both comparison windows contain that impulse, every positive-lag pair
has dot product `A²(N-2K)/K²` and both energies equal
`A²(K²-2K+N)/K²`. The normalized curve is therefore the constant
`(N-2K)/(K²-2K+N)`, independent of nonzero amplitude. There is no strict peak.
For the default middle frame, `K=426`, `N=958`, and the exact ratio is `106/181582`.
Nevertheless, the pinned binary reports approximately -12.8266 dB at amplitude
0.75, no result after gain 0.1, -27.4263 dB after gain 0.01, and -22.1028 dB after
gain 0.3. All raw outputs remain in the catalog; none becomes a native golden.

`degeneracy.py` proves the single nonzero input, complete lag support, local mean
and rational correlation before classifying a disagreement. It rejects a second
impulse, altered curve, missing support, or a selected native candidate. This is
not an exception keyed by fixture name. The equation audit reports ordinary
agreements, these documented disagreements, and unexplained failures separately;
a report with disagreements is **qualified**, never an unqualified parity pass.
The native result for this flat curve is unavailable, with inspectable numerical
diagnostics and coverage. See owner-attention issue #149.

## Reproduction and validation

```sh
python3 Tools/Reference/setup.py
python3 Tools/HNR/reference.py --output .build/hnr-candidate
python3 Tools/HNR/verify.py --directory .build/hnr-candidate
python3 Tools/HNR/check_equations.py --directory .build/hnr-candidate --output .build/hnr-equations
python3 Tools/HNR/stages.py --reference-directory .build/hnr-candidate --directory .build/hnr-stages
```

Generation requires an absent candidate directory under `.build`. An optional
repeated `--case` selects a diagnostic subset; its manifest is explicitly partial
and cannot satisfy the full verifier without `--allow-partial`. The strict protocol
checks complete ordered frames, input/settings, units, timestamps, finite numbers,
sentinels, limits and the arithmetic mean of available reference dB values. Input
bytes, normalized sample bytes, raw output, generator and tool identities are retained.
Execution timings include external process startup, file reading and export; they
are not native algorithm benchmarks.

The independent equation audit uses direct compensated sums and bounded
golden-section refinement, with closed-form correlation/interpolation anchors.
It compares the first, middle and last distinct complete frame of every case and
retains every outcome. It does not substitute native outputs for expected values.
`stages.py` separately retains 16 middle-frame anchors with every windowed sample,
correlation cell, candidate and selected outcome, including the fused-grid boundary,
two analytically flat impulse cases, Float32 input, low F0, all requested rates and
licensed speech. Its `--verify` mode recomputes those independent equations and
checks exact bytes and source identities. External observations and native numerical
resolution decisions are separate fields.

The offline verifier recreates source bytes and the typed record from retained raw
output. It checks silence/DC unavailability, polarity/gain/offset invariants and
controlled-noise trends. Float32 gain/offset operations alter the actual waveform;
their high-HNR changes are retained without pretending exact invariance or changing
same-input native tolerances. Reference fixture promotion/provenance registration,
independent scalar-stage anchors, native conformance and performance evidence are
required before this issue is complete.

The pre-native checkpoint retains 4,113 external frames (3,476 available, including
42 reporting limits), 16 complete stage anchors and 559 registered artifacts.
Fifty speech-derived artifacts retain CC BY 4.0 terms; the remaining original
artifacts inherit the project's pending license decision. The first/middle/last
equation audit has 532 comparisons: 526 agreements, six algebraically proved
single-impulse disagreements and zero unexplained failures. The largest comparable
error uses 0.513 of its declared budget. Twelve gain/polarity/offset invariant pairs
and all four controlled-noise trends pass. These are reference/equation results;
they do not establish native conformance or completion of #39.

## Separately identified causal windows

`streaming.py` generates original finite-window references without executing the
native library or claiming external whole-recording parity. Twelve cases cover AC
and CC, 16/44.1/48 kHz and Float32/Float64 input. Each contains a sharp amplitude
increase followed by recovery. The direct-sum oracle analyzes each complete
acquired normalization window independently. Early windows never see future gain.
There are 312 complete frames, plus 12 declared incomplete tails; the 25 artifacts
in `Fixtures/HNRCausal` contain no human recordings.

Starts use `floor(k * Fraction.from_float(max(1, hopSeconds * sampleRate)))`.
This direct rational multiplication is independent of the native incremental
phase accumulator. Whole-window normalization mean/peak, local amplitudes,
candidates, selected periodicity, dB, PCM bytes and all source identities are
retained. Profiles explicitly serialize the causal grid and emit-unavailable
partial-window policy. Numerical budgets are 2e-14 for periodicity and normalized
amplitudes, 1e-4 dB for these ordinary finite values, and 1e-12 seconds for axes.
Counts, selection states, input bytes and rational positions are exact.

```sh
python3 Tools/HNR/streaming.py --directory .build/hnr-causal-candidate
python3 Tools/HNR/streaming.py --directory Tests/HDXLVoiceProcessingTests/Fixtures/HNRCausal --verify
```

Generation refuses an existing directory or a path outside `.build`; verification
recomputes every independent equation and checks every byte. The lightweight
Python contract tests separately validate source/profile hashes, input precision,
exact grids, suppression/recovery and overwrite prevention. Swift compares all
312 complete frames and tests arbitrary chunk boundaries and lifecycle behavior.

## Host performance matrix

`python3 Tools/HNR/benchmark.py timing --shard ac16000` and the analogous
`allocation` command use the pinned benchmark framework in `Benchmarks`. Shards
are `ac16000`, `ac44100`, `ac48000`, `cc16000`, `cc44100`, `cc48000`, `stress`
and `export`. The complete matrix has 208 workloads: the requested 48 AC/CC ×
rate × period × floor × hop configurations, each in both PCM precisions and both
normalization definitions (192), four 20 Hz floor stress cases, four five-second
silence/noise cases, and eight explicit owned-output export cases. Baseline input
is 0.4 seconds; the low-floor cases acquire four full windows and one tail.
At an exact search boundary, noisy peak refinement can leave a frame unavailable;
these stress receipts preserve the observed coverage rather than assume a valid
candidate. No external F0 or transform sharing is involved.

Prepare constructs and destroys the selected worker, including FFT preparation
and bounded PCM storage. Run resets a prepared worker, feeds 256-sample chunks,
finishes and consumes scalar results. Verification repeats with 137-sample chunks
and compares exact numerical checksums and coverage. OwnedDiagnostics additionally
copies candidates and window/correlation arrays and serializes scalar results.
Input generation and correctness verification are outside measured regions.
Each receipt includes canonical configuration/identity, exact PCM hash, geometry,
input duration, explicit workspace bytes, availability/limit counts and checksum.
Whole normalization retains the declared input; causal normalization uses fixed
ring/emission buffers. Workspace accounting excludes object overhead and opaque
FFT setup tables. Prepared non-export runs must have zero observed heap-allocation
maxima; owned export allocations are reported separately. Allocation/ARC positive
controls are required. Timing binaries have interposition disabled.

`python3 Tools/HNR/stage_benchmark.py --rate 16000` (also 44100 and 48000) measures
actual worker scopes, with five paired disabled/detailed trials for each baseline
profile and a warmed worker before each measurement. Raw per-stage nanoseconds
and summaries are retained; nested FFT cost belongs to the inclusive correlation
scope, so those durations must not be summed as independent work. Detailed trials
include bounded sink clock/lock overhead. Paired uninstrumented full-batch trials
show its context; the main suite supplies allocator-free timing distributions and
separate allocation evidence. The probe is development tooling, outside library
products, and logs no audio or per-sample records.

`hnr-benchmarks.yml` runs the eight matrix shards plus three stage-probe rates.
The strict validators reject missing profiles, incorrect hashes/geometry,
coverage or export inconsistencies, incomplete distributions, failed counter
controls, prepared allocations, missing stages, unbalanced inclusive timing and
instrumentation-induced result changes. Host distributions describe processing
cost, not physical capture latency, scheduling guarantees or a real-time deadline
certification. Physical measurements remain tracked under #74/#102.

## Reference CI evidence

`hnr-references.yml` separately regenerates all 180 pinned external cases,
compares their manifest with the frozen references, repeats the 532 independent
equation comparisons, reproduces all 16 intermediate anchors and all 12 causal
cases, then runs the native HNR tests against those newly generated candidates.
The family-specific `HDXL_HNR_REFERENCE_DIRECTORY`, `HDXL_HNR_STAGES_DIRECTORY`
and `HDXL_HNR_CAUSAL_DIRECTORY` environment variables select candidate inputs;
an explicitly empty path is an error rather than a fallback to bundled data.

`HDXL_HNR_REFERENCE_REPORT` exports every native external frame with profile/input
identity, exact axis, typed state, value, comparison-budget use and any proved
single-impulse flat-correlation disagreement. `HDXL_HNR_CAUSAL_REPORT` exports
complete/tail counts, exact chunk equality and maximum numerical-stage budgets.
`native_audit.py` independently checks report completeness, reference identities,
values/limits, proof geometry and causal coverage. The external result remains
qualified (4,107 agreeing frames plus six proved reference disagreements), while
all 312 causal windows and 12 partial tails must pass their separate definition.
Neither CI regeneration nor audit export updates the frozen goldens.
