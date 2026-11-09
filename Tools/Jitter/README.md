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
