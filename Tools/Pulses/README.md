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

The original writer encodes a `Pitch 1` text object with one selected candidate
per frame. Decimal literals include a leading zero. The external script echoes
every F0 value and frame timestamp before invoking the waveform-aligned tracker.
Fixed serialization intensity/strength values carry no estimated confidence;
the supplied frequency and explicit unvoiced state determine this oracle input.
The strict parser requires the exact injected frequencies, complete ordered frame
and pulse coverage, finite numbers and matching PCM axes. This separates pulse
conformance from errors or choices in a pitch estimator. End-to-end YIN plus pulse
analysis needs separately identified evidence.

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

[Period eligibility](https://www.fon.hum.uva.nl/praat/manual/PointProcess__Get_jitter__local____.html)
and adjacent-pair eligibility are distinct. Rejecting one neighboring ratio must
not silently discard an otherwise eligible period from every other statistic.
Boundary fragments, rejected pairs and missing cycles remain inspectable so later
jitter and shimmer implementations can audit their denominators. Pulse landmarks
are acoustic estimates, not physiological measurements or health classifications.

## Validation and promotion

Protocol tests use hand-enumerated rows and corruptions without launching Praat:

```sh
python3 -m unittest discover -s Tools/Tests -p test_pulse_reference.py
```

External generation remains an explicit developer action. Retain original inputs,
F0 contours, raw output and complete identity records in fresh candidate locations.
Freeze numerical tolerances from independent probes before native comparisons;
never generate expected pulse locations with Swift or change tolerances solely to
make a native comparison pass. Fixture catalog generation, eligibility/amplitude
oracles, promotion, provenance and complete runtime conformance are required parts
of #42; the interchange module alone does not complete that issue.
