# Shimmer reference development

Issue [#51](https://github.com/plx/hdxl-voice-processing/issues/51) adds local
normalized shimmer, local dB, APQ3, APQ5, APQ11 and DDA. The reference foundation
is independent of native outputs: original supplied amplitude sequences, exact
rational equations and 100-digit logarithms are compared with the hash-pinned
Praat 7.0.02 executable. No external implementation source is used. Praat is a
development process and never a package runtime dependency.

## Equations and populations

The [public definitions](https://www.fon.hum.uva.nl/praat/manual/Voice_3__Shimmer.html)
define local shimmer as the mean absolute adjacent amplitude difference divided
by a mean amplitude. Local dB is the mean of
`20 * abs(log10(a[i+1] / a[i]))`, **not** a difference of dBFS analysis frames.
APQ3/5/11 average the absolute deviation of the central amplitude from its
three/five/eleven-amplitude neighborhood mean, then normalize. DDA is three
times APQ3 under the identical neighborhoods. Relative outputs are fractions;
local dB is in decibels.

Original black-box experiments establish the pinned normalization population:
**all selected amplitudes except the final one**, independently of numerator
period/amplitude-ratio rejections. Zeros remain in this population. When an
amplitude factor of at least 2 permits the pair, `[1,2]` has local shimmer 1,
while `[2,1]` has 0.5; both have the same dB value. This
asymmetry is explicit reference behavior, not a physiological claim. Owner
attention issue [#158](https://github.com/plx/hdxl-voice-processing/issues/158)
records the convention for later review.

Every numerator window requires consecutive positive amplitudes, all adjacent
timestamp differences inside inclusive period bounds, and each adjacent
`max(a,b)/min(a,b)` at or below the amplitude factor. No rejected edge is
removed and reconnected. Local/dB need two amplitudes, APQ3/DDA three, APQ5
five, and APQ11 eleven. A constant eligible sequence produces numerical zero;
an empty, zero-energy or inadequately observed sequence is unavailable.

The supplied-tier query is constructed from points in the closed selected
range. It does not claim equivalence to extracting amplitudes from a cropped
waveform/PointProcess query, which needs neighboring pulses to define support.
Native source reliability and explicit continuity are additional to these
raw mathematical tier rules.

## Evidence and reproduction

The 94-case catalog covers every short constant length, alternation, ramps,
sinusoidal modulation, outliers, zeros, reversal, gain/time scaling, inclusive
thresholds and adjacent binary64 values, split neighborhoods, cropped tiers,
and 24 deterministic non-dyadic sequences. Development interchange bounds are
30,000 records in 60 seconds, timestamp separation at least `1e-12`, and
amplitudes zero or in `[1e-150,1e150]`. These are fixture limits, not PCM units.

```sh
/opt/homebrew/opt/python@3.14/bin/python3.14 Tools/Shimmer/generate.py \
  --output .build/shimmer-candidates
/opt/homebrew/opt/python@3.14/bin/python3.14 Tools/Shimmer/verify.py \
  .build/shimmer-candidates --canonical Tests/HDXLVoiceProcessingTests/Fixtures/Shimmer
/opt/homebrew/opt/python@3.14/bin/python3.14 -m unittest discover \
  -s Tools/Tests -p test_shimmer_reference.py
```

Generation only writes an absent directory under `.build`. The canonical set
contains 283 files: inputs, scripts, raw transcripts, independent equations,
membership indices, rejection reasons, comparisons, hashes and a manifest.
Offline verification reconstructs everything without running the reference.
Corruption tests include rehashed wrong answers and forged normalization or
neighborhood membership; a checksum alone is insufficient.

Availability and membership decisions are exact. For arithmetic comparisons,
`g = 16 * ulp(1) * (n + 64)`; fractional bounds are
`g * (1 + maximumSelectedAmplitude / meanAmplitude)`, and the dB bound is
`g * (1 + abs(expectedDB))`. The factor covers ordinary binary64 accumulation,
up to eleven terms per neighborhood and normalization/logarithm operations.
This is numerical conformance allowance, not a recorded-voice error estimate.
External DDA must additionally equal `3 * APQ3` exactly.

## PCM extraction and accepted-population audit

`Fixtures/ShimmerPCM` adds 80 cases (161 files) using existing original pulse
fixtures, without duplicating audio: both precisions, full and cropped queries,
80/150/600 Hz inputs at 16/44.1/48 kHz, harmonic and filtered signals, modulation,
alternation, polarity/gain, noise, jitter, missing cycles, unvoiced gaps and short
or silent inputs. Wider amplitude-factor cases expose the effect of that setting.
Inherited WAV, Pitch and pulse-fixture hashes are verified before execution.

The pinned CLI produces 70 complete query sets and explicitly skips ten cases
with fewer than three selected pulses. A skipped query has no external answer.
Every complete query records both Sound/PointProcess and extracted AmplitudeTier
answers. Independent squared-Hann energy sums audit 4,072 raw RMS amplitudes;
the exact sequence equations then audit all six external statistics. RMS error
is bounded by `2e-12 + 1e-10 * abs(referenceAmplitude)`, inherited from the pulse
extraction contract. It is separate from the statistical arithmetic allowance.

Native tests retain 4,030 accepted RMS observations. Source reliability excludes
additional amplitudes in 36 cases, two retain explicit run/cycle gaps, 32 have
identical populations/neighborhoods, and ten have no executed reference query.
The first interior amplitude of full Gaussian inputs is explicitly asserted to
retain the upstream insufficient-support rejection. It is not silently admitted
to force agreement with a raw reference tier. Identical populations permit 176
direct scalar comparisons after propagating the RMS error through normalization
or logarithms. All 80 native populations are independently recomputed with exact
rational equations and 100-digit logarithms, including their rejection counts.

```sh
python3 Tools/Shimmer/generate_pcm.py --output .build/shimmer-pcm-candidates
python3 Tools/Shimmer/verify_pcm.py .build/shimmer-pcm-candidates \
  --canonical Tests/HDXLVoiceProcessingTests/Fixtures/ShimmerPCM
HDXL_SHIMMER_PCM_REPORT="$PWD/.build/shimmer-native-pcm.json" \
  swift test -c release --filter shimmer
python3 Tools/Shimmer/audit_native_pcm.py .build/shimmer-native-pcm.json \
  --report .build/shimmer-native-audit.json --corruption-controls
```

The native audit independently checks input/profile/F0 identity, source timing,
adapter flags, selected and normalization membership, complete neighborhoods,
coverage, units, availability and numerical answers. Its negative controls reject
missing rows, altered scalars, counts, source flags and profile identity. CI
regenerates both catalogs, checks canonical identity, runs the native suite and
retains raw transcripts, reports and audit results. An additional 36-case native
integration suite exercises original signals and the existing approved licensed
vowel/speech corpus in both precisions. It checks finite behavior, provenance and
coverage; it does not promote those native values into reference goldens.

## Host performance matrix

The 68 workloads register shimmer statistics under #25 and token-51
`Perturbation` scopes under #18. The matrix has 32 amplitude batches, 32 rolling
histories and four PCM comparisons. Amplitude/rolling cases cover 0.25/1/3/10
seconds, 80/600 Hz and both declared input precisions at 16 kHz. Arithmetic is
Float64. Original alternating 0.9/1.1 amplitudes exercise every numerator;
dense cases additionally reject seven of each seventeen source observations
and include isolated amplitude-4 outliers. Missing observations retain their
sequence positions. Exact equations independently validate counts and values.

Batch `Combined` computes all six variants. `Separate` uses six actual
single-variant workers, including each worker's coverage calculation. Rolling
measurements seed one complete window outside the clock, then measure at most
64 append/query pairs, consuming every result. This keeps the operation bounded
while exercising expiration at every window size. `QueryOnly` measures one
already populated window. Receipts verify append/query counts and the exact
number of amplitudes scanned. The implementation is O(n) per query, with
amortized O(1) append/expiration, not constant-time incremental statistics.

The PCM cases use existing pinned half-second Gaussian 80/600 Hz fixtures in
both precisions. `PulseOnly` includes shared cycle RMS extraction and bounded
trace consumption. `PCMCombined` includes the same pulse work, mapping and all
shimmer statistics. `StatisticsOnly` operates on the exact qualified amplitude
sequence captured during untimed setup. These are directly timed operations;
subtracting two noisy timings is not used to claim an isolated extraction cost.
All three retain the same source and F0 identities. Available RMS amplitudes
are checked against the frozen external pulse evidence, and mapped source flags
are audited separately from the statistical equations.

`Prepare` measures combined worker construction/destruction and bounded buffers.
Input creation, F0 construction, resets, rolling seeds, snapshots and JSON export
are outside steady-state measurements. Thirty measured samples follow three
warmups; an operation that cannot supply thirty within 600 seconds fails. Wall
and CPU histograms, explicit p99 values, throughput, amortized update/query cost,
profiles, frame/window/hop definitions, input hashes, hardware/toolchain identity,
source hashes and prepared/input storage are retained. P99 from thirty samples
is near the observed maximum, not a stable population-tail estimate.

```sh
python3 Tools/Shimmer/benchmark.py timing --shard duration250
python3 Tools/Shimmer/benchmark.py allocation --shard duration250
```

Run both modes for `duration250`, `duration1000`, `duration3000`, `duration10000`
and `pcm`. Timing uses a binary without allocator interposition. Allocation uses
a separate binary, requires positive malloc/free/object/ARC controls, and rejects
any nonzero maximum heap count/bytes/object allocation in a prepared operation.
Artifacts are in `Benchmarks/.build/artifacts/shimmer-*`; CI runs each shard and
retains its original distributions and independently validated receipts.
No fixed machine-independent timing gate or physical-device claim is made.
Deployment cadence and any need for incremental aggregation are tracked in
[#160](https://github.com/plx/hdxl-voice-processing/issues/160). Device capture,
thermal behavior and sustained real-time evidence remain in
[#74](https://github.com/plx/hdxl-voice-processing/issues/74) and
[#102](https://github.com/plx/hdxl-voice-processing/issues/102).
