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

[Search mathematics and stage evidence](SEARCH.md) defines sampled coordinates,
F0 support, seed selection, observed-pair correlation, finite-table peak selection,
quadratic refinement, progression and the separate source-timing bias model.

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
behavior. The separate finite-input certificates below account for the actual
discrete/finite support; these observations do not relax native/reference parity.

External generation remains an explicit developer action with the pinned
Python/toolchain environment from [Reference](../Reference/README.md):

```sh
python3 Tools/Pulses/generate.py --output .build/pulse-candidates-new
python3 Tools/Pulses/verify.py --directory .build/pulse-candidates-new
```

Isolated stages have a separate explicit generation route:

```sh
python3 Tools/Pulses/stage_probe.py --mode f0 --output .build/pulse-f0-stages-new
python3 Tools/Pulses/stage_probe.py --mode matching \
  --reference-directory .build/pulse-candidates-new --output .build/pulse-matching-stages-new
```

The F0 route retains direct executable queries at frame centers, interior points,
boundaries and adjacent representable times. The matching route first verifies
the complete input reference catalog, then compares 80-digit correlation/peak
stages with 96 retained next-pulse positions across the Gaussian cases. Stage
summaries bind every generated artifact and source identity. Their timing records
describe developer generation, not native execution. They are isolated-stage
evidence and cannot replace full native tracker/run/eligibility conformance.

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
eligibility, timing budgets and complete runtime conformance remain required
parts of #42; these development tools alone do not complete that issue.

## Promoted evidence and native comparison

The complete catalog and isolated stages are retained under `Fixtures/Pulses`,
`Fixtures/PulseF0Stages`, and `Fixtures/PulseMatchingStages`, including raw
transcripts, inputs, tool/source identities, and provenance inventory. Offline
verification never launches either Swift or the external executable:

```sh
python3 Tools/Pulses/verify.py --directory Tests/HDXLVoiceProcessingTests/Fixtures/Pulses
python3 Tools/Pulses/verify_stages.py \
  --f0-directory Tests/HDXLVoiceProcessingTests/Fixtures/PulseF0Stages \
  --matching-directory Tests/HDXLVoiceProcessingTests/Fixtures/PulseMatchingStages \
  --reference-directory Tests/HDXLVoiceProcessingTests/Fixtures/Pulses
```

`PulseReferenceTests` checks all raw landmarks, every available native amplitude,
255 F0 queries, and 96 complete independent correlation tables. The
[frozen comparison policy](COMPARISON.md) records the exact constant-waveform
proof exception separately from location parity. The
[runtime contract](../../Documentation/Pulses.md) explains native eligibility,
ownership, complete support, and bounded chunked delivery.

For freshly regenerated candidates, set `HDXL_PULSE_REFERENCE_DIRECTORY`,
`HDXL_PULSE_F0_STAGE_DIRECTORY`, and `HDXL_PULSE_MATCHING_STAGE_DIRECTORY` to
their respective directories before running the same tests. An explicitly empty
path fails instead of silently selecting committed fixtures. Set
`HDXL_PULSE_REFERENCE_REPORT` to retain native/reference coordinates, source and
profile identities, amplitude comparison counts, and maximum budget use. This
audit is separate from generator execution timings and physical measurements.

## Independent tracking histories

`trace_oracle.py` supplies a bounded original locator using the 80-digit stage
equations. It retains the complete finite lag tables and all attempted steps,
then computes eligibility through connected components of a successful-step
graph. Rejection removes an edge; filtering the raw point list cannot reconnect
it. The 50 cases include both precisions, exclusions, missed cycles, silent and
unvoiced gaps, short fragments, period limits, alternating periods and strengths,
polarity, fractional seeds, and 80/150/300/600 Hz templates.

The exact binary lobe templates have independently specified source landmarks.
The quarter-sample asymmetry of one template also exposes endpoint seeding:
an extremum at the seed-window edge is not refined, so that case retains a
declared -0.25-sample phase bias. Increasing the input length moves the seed to
the interior and recovers the fractional source phase. Absolute source error
and bias-adjusted residual remain separate fields. A seed in a long silent gap
can reacquire a different phase and yield unavailable cycle RMS. Neither case
is evidence of physiological timing, and exact-template anchors remain separate
from the finite Gaussian source certificates.

```sh
python3 Tools/Pulses/trace_reference.py --directory .build/pulse-histories-new
python3 Tools/Pulses/trace_reference.py --verify \
  --directory Tests/HDXLVoiceProcessingTests/Fixtures/PulseHistories
swift test --filter pulseHistories
```

Generation checks the independent history against the pinned external raw
trajectory and amplitudes. Offline verification regenerates PCM, F0, mathematical
histories, graph membership, and every derived result, without Swift or external
execution. It rejects stale identities, missing/extra artifacts, changed policies,
symlinks, and rehashed corruption. The 202 promoted files include 200 case
artifacts plus manifest and separately scoped generation timings. Hashes and
replay do not authenticate the producer of the retained external transcript.

`PulseHistoryTests` compares all 1,586 attempts, 1,434 raw points, 1,386 adjacent
intervals, 1,342 adjacent-period pairs, and their amplitudes in both direct and
irregularly chunked modes. Eligible counts are 1,088 periods, 958 pairs, and 890
amplitudes. Set `HDXL_PULSE_HISTORY_DIRECTORY` to test a freshly generated catalog;
an explicitly empty override fails. The [comparison policy](COMPARISON.md) was
frozen before native history comparison and is separate from generator timings.

## Separate estimated-F0 integration

`yin_reference.py` first reproduces 16 existing independent YIN fixtures from
their original PCM and equations. It maps only complete raw-voiced frames to
positive F0 at their observed-support midpoints; every other full-frame status
maps explicitly to unvoiced. The original hop and unsupported edges remain.
Partial tails are excluded; no complete frame means insufficient upstream
support. The causal candidate tracker is disabled in this recipe. These choices
are retained in `fullSupportRawVoicedYINToPulse-v1` and must be included in any
combined pipeline configuration that adopts it.

The pinned external pulse route then receives that independently estimated F0.
The 16 cases cover tones, harmonics, missing fundamental, varying F0, irregular
pulses, noise, silence, both precisions, and three licensed speech excerpts. All
152 full YIN frames and 175 external raw pulses remain inspectable. The speech
records inherit corpus attribution and consent evidence; unavailable/no-pulse
outcomes are retained without inventing reference pitch labels.

```sh
python3 Tools/Pulses/yin_reference.py --directory .build/pulse-yin-new
python3 Tools/Pulses/yin_reference.py --verify \
  --directory Tests/HDXLVoiceProcessingTests/Fixtures/PulseYIN
swift test --filter pulseYINIntegration
```

Offline verification recomputes the original YIN inputs, F0 mapping, and parsed
external results. Native comparison uses both YIN backends and whole-input or
irregular chunk delivery. It checks the upstream frame grid/status exactly and
frequencies within the existing YIN **0.001 Hz** budget. Raw pulse counts remain
exact; the separate end-to-end catalog position budget is **1e-6 samples**, with
the existing cycle-amplitude budget. These catalog gates were declared before
native integration comparisons; they are not universal error bounds.

Set `HDXL_PULSE_YIN_DIRECTORY` for a fresh candidate catalog and
`HDXL_PULSE_YIN_REPORT` for the separate native error/count audit. Explicitly empty
paths fail. Integration passes do not replace supplied-oracle-F0 conformance,
history qualification, or known-source/physical accuracy evidence.

## Finite generated-source timing

`source_reference.py` certifies 36 original Gaussian cases using only source PCM,
F0 and known generated coordinates. Coverage includes both precisions, the three
rates and four steady frequencies, polarity, quiet input, known jitter, modulation
and alternating strength. It does not read native or external tracker answers.

The [frozen source policy](SOURCE_TIMING.md) derives a radius from input geometry,
ideal interpolation bias and declared precision. Exact integer energies/dots and
outward arithmetic then check the actual finite-window calculation against that
radius. All possible rounded window geometries and winning peak alternatives are
enclosed; a failed proof condition stops generation. This avoids treating an
infinite Gaussian approximation as an unproved finite-window error theorem.

```sh
python3 Tools/Pulses/source_reference.py --directory .build/pulse-source-new
python3 Tools/Pulses/source_reference.py --verify \
  --directory Tests/HDXLVoiceProcessingTests/Fixtures/PulseSourceTiming
swift test --filter pulseGeneratedSourceTiming
```

The promoted 38 files retain 4,290 source landmarks and their certified algorithm
intervals. Native tests require exact source count/order, interval membership and
the unchanged source-error radius in both direct and chunked modes (8,580 point
comparisons). The maximum observed source error is about 1.38 samples, while the
widest certified algorithm interval is below 8.56e-8 samples. These are different
quantities: the narrow interval encloses the finite algorithm's biased result,
not the true source center. Original source coordinates remain unchanged.

Use `HDXL_PULSE_SOURCE_TIMING_DIRECTORY` for a fresh candidate directory and
`HDXL_PULSE_SOURCE_TIMING_REPORT` for a native error audit. The certificate verifier
recomputes every enclosure and rejects rehashed changes to coordinates, intervals,
budgets, identities and coverage. [Evidence and assumptions](../../Documentation/Evidence/pulses.md)
separate this finite-catalog claim from arbitrary-waveform or physiological accuracy.

## Host performance matrix

The A12 matrix has 88 cases. Forty-eight cover Gaussian 80/150/300/600 Hz at
16/44.1/48 kHz, both input precisions, and both support definitions. Thirty-two
cover rising/falling F0, 12% jitter, noisy pulses, missed cycles, splices, silence,
and noise. Four use the licensed sustained-vowel excerpt; four deliberately copy
owned snapshots. All input PCM and F0 come from the promoted pinned catalog.
The workload verifier checks hashes, raw reference agreement, reset repeatability,
eligibility counts, and every available amplitude before measurement.

```sh
python3 Tools/Pulses/benchmark.py timing --shard steady16000
python3 Tools/Pulses/benchmark.py allocation --shard steady16000
python3 Tools/Pulses/stage_benchmark.py --shard steady16000
```

Complete the `steady16000`, `steady44100`, `steady48000`, `stress`, `vowel`, and
`export` shards in both timing and allocation modes. The stage probe uses the
first five shards; export repeats an existing input and adds no new kernel case.
Each invocation retains a fresh artifact directory and never reuses a previous
timing receipt. Run timing measurements separately from other benchmark workloads.

`Prepare` constructs and destroys the tracker or bounded block collector with
prepared PCM/F0 already available. `Run` resets and analyzes the full declared
interval; block mode additionally appends 256-sample chunks before finishing.
It consumes every borrowed output array. Owned cases also copy and consume all
five snapshot arrays; they do not claim archive serialization. Loading/decoding,
input generation, F0 identity hashing, warmup, and verification are outside the
measured operation. Ordinary runs require zero observed heap allocations with
positive malloc/ARC controls; the owned-snapshot cases intentionally allocate.
Timing binaries exclude the allocator interposer; allocation binaries include it.

Receipts retain profiles, PCM/F0/fixture identities, sample rate, precision,
input duration, F0 frame grid, chunk size, attempt/output counts, capacity, prepared
bytes, hardware/toolchain, and full raw benchmark histograms. Prepare/control use
30 measured iterations after three warmups; Run uses ten after one warmup. The
p99 of ten observations is effectively the maximum, not a stable population-tail
estimate. `costs.json` derives throughput and amortized cost per attempt from the
complete Run distribution. It does not attribute the whole batch to accepted or
rejected cycles. Both support profiles wait for their complete block; processing
time is separate from the half-block center delay and physical capture latency.
There is no fixed analysis frame/hop: each matching window spans one current F0
period, with one attempted cycle per progression step. The supplied F0 grid is
reported independently; 256 samples is a delivery chunk, not an analysis hop.

The separate stage probe records the actual attempted steps from a complete
native tracking prepass, then replays the unchanged matching/interpolation kernel
with five paired disabled/detailed trials. Every result must equal the prepass;
every detailed matching call is recorded, with no diagnostic suppression. Each
attempt gets its own diagnostic frame to avoid production's 64-record prefix
limit. Accepted/rejected reference gates and native eligible/ineligible timing
remain separate groups. Matching/interpolation samples include sink clock/lock
overhead. Null means a stage was not measured or not entered; a measured zero
means below-clock-resolution duration. Replay totals include framing/validation
and are not complete analyzer throughput. No physical-device performance claim
is made; those measurements remain follow-up #74.

The [initial host evidence](../../Documentation/Evidence/pulses-performance.md)
records all 17 passing shards, observed throughput and allocation counts, stage
coverage, and raw-artifact identities. `pulse-benchmarks.yml` runs the complete
matrix for relevant pull requests and weekly. `pulse-references.yml` independently
regenerates raw, isolated-stage, history and YIN integration candidates before
comparing native release output against those fresh candidates.
