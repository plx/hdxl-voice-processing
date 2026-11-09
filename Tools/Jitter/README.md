# Jitter reference development

Issue [#50](https://github.com/plx/hdxl-voice-processing/issues/50) implements
local relative jitter, local absolute jitter, RAP, PPQ5 and DDP. This directory
first establishes independent period-sequence evidence, before native statistics
or pulse-tracking outputs are used in comparisons.

`jitter_oracle.py` is original mathematical code. It evaluates the selected
periods with 100-digit Decimal arithmetic after binary64 timestamp subtraction
and eligibility comparisons. It does not import Swift outputs or external
implementation source. `jitter_reference.py` creates a PointProcess using public
Praat commands and queries the hash-verified executable pinned by
`Tools/Reference/toolchain.json`. Praat remains a development process, outside
the package dependency graph. The repository provenance policy applies.

## Numerical definition

For consecutive observed periods, local absolute jitter is the mean absolute
adjacent difference, in **seconds**. Local relative jitter divides that result
by the eligible mean period. RAP measures three-period central deviation;
PPQ5 uses five periods. DDP uses the absolute second difference of periods,
with the same three-period eligibility as RAP, and is three times RAP.
The four relative outputs are **fractions**, not percentages.

Period floor/ceiling and adjacent-ratio limits are inclusive. Each numerator
requires an intact consecutive neighborhood inside the query, with every
period in bounds and every adjacent ratio at or below the configured maximum.
Rejected periods never cause their surviving neighbors to be reconnected.
One accepted pair is sufficient for local/absolute; RAP/DDP require a triplet;
PPQ5 requires a quintuplet. Missing observations produce unavailable results.
An adequately observed constant sequence produces numerical zero.

Mean-period membership is separate: an in-range period is excluded by the
ratio rule only when **both** adjacent ratios exceed the limit. A missing
neighbor at the PointProcess boundary does not fail that test. The public
formulas are documented in the [local-jitter definition](https://www.fon.hum.uva.nl/praat/manual/PointProcess__Get_jitter__local____.html),
[RAP definition](https://www.fon.hum.uva.nl/praat/manual/PointProcess__Get_jitter__rap____.html),
[PPQ5 definition](https://www.fon.hum.uva.nl/praat/manual/PointProcess__Get_jitter__ppq5____.html)
and [DDP definition](https://www.fon.hum.uva.nl/praat/manual/PointProcess__Get_jitter__ddp____.html).

## Pinned boundary observations

Direct black-box queries against **Praat 7.0.02** establish two details that
must remain visible in the fixtures:

- The denominator's adjacent ratios can use periods outside the requested
  query, provided those periods still exist in the PointProcess. For periods
  `[2, 1, 2] / 256`, a query selecting only the middle period has zero accepted
  denominator periods. Creating a separate two-point object for that middle
  period gives one. Cropping a query and constructing a new object are distinct.
- A neighbor outside the period bounds still participates in that ratio test.
  With floor `2/256`, `[1.75, 2, 1.75] / 256` retains the middle period in the
  denominator; `[0.25, 2, 0.25] / 256` with floor `0.5/256` does not.

These are reference observations, not claims about physiological validity.
Explicit tracking failures, exclusions and discontinuities require additional
native eligibility rules; a raw reference point sequence does not establish
that its landmarks are reliable acoustic cycles.

## Catalog and verification

The catalog contains constant sequences of every short length, alternation,
linear ramps, isolated outliers, rejected boundaries, dense rejections, split
regions, inclusive thresholds and adjacent binary64 settings, cropped queries,
uniform time scaling, and 24 deterministic non-dyadic sequences. Dyadic anchors
have hand-derived answers independent of both the tracker and the reference.

Candidate generation is explicit and only writes a new directory under `.build`:

```sh
/opt/homebrew/opt/python@3.14/bin/python3.14 Tools/Jitter/generate.py \
  --output .build/jitter-candidates
/opt/homebrew/opt/python@3.14/bin/python3.14 -m unittest discover \
  -s Tools/Tests -p test_jitter_reference.py
/opt/homebrew/opt/python@3.14/bin/python3.14 Tools/Jitter/verify.py \
  .build/jitter-candidates \
  --canonical Tests/HDXLVoiceProcessingTests/Fixtures/Jitter
```

Each case retains its input, generated script, raw output, tool identity,
generator hashes, independent results, selected indices and comparison bounds.
Candidate generation does not promote or overwrite tracked fixtures.
The committed canonical set contains 69 cases and 208 files. Offline verification
reconstructs every result and identity from the saved scripts and transcripts;
rehashed wrong answers and neighborhood membership still fail the mathematical
and reconstruction checks.

Availability and denominator counts must match exactly. Numerical comparisons
allow a conservative binary64 forward-error bound: with `n` input points,
`g = 8 * ulp(1) * (n + 32)`; seconds use `g * maximumSelectedBoundedPeriod`,
and fractions use `g * (1 + maximumSelectedBoundedPeriod / meanPeriod)`.
The factor covers short-neighborhood operations, ordinary accumulated sums,
and mean/normalization division. This is a numerical conformance allowance,
not an error estimate for recorded speech. DDP must also equal `3 * RAP`
exactly in the external query outputs.

The development interchange is intentionally bounded: at most 30,000 points
in 60 seconds, minimum point separation `1e-12` seconds, and a maximum eligible
period of 0.1 seconds. Inputs reject unknown fields, nonfinite numbers, duplicate
or reordered points, invalid ranges and unsupported settings before execution.
The parser rejects missing, extra, reordered or malformed records, changed
injected points, invalid counts and inconsistent availability.

## Host performance matrix

The #25 workload registration is `JitterCase.matrix()` in
[`JitterWorkload.swift`](../../Benchmarks/Sources/JitterWorkload/JitterWorkload.swift).
It contains 68 cases and 240 operation distributions in each mode:

| Input | Cases | Operations |
| --- | ---: | --- |
| Supplied periods: 0.25/1/3/10 seconds, 80/600 Hz, accepted/dense rejection, both declared PCM precisions | 32 | Prepare, Combined, Separate |
| Incremental rolling: same window/F0/rejection/precision matrix | 32 | Prepare, Combined, Separate, QueryOnly |
| Pinned 0.5-second Gaussian PCM at 16 kHz, 80/600 Hz, Float/Double | 4 | Prepare, PulseOnly, PCMCombined, StatisticsOnly |

Period arithmetic is Float64 in all cases. The original supplied-period recipe
alternates +1%/-1% durations; endpoints come directly from the cycle ordinal,
without accumulated generation drift. Dense cases reject five of every eleven
periods, keeping six-period accepted runs so every numerator is still exercised.
Rejected observations remain in position. The Python receipt checker reconstructs
the input bytes and applies separate 100-digit Decimal equations, comparing
membership/counts exactly and values within stated binary64 forward bounds.

Rolling input contains two windows. Each measured operation begins with one full
window seeded outside the measurement. Combined and Separate append the second
window, querying and consuming output after each new period. Actual append/query
counts and bounded tree-node work are checked. QueryOnly measures one report from
already populated state, with no expiry due. Separate uses five workers that each
compute a genuinely requested variant; RAP/DDP each require the triplet numerator.
Preparation measures construction/destruction of one combined worker. Input
creation, contour hashing, reset, rolling seed history and encoding are excluded.

Supplied periods use one source sample of conservative dependency padding around
fractional endpoints. This is a benchmark input-envelope policy, not a claim of
physiological pulse detection delay. Frame/window lengths, variable period-hop
definition, profile identities, source intervals and precision are recorded.

The PCM comparison uses the existing frozen external pulse/F0 fixtures, including
their exact content hashes. PulseOnly and PCMCombined consume the same borrowed
pulse outputs. StatisticsOnly receives the exact qualified period sequence copied
during untimed setup. Numerical equations are independently checked for those
declared periods and flags; this benchmark does not independently relabel pulse
reliability. Raw pulse populations and positions also match the frozen reference.
The three costs are measured directly. Their difference is not presented as an
isolated internal stage duration. Full pulse tracking validation remains in
[`Tools/Pulses`](../Pulses/README.md).

Run each shard in both modes with the pinned host toolchain:

```sh
python3 Tools/Jitter/benchmark.py timing --shard duration250
python3 Tools/Jitter/benchmark.py allocation --shard duration250
```

The other shards are `duration1000`, `duration3000`, `duration10000` and `pcm`.
Each operation has three warmups and thirty measured samples, with a 600-second
cap; fewer samples fail verification. The retained p99 is near the maximum of
this small sample and is not a stable population-tail estimate. Throughput and
amortized update cost use the declared batch length; query-only cost is separate.
These are host software measurements, not device capture latency or physical
real-time guarantees. Physical evidence is tracked in #74/#102.

Timing and allocation builds use separate `.build/jitter-timing` and
`.build/jitter-allocation` caches. Allocation mode requires positive malloc,
free, byte, object and ARC controls. Every prepared non-Prepare operation must
report zero heap-allocation maxima; unavailable instrumentation cannot pass as
zero. Allocator-instrumented wall times are diagnostic and must not be used as
uninstrumented latency results. Worker signposts are disabled during these runs.
The #18 token50 registration and its source/period counter semantics are in
the [instrumentation guide](../../Documentation/Instrumentation.md#jitter-worker-integration).

Each unique `Benchmarks/.build/artifacts/jitter-<mode>-<shard>-<id>` directory retains
input/profile/geometry reports, hardware/toolchain/SDK and source hashes, locked
dependency resolution, command logs, raw histograms, p99 exports, validated metric
coverage and status. Timing mode also writes derived operation costs. Temporary
framework baselines are removed only after their distributions are retained.

Prepared bytes are explicit buffer storage, excluding object bookkeeping. Pinned
arm64 Swift 6.4 layouts are: numerical period16, public period32, source interval48,
analysis timing112, optional rolling ring entry88 and tree node352 bytes. A ring of
capacity `C` uses `88*C + 352*2*nextPowerOfTwo(C)` bytes. Five separate workers own
five copies of that storage. Input/contour/support arrays are reported separately.
Allocator resident-memory and leak metrics are not inferred from those sizes.

Receipt rejection tests cover changed values, counts, units, queries, profiles,
input/F0 identities, missing incremental work, workspace geometry, distributions,
controls and units. CI runs all five performance shards, regenerates the complete
69-case reference set and proves byte identity before native comparison tests.
