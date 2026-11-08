# Acoustic pulse reference contract

Issue #42 uses the pinned Praat 7.0.02 **Sound + Pitch → PointProcess (cc)**
development route. The executable and source identities are in
[the reference lock](../Reference/toolchain.json). `reference.py` is an original
interchange wrapper: it does not estimate pitch or locate pulses. The runtime
library must implement the published mathematics independently; the
[source-reuse policy](../../Documentation/ProvenancePolicy.md) applies.

## Independent F0 input

The caller supplies a regularly sampled contour with explicit domain end, first
frame center, step, ceiling and selected frequency per frame. Zero identifies an
unvoiced frame. Positive frequencies must be finite and below the ceiling. The
contour covers the same observed mono PCM domain; no implicit resampling,
normalization, pitch analysis or gap stitching occurs in the wrapper.
Its frame centers may cover only the interior of that domain. The original
interior grid is retained; missing edge frames are not invented or padded.

The original writer encodes a `Pitch 1` text object with one selected candidate
per frame. Decimal literals include a leading zero. The external script echoes
every F0 value and frame timestamp before invoking the waveform-aligned tracker.
Fixed serialization intensity/strength values carry no estimated confidence;
the supplied frequency and explicit unvoiced state determine this oracle input.
The strict parser requires the exact injected frequencies, complete ordered frame
and pulse coverage, finite numbers and matching PCM axes. This separates pulse
conformance from errors or choices in a pitch estimator. End-to-end YIN plus pulse
analysis needs separately identified evidence.

For licensed speech, `pitch.praat` and `pitch_reference.py` retain a separate
Praat raw-CC F0 transcript: 5 ms hop, 75–700 Hz range, 15 candidates, accurate
mode, and all voicing/path costs serialized explicitly. The script also tracks
pulses directly from that original Pitch object. Reinjecting its selected F0
frames must produce exactly the same raw pulse positions. This is an
interchange check, not a claim that either the reference F0 or its pulses are
physiological ground truth. The synthetic sources use known supplied contours
and do not invoke that estimator.

Float32 input is rounded once before lossless Float64 WAVE transport; Float64
input remains unchanged. The reference record binds input precision, exact WAV
and Pitch bytes, raw output, wrapper sources and the complete tool lock. The
current resource boundary is five seconds, at most 960,000 samples, 5,000 F0
frames, 30,000 output points and 4 MiB of protocol output. These are developer
reference bounds, not runtime API limits or timing budgets.

## Tracking conventions and eligibility

The [method description](https://www.fon.hum.uva.nl/praat/manual/Sound___Pitch__To_PointProcess__cc_.html)
seeds each completed voiced interval at an absolute waveform extremum near its
midpoint, then matches approximately one-period neighborhoods on both sides.
Normalized dot products and parabolic peak refinement determine fractional pulse
locations. The pinned release searches 0.8–1.25 times the current period, with
separate internal and edge correlation/amplitude gates. Release-specific details
must be tested against the pinned executable rather than inferred from the
manual's abbreviated 1.2 bound. A whole-interval seed and amplitude reference
cannot claim causal prefix stability.

Raw landmarks are not automatically accepted periods. The reference can emit an
extra edge landmark outside the acquired domain; the parser retains it and records
its zero-based index. It does not clamp a pulse to the boundary. Native sequence construction
must expose boundary, support, selection, tracking and period-range eligibility,
and may not connect cycles across gaps, exclusions or failed tracking. A single
seed on forced-voiced silence supplies no valid period. Symmetric waveform extrema
can change the selected phase under polarity inversion; known asymmetric pulse
trains and symmetric tones must both be tested. These choices are tracked in
[attention issue #151](https://github.com/plx/hdxl-voice-processing/issues/151).
Forced F0 on a constant waveform can produce many raw points and positive RMS
amplitudes. Their presence alone is not evidence of usable cycle timing. Native
eligibility must separately identify degenerate waveform support; the raw
external transcript must remain unchanged for conformance auditing.

[Period eligibility](https://www.fon.hum.uva.nl/praat/manual/PointProcess__Get_jitter__local____.html)
and adjacent-pair eligibility are distinct. Rejecting one neighboring ratio must
not silently discard an otherwise eligible period from every other statistic.
Boundary fragments, rejected pairs and missing cycles remain inspectable so later
jitter and shimmer implementations can audit their denominators. Pulse landmarks
are acoustic estimates, not physiological measurements or health classifications.

`sequences.py` supplies independent eligibility algebra, not a pulse locator.
It retains every adjacent interval in the original sequence, with explicit run
membership and failed-tracking interval indices supplied by the caller.
Individual period bounds and adjacent-period ratios are evaluated separately.
The acquisition domain is half-open `[0, duration)`; an endpoint at `duration`
does not become an observed sample. This algebra cannot recover tracking failures
from a flat reference point list: the native tracker must expose that history.

## Cycle-amplitude definition

Protocol `pulse-reference-v2` retains the external **To AmplitudeTier (period)**
observations as well as raw landmarks. The fixed defaults are minimum period
0.0001 s, maximum period 0.02 s, and adjacent-period factor 1.3; custom settings
are explicitly serialized and echoed. These are independent of the pitch
search bounds. With fewer than three observed raw landmarks, the transcript
reports `insufficientData` without invoking the amplitude command.

The external tier's query selects pulse times in the *closed* interval
`[0, duration]`, then excludes its first and last points. Both periods neighboring
an interior point must satisfy the period range and their ratio must satisfy the
factor. This external selection rule is preserved for reference auditing;
native half-open acquisition, run, gap and selection rules remain additional.

At pulse time `t`, let `L = 0.2 × previousPeriod` and
`R = 0.2 × nextPeriod`. For each observed sample center `s` in `[t-L, t+R]`,
choose `W=L` on the left and `W=R` on the right. The amplitude taper is
`h(s) = cos(π(s-t)/(2W))²`. The reported amplitude is
`sqrt(sum(x(s)² h(s)²) / sum(h(s)²))`, with at least three samples and positive
energy. It is a Hann-weighted RMS, not a peak-to-peak amplitude. No partial
support, silent energy, or numerical failure becomes a numeric zero.

The independent oracle uses compensated sums and scales by the local peak before
squaring. Constant-signal and isolated-impulse tests have closed-form answers;
polarity and very small finite scaling are also checked. External comparisons
use a frozen linear-amplitude budget of `2e-12 + 1e-10 × abs(reference)`.
Pulse indices and times are exact because this comparison uses identical raw
reference landmarks. This budget does **not** define a native pulse-location
tolerance or validate the pulse-search algorithm.

## Validation and promotion

Protocol tests use hand-enumerated rows and corruptions without launching Praat:

```sh
python3 -m unittest discover -s Tools/Tests -p 'test_pulse_*.py'
```

The original catalog contains 110 cases across Float32/Float64 and
16/44.1/48 kHz: known Gaussian trains at 80/150/300/600 Hz, symmetric tones,
jitter, modulation, alternating and missing cycles, rising/falling F0,
polarity/gain/DC, harmonic/filter changes, noise, splices, explicit unvoiced
gaps, wrong F0, degenerate signals, short fragments, and eight licensed speech
sources per precision. Gaussian landmarks describe the generated source, not
expected tracker answers; filtering/noise can shift the acoustic landmarks.
Speech inputs retain their approved corpus path, hash and inherited attribution.

Known source timing and agreement with the pinned tracker are separate tests.
The reference's fractional-delay parabola can accumulate a small signed bias
while following a narrow periodic waveform away from its midpoint seed. In the
0.5 s, 16 kHz, 600 Hz Gaussian candidate, all 300 cycles are located distinctly,
but source-time error reaches about 1.38 samples; the per-period bias is about
0.009086 samples. A continuous-Gaussian correlation parabola explains this
behavior. A final source-timing budget still needs the discrete/finite-support
stage checks; these observations do not relax native/reference parity.

External generation remains an explicit developer action with the pinned
Python/toolchain environment from [Reference](../Reference/README.md):

```sh
python3 Tools/Pulses/generate.py --output .build/pulse-candidates-new
python3 Tools/Pulses/verify.py --directory .build/pulse-candidates-new
```

The output directory must be absent and under `.build`. `--case NAME` produces
an explicitly partial catalog; verification requires `--allow-partial` for it.
Full verification rejects partial, reordered, duplicate, unknown, stale and
extra artifacts. It regenerates exact PCM and Pitch bytes, parses all raw
transcripts, recomputes identities and amplitude evidence, and validates the
manifest and separately scoped generation timings. Corruption tests update
file hashes deliberately to exercise the deeper checks. Hashes and offline
replay establish integrity and reproducibility; they do not authenticate who
produced a transcript. Promotion still requires retained executable-run evidence
and independent review.

Retain original inputs, F0 contours, raw output and complete identity records in
fresh candidate locations. No candidate is promoted automatically.
Freeze numerical tolerances from independent probes before native comparisons;
never generate expected pulse locations with Swift or change tolerances solely to
make a native comparison pass. Pulse-search stage oracles, native support/run
eligibility, promotion, provenance, timing budgets and complete runtime
conformance remain required parts of #42; these development tools alone do not
complete that issue.
