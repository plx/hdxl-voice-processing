# Jitter measurements

The jitter family contains local relative jitter, local absolute jitter, RAP,
PPQ5 and DDP. Relative estimates use fractions; absolute jitter uses seconds.
These describe variability in an observed acoustic period sequence. They do not
measure pleasantness, establish a diagnosis, or separate natural F0 movement
from tracking error.

`JitterConfiguration` distinguishes a declared sustained-phonation task from an
exploratory rolling task. An exploratory configuration requires an explicit
integer window size in source sample frames. Every numerical setting, sample
rate, upstream PCM precision, applicability and window size participates in its
canonical identity. Period arithmetic remains Float64 in both PCM precisions.
Unknown fields, altered fixed definitions and invalid settings fail decoding.

## Period statistics

`PreparedJitter` accepts chronological `JitterPeriodInput` records. Times are
seconds relative to `dependencyTiming.source.startSample`; retain that integer
origin rather than first converting a large absolute sample clock to Double.
Each record retains its run ID and source rejection reasons. Records must not
overlap. Gaps, different run IDs and unreliable records interrupt neighborhoods.
Numerically rejected periods stay in position; their neighbors are never joined.

Prepare a fixed maximum period capacity, then call `analyze` on an analysis
worker. An input above capacity fails without publishing a partial result.
Invalid calls leave successful-query counters unchanged. Reset clears execution
statistics. Workers are single-owner objects and must not run in a hardware
capture callback. Returned reports are owned Sendable values and retain no input
buffer. The single-variant overload computes the requested numerator; all other
estimates explicitly report `notRequested`.

```swift
let configuration = try JitterConfiguration(sampleRate: 16_000)
let worker = try PreparedJitter(
    configuration: configuration, maximumPeriodCount: 1_024)
let points = [0.0, 0.010, 0.0202, 0.0301, 0.0403, 0.0503]
let periods = try zip(points, points.dropFirst()).map {
    try JitterPeriodInput(startSeconds: $0, endSeconds: $1)
}
let source = try SourceInterval(
    epoch: StreamEpoch(streamID: UUID()), startSample: 0,
    sampleCount: 1_600, sampleRate: 16_000)
let timing = try AnalysisTiming(source: source, includedSampleCount: 1_600)
let result = try periods.withUnsafeBufferPointer {
    try worker.analyze($0, dependencyTiming: timing)
}
// An unavailable value is nil with an explicit reason, never a fabricated zero.
let absoluteSeconds = result.absolute.value
let relativeFraction = result.local.value
let percentRecord = try result.measurementResult(.local, unit: .percent)
```

For consecutive periods `T`, absolute jitter averages `abs(T[i+1] - T[i])`
over eligible pairs. Local jitter divides that mean by the separately selected
mean period. RAP uses the central deviation within three periods; PPQ5 uses
five periods. DDP uses the same eligible triplets as RAP and equals `3 * RAP`.
One accepted pair, triplet or quintuplet is sufficient for its respective
numerator. A constant sequence with enough observations produces numerical zero.

All periods in a numerator neighborhood must be reliable, inside the query and
within the inclusive period bounds. Every adjacent ratio must be at or below
the configured maximum. The mean-period denominator has its own population:
an otherwise eligible period is rejected by the ratio rule only when both
existing adjacent ratios exceed the limit. Missing neighbors at a run boundary
do not fail that test. A reliable neighbor outside the query or outside the
period bounds can still supply ratio context. Source rejection is a hard boundary.

The [reference development notes](../Tools/Jitter/README.md) identify the public
definitions, direct pinned-reference observations, original analytic fixtures,
and numerical comparison bounds. Agreement on a supplied period sequence does
not imply that an arbitrary waveform yields reliable periods.

## Query support, coverage and persistence

An optional `JitterQueryRange` retains exact Double bounds inside the declared
dependency. Complete point intervals at either boundary are included; a partially
overlapping period is not. Pass the complete available sequence, including
outside-query neighbors needed by the denominator. A crop of the query and a
new object constructed from cropped points are different operations.

`JitterCoverage` reports raw and selected periods, bounded reliable periods,
mean-period membership, accepted pairs/triplets/quintuplets, candidate counts,
duration and rejection counts. Duration coverage divides accepted period time
by query duration. Neighborhood coverage uses accepted/candidate counts.
An empty population has zero coverage, not NaN. Rejection predicates can overlap.
Acquisition coverage in `AnalysisTiming` remains separate: acquired audio can
contain few reliable cycles. Source rejection flags declare immutable selection
for each supplied period; a total acquisition exclusion also excludes all periods.

Availability is per variant. Insufficient observations, silence, exclusions,
missing acquisition, invalid source observations, discontinuities, unsupported
period bounds and low-confidence sequences have explicit unavailable reasons.
Malformed inputs throw rather than becoming successful zero-valued measurements.

`canonicalJSON()` exports the complete typed result: exact query range, larger
dependency timing, profile, input provenance, all estimates and coverage counts.
It is an owned numerical report, not an untrusted archive-import API. Configuration,
period input, query and provenance types have validated Codable representations.
`measurementResult` is an explicit allocating adapter to the shared scalar
contract. Its timing covers the full dependency; retain the typed report to
persist the selected query and counts. Use `queryCenterSourceSeconds` to plot
the query center, including a supplied source-clock anchor. The exact source
interval remains integer-valued even when its absolute display coordinate is
too large for exact Double representation.

Fraction-to-percent conversion is explicit and changes the measurement unit.
Absolute jitter cannot be exported as percent or as a frequency deviation.
Exploratory scalar exports carry the `exploratoryApplicability` warning; incomplete
period coverage carries `partialCoverage`. No confidence probability is invented.

## PCM and acoustic pulses

`PreparedPCMJitter<Float>` and `PreparedPCMJitter<Double>` accept finite mono PCM,
an explicit `PulseF0Contour`, source timing and optional exclusions. They require
no audio engine, microphone, UI or network. Jitter and pulse configurations must
agree on sample rate, precision, period bounds and adjacent-factor threshold.
Prepare explicit PCM, F0-frame and tracking-attempt capacities; total prepared
storage is bounded to 512 MiB.

The adapter preserves all raw adjacent pulse intervals and the tracker's
reliability/run decisions. It exposes a synchronous borrowed pulse trace and
mapped period inputs; copying those inputs is an explicit budgeted operation.
The owned jitter report retains the pulse profile, exact F0-contour identity
and optional supplying F0 profile. An unidentified supplied contour is explicit.

The tracker's complete waveform, global amplitude reference and midpoint
anchoring remain dependencies. This adapter does not make that estimator causal.
An exploratory configuration defaults to its trailing query within the supplied
complete input. Its earliest permitted start is calculated as
`max(0, queryEnd - configuredWindowDuration)`; this avoids inconsistent repeated
floating-point subtraction when a sample-aligned window is expressed in seconds.
Independently anchored blocks retain their distinct pulse profile and cannot
claim cycle continuity across blocks. See [acoustic pulse tracking](Pulses.md)
for support, delay and exclusion details.

The integration tests include original periodic/jittered/rising-F0 signals, three
licensed sustained vowels, and licensed voiced/consonant-rich speech in both
input precisions. Speech remains exploratory and exposes its lower coverage.
These are software behavior checks, not clinical validation or physiological
timing evidence. Physical and expert-labelled evidence remains tracked in
[#74](https://github.com/plx/hdxl-voice-processing/issues/74) and
[#102](https://github.com/plx/hdxl-voice-processing/issues/102).
