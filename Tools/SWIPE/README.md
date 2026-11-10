# Bounded SWIPE-prime reference contract

Issue #44 implements **SWIPE′**, the first/prime-harmonic variant, from Camacho
and Harris, JASA 124(3), 2008, [DOI 10.1121/1.2951592](https://doi.org/10.1121/1.2951592).
The author's [2007 dissertation](https://hdl.handle.net/10669/536), chapter 3,
provides the underlying derivation. The route assigned by
[`Tools/Reference/ROUTES.md`](../Reference/ROUTES.md) is an original implementation
of these equations. No MATLAB or other third-party implementation is copied,
imported, or executed. Python and its standard library are developer tools only.
This is neither plain SWIPE nor a claim of binary parity with author software.

The named profile is `hdxl-swipe-prime-centered-2008`, version 1. The choices below
make the paper's otherwise underspecified discrete interpolation and boundaries
reproducible. They are frozen before generating native comparison fixtures.
Changes require an explicit profile/fixture review, not regeneration to make a
native mismatch disappear.
Decision [#162](https://github.com/plx/hdxl-voice-processing/issues/162) records the
profile choices and the pre-native pure-tone accuracy finding below.

## Discrete profile

- Mono finite PCM, integer sample rate 4–192 kHz, Float32 or Float64 inputs and
  Double arithmetic. No implicit resampling, demeaning, conditioning, or voicing
  mask. Divide by the complete observed support's absolute peak to bound
  arithmetic; retain that peak and the original-unit RMS. This gain does not
  change normalized pitch strength.
- Inclusive pitch range, floor at least 20 Hz and ceiling at most `fs/4`.
  Candidate spacing is logarithmic: `floor * 2^(j/candidatesPerOctave)`, starting
  at j=0, followed by the exact ceiling. The default is 96 candidates per octave
  (1/8 semitone); supported integer resolutions are 12–192. Omit an interior
  point if it is within `1e-12 * ceiling` of the ceiling, then append that ceiling
  exactly once. Require at least three candidates, at most 2304. This tiny
  endpoint coalescence is a grid-construction convention, not pitch acceptance
  tolerance. Equal strengths choose the lowest candidate frequency.
- The optimal Hann support for candidate f is `8*fs/f`. Let
  `L=floor(log2(fs/f)+3)` and `lambda=log2(fs/f)+3-L`. Blend the strengths from
  lengths `2^L` and `2^(L+1)` with weights `1-lambda` and `lambda`. Do not prepare
  or evaluate an upper window whose weight is exactly zero. All selected window
  lengths are powers of two, bounded by 131072 samples.
- A full frame observes the longest required window. Smaller windows use its
  centered subinterval, with integer offset `(fullLength-windowLength)/2`.
  The periodic Hann is `0.5-0.5*cos(2*pi*j/N)`, j=0..<N. Thus all windows have
  the same center at the midpoint of their half-open support. Use the ordinary
  negative-exponent unnormalized DFT and magnitudes at bins 0...N/2, including
  DC and Nyquist, without doubling interior bins.
- Sample the auditory axis at `e=m*0.1`,
  `m=0...floor(21.4*log10(1+(fs/2)/229)/0.1)`, and map back with
  `f=229*(10^(e/21.4)-1)`. There is no extra Nyquist endpoint. Interpolate
  **magnitude linearly** between its two surrounding DFT bins, then take its
  square root to obtain loudness. Equation 23 leaves the interpolating function
  unspecified; this profile names it explicitly. It is not cubic interpolation
  of magnitude, interpolation of complex coefficients, or interpolation of power.
- For each candidate, sum equation 16's components for harmonic 1 and all prime
  harmonic indices whose lobes intersect the sampled band. At frequency ratio q,
  a component centered on h is `cos(2*pi*(q-h))` for `abs(q-h)<1/4`, half that
  cosine for `1/4<abs(q-h)<3/4`, and zero elsewhere. Quarter-period boundaries
  are exactly zero. Overlapping valleys add. Composite peaks are absent.
  A partially intersecting lobe is evaluated at every actual ERB point; there
  is no complete-lobe truncation or invented frequency beyond Nyquist.
- Multiply by `1/sqrt(frequencyHz)`. The value at DC is the limiting zero
  because every component is identically zero near DC. Normalize the signed
  kernel by the L2 norm of **its positive part**, retaining negative coefficients.
  Normalize loudness by its L2 norm over the **whole sampled ERB band**, including
  DC. Their signed inner product is pitch strength. Zero loudness norm means
  unavailable strength, not a numerical zero. The common ERB step cancels.
  Strength is not a probability; it may be negative, even below -1. No absolute
  value or clipping converts that statistic into confidence.
- Choose the largest blended discrete strength. At an interior strict maximum
  (`center>left` and `center>right`), fit a quadratic through the three strengths
  on the **period axis** `1/f`. Use the continuous vertex only if concave and
  between the two neighboring periods. Endpoints, ties, convex or invalid fits
  retain the discrete candidate. Do not extrapolate or clamp into the pitch range.
  Report the discrete score, refined score, selected index, and refinement flag.
- Default strength threshold is 0.2, configurable in (0,1). A selected refined
  score at or above the threshold is voiced/eligible; a weaker estimate remains
  uncertain with a low-confidence warning. Neither status certifies speech or
  voice health. RMS at or below the explicit silence threshold (default 1e-7 in
  unit-peak PCM) is unvoiced/silence. A nonzero exactly constant frame is unvoiced/
  lowConfidence. Such frames retain intermediate diagnostics but select no F0.
  Undefined spectra/kernel norms are unavailable/analysisFailure, never 0 Hz.
  This includes a nonzero isolated boundary sample whose Hann-windowed support
  cannot supply any complete candidate; its nonzero raw RMS stays visible.
- Streaming starts at the continuity epoch's first sample and advances by an
  integer hop, 1...fullLength. It reports full observed support and its midpoint;
  earliest delivery is half that duration after the midpoint. Hop is not latency.
  No boundary zero-padding supplies observed PCM. Finalization either reports the
  first nonempty partial frame as unavailable/insufficientData or discards it by
  explicit policy. A gap/reset discards prior history and restarts the local grid.

All adjustable values and the named conventions participate in serialized
identity. SWIPE′ is optional and does not replace or gate YIN, CPP/CPPS, or other
measurements. It requires no capture engine, UI, network, Python runtime, or model.

## Precommitted numerical and applicability budgets

For identical Float32/Float64 PCM values promoted to Double, compare ordinary
DFT magnitudes with **2e-11 × window length absolute + 2e-12 relative**,
ERB loudness with **2e-7 absolute + 2e-12 relative**, kernel coefficients with
**2e-11 absolute**, window/blended/refined strengths with **2e-7 absolute**,
and refined F0 with **0.01 Hz absolute**. Geometry, support, candidate selection,
classification, and availability are exact. The square-root budget accounts for
roundoff near zero magnitude; it is not a measurement uncertainty interval.
The oracle's original recursive complex FFT is checked against direct scalar DFT
and analytic spectra. The native path will use the independently supplied vDSP
real transform. Neither generates expected results for the other.

Interior stationary pure tones with at least eight samples per period must have
at most **50 cents** absolute error and at least **90% voiced coverage** of full
frames. Clean identifiable harmonic and missing-fundamental sources must have at
most **20 cents**, no gross/octave errors, and at least **90% voiced coverage**.
Dominant upper harmonics, inharmonic mixtures, range boundaries, transitions,
noise, and real speech remain separate characterizations with all denominators
retained. No universal superiority over YIN is claimed. A clean analytic source
failure must be investigated before native implementation or golden promotion.

The first contract commit (`1905674`) proposed a 10-cent pure-tone gate. The
independent oracle failed that proposal **before any native implementation or
golden promotion**. A 228-frame preflight across two pitch ranges, two phases,
and 16/44.1/48 kHz found a maximum absolute error of 34.494 cents, without
unvoiced frames. Substituting an independently derived exact Hann-tone DTFT
still gave 27.682 cents for a 165.054 Hz tone at 44.1 kHz; changing to cubic
magnitude interpolation did not remove the bias in exploratory comparisons.
These calculations show pure-sinusoid bias in this discrete profile.
Thirty harmonic/missing-fundamental preflight cases at the same three rates had
maximum absolute error below 3.53 cents. These are bounded observations, not
general accuracy promises.

Accordingly, v1 keeps the specified algorithm and records the unmet **10-cent
quality goal** separately in reports. Its pure-tone regression ceiling is a
conservative half-semitone, 50 cents, committed before reference promotion.
The numerical parity budgets and 20-cent harmonic gate are unchanged. This
amendment does not count the original 10-cent proposal as passing, discard
unfavorable frames, or introduce an empirical pitch correction. The reproducible
investigation and #162 retain the evidence for future profile evaluation.

```sh
python3 Tools/SWIPE/investigate.py --output .build/swipe-tone-investigation.json
python3 -m unittest discover -s Tools/Tests -p 'test_swipe*.py'
```

Compare both estimators on identical PCM with their own actual support and
delivery delay. Match support midpoints explicitly; do not equate frame indices
or hops. YIN uses the SWIPE′ requested hop when it fits YIN's shorter support;
otherwise its explicitly serialized comparison hop equals that support. This
produces a denser valid YIN stream, not a change to either estimator's mathematics.
Match each complete SWIPE′ frame to the nearest unused complete YIN midpoint
within half the actual YIN hop; ties choose the earlier midpoint. Preserve the
half-sample displacement of odd YIN support and both actual support intervals.
Report unmatched frames, partial tails, available and accepted coverage,
fine cents error conditional on non-gross available estimates, gross errors
(>20% relative Hz), and octave errors (gross and within 20% of half/twice truth).
Unknown corpus truth stays unknown. Physical-device and human-label evidence
remains assigned to #74/#102 and does not waive software correctness gates.

## Implementation and evidence status

The independently recomputed reference catalog contains 74 cases, 374 SWIPE′
frames (300 complete and 74 partial tails), 1982 YIN frames, and 300 pairs matched
by actual support midpoint. Its 146 artifacts include input and generator hashes,
all spectral/candidate stages, kernel probes, both profiles, and complete coverage
and error denominators. Derived speech outputs inherit the governed corpus's
attribution; its PCM is read from the existing corpus paths. Synthetic inputs are
lossless Float64 WAV, including explicitly rounded Float32 cases.

Generate candidates separately from promotion; verification recomputes every
record and audits the exact inventory. Expected values never come from Swift.

```sh
python3 Tools/SWIPE/swipe_reference.py --output .build/swipe-candidates
python3 Tools/SWIPE/swipe_verify.py .build/swipe-candidates
python3 Tools/SWIPE/swipe_verify.py
```

The Swift configuration and layout match all 74 profile identities and geometries.
The prepared native worker passes every retained spectral/candidate stage and
final F0 comparison, both directly and through batch/irregular streaming delivery
(374 direct frames and 748 streamed frames). Core lifecycle, borrowing, export
budgets and diagnostics tests pass on the separately recorded local development
toolchain. Optional scheduler, archive, and capture-result integration is also
implemented and covered by local tests. Performance and final review/CI gates
remain under development for #44. This is not a completed issue or a
performance claim. See the [native guide](../../Documentation/SWIPEPrime.md).
Preparation must retain reusable FFT plans, Hann tables, frequency interpolation
indices/weights, and normalized candidate kernels. Processing storage must remain
bounded independently of recording duration. Owned intermediate exports allocate
explicitly and are measured separately.

## Paired workload validation

The workload checker covers 44 inputs and 88 paired SWIPE′/YIN FFT rows. The 36
ordinary inputs span 16/44.1/48 kHz, Float/Double, 80–400 Hz and 25–2000 Hz ranges,
and 5/10/20 ms requested hops. Eight additional inputs cover both precisions at
the maximum geometry, ten-second silence/noise, and owned intermediate export.
The maximum profile uses 192 kHz, 20–48000 Hz, 192 candidates/octave, and 131072
observed samples. Its shared framing prerequisite is #165 / #166.

Both algorithms receive identical PCM bytes and retain their own support and
valid hop. YIN tracking is disabled. The checker compares 256-sample, 137-sample,
and whole-input delivery, coverage, observable checksums, and stable buffer
payloads. `workloads.py` independently enumerates every case, regenerates the PCM
hashes, and validates profiles, identities, frame counts, support/delay, owned
export sizes, and exact payload accounting on the supported 64-bit Apple ABI.
All worker payloads must remain below 64 MiB; input storage is reported separately.

`probe_audit.py` checks the first, middle, and last complete scalar estimate in
each row against the original independent SWIPE′ and scalar YIN oracles. The
existing frozen numerical budgets apply. These probes run outside measurement;
they complement the complete staged fixture suite. Their report retains source
hashes, expected/actual estimates, and errors, and rejects source edits during
the audit.

```sh
mkdir -p .build
swift run --package-path Benchmarks --scratch-path .build/swipe-check \
  --configuration release --force-resolved-versions SWIPEPrimeWorkloadCheck \
  > .build/swipe-workloads.json
python3 Tools/SWIPE/probe_audit.py .build/swipe-workloads.json \
  --output .build/swipe-probes.json
```

## Timing and allocation collection

On the exact toolchain declared in `Configuration/build.json`, run each of the
ten shards exposed by `benchmark.py --help` in both modes:

```sh
python3 Tools/SWIPE/benchmark.py timing --shard MaximumGeometry
python3 Tools/SWIPE/benchmark.py allocation --shard MaximumGeometry
```

The dedicated workflow runs all ten shards. Each mode uses a separate optimized
build and a fresh named baseline. Timing rejects allocator interposition;
allocation mode verifies its linkage and positive malloc/object/ARC controls.
Every non-export prepared Run must have zero maximum malloc count, malloc bytes,
and object allocations. OwnedDiagnostics allocates explicitly. Construction is
measured separately, excluding input generation and destructor cost. A Run
includes reset, chunked processing, scalar consumption, and finalization.

Artifacts under `Benchmarks/.build/artifacts/swipe-prime-*` retain the environment,
source and dependency hashes, complete workloads and oracle probes, command log,
raw distributions, measured counts/maxima, p99 exports, and a fail-closed result.
Input generation, workload validation, and independent scalar probes occur before
measurement. Sources and the resolved dependency lock must remain unchanged.
Failed unarchived baselines remain available locally for investigation.

Run measurements use one warmup and ten measured operations; preparation/control
use three warmups and up to thirty measured operations. At least ten samples per
metric are required. The p99 of ten observations is effectively their maximum,
not a stable estimate of a population tail. Full-batch throughput does not
establish worst-frame latency or physical capture performance. Actual measured
distributions, final CI evidence, and registrations under #25/#18 remain pending.
