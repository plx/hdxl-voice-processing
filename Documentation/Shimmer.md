# Shimmer measurements

Shimmer describes variation in observed cycle amplitudes. The six variants are
local normalized shimmer, local dB, APQ3, APQ5, APQ11 and DDA. They do not establish
a diagnosis, measure pleasantness or distinguish natural amplitude movement from
tracking error. `ShimmerConfiguration` records either a declared sustained
phonation task or exploratory rolling use. Exploratory values carry that warning
and coverage; the profile does not turn changing speech into sustained phonation.

## Prepared amplitude statistics

`PreparedShimmer` accepts chronological `ShimmerAmplitudeInput` records with
times relative to `dependencyTiming.source.startSample`. Preserve this integer
origin instead of converting a large absolute sample clock to Double. Each
record carries a sequence index, run ID and source rejection flags. Keep rejected
records in place: dropping them must not create a new adjacent pair. Nonconsecutive
indices, different runs, missing amplitudes and source rejections break windows.

```swift
let configuration = try ShimmerConfiguration(sampleRate: 16_000)
let worker = try PreparedShimmer(
    configuration: configuration, maximumAmplitudeCount: 1_024)
let amplitudes = try [1.0, 1.1, 0.9, 1.0, 1.05].enumerated().map { i, value in
    try ShimmerAmplitudeInput(
        timeSeconds: Double(i + 1) * 0.01, amplitude: value, sequenceIndex: UInt64(i))
}
let source = try SourceInterval(
    epoch: StreamEpoch(streamID: UUID()), startSample: 0,
    sampleCount: 1_600, sampleRate: 16_000)
let timing = try AnalysisTiming(source: source, includedSampleCount: 1_600)
let result = try amplitudes.withUnsafeBufferPointer {
    try worker.analyze($0, dependencyTiming: timing)
}
let fraction = result.local.value
let decibels = result.db.value
let percentRecord = try result.measurementResult(.local, unit: .percent)
// APQ11 is unavailable here: five amplitudes cannot form an eleven-point window.
```

Workers have fixed capacities and one owner. Prepare them off the capture path,
then call them on an analysis worker. Invalid or oversized input throws without
publishing a partial result. Reset clears execution counters; diagnostic callbacks
cannot reenter query or reset operations. The owned, Sendable report retains no
borrowed input. A single-variant call marks the remaining estimates `notRequested`.

## Equations, eligibility and units

Local shimmer averages `abs(a[i+1] - a[i])` over accepted pairs and divides by
the selected mean amplitude. Local dB averages
`20 * abs(log10(a[i+1] / a[i]))`; it is a logarithmic amplitude ratio, not a
difference between dBFS analysis frames. APQ3/5/11 average the absolute deviation
of a central amplitude from its complete neighborhood mean, then normalize.
DDA is exactly three times APQ3 over the identical neighborhoods.

Every numerator edge requires positive source-eligible amplitudes, an inclusive
timestamp separation inside the period bounds and an amplitude ratio at or below
`maximumAmplitudeFactor`. Every edge in an APQ window must pass. Local/dB need
two consecutive amplitudes, APQ3/DDA three, APQ5 five and APQ11 eleven. Period-factor
eligibility belongs to upstream cycle extraction; supplied amplitude records
declare that source eligibility in their flags.

The pinned reference's normalization population is **all source-eligible selected
amplitudes except the final one**, including zeros and amplitudes whose numerator
edges fail the numerical thresholds. This creates reversal asymmetry: `[1,2]`
normalizes local shimmer by 1, while `[2,1]` normalizes by 2. This convention is
serialized explicitly and tracked for owner attention in
[#158](https://github.com/plx/hdxl-voice-processing/issues/158). The
[reference notes](../Tools/Shimmer/README.md) document its independent evidence.

Relative variants use fractions; an explicit export can convert them to percent.
Local dB uses `decibelsRatio`. A constant, sufficiently observed sequence yields
zero. Zero energy, missing support, exclusions, discontinuities or too few
neighbors yield explicit unavailability, never a fabricated favorable zero.
Peak scaling and compensated sums protect finite tiny and huge amplitudes. When
the positive mean itself cannot be represented, its scale and scaled mean remain
inspectable; it is not mislabeled as silence.

## PCM extraction and source provenance

`PreparedPCMShimmer<Float>` and `<Double>` accept normalized mono PCM, explicit
`PulseF0Contour`, timing, optional query and excluded sample ranges. They require
no microphone, acquisition framework, UI or network. Rate, precision and period
settings must match `PulseConfiguration`; sustained phonation requires complete
interval support. Amplitude arithmetic remains Float64 for both input precisions.

The adapter reuses the [pulse worker](Pulses.md)'s cycle RMS amplitude: a Hann
window extending 0.2 of the preceding and following periods from each pulse,
with squared window weights in the energy sum. It retains one amplitude record
per pulse, including rejected observations. Matching failures, unavailable
neighboring periods, exclusions and run boundaries remain visible. In particular,
the first interior amplitude of a clean full-interval fixture can lack reliable
matching support even when a raw reference PointProcess yields an amplitude.
The adapter preserves that rejection instead of weakening the tracker policy.

A cropped PCM query requires both neighboring pulses inside the closed query
before the center amplitude can contribute. It reuses the complete extracted
RMS support rather than shortening the window. This differs from querying a
supplied amplitude tier, where only amplitude centers select membership. The
reference suite separately audits RMS extraction, raw tier equations, complete
Sound/PointProcess queries and the native accepted population.

The synchronous callback receives an owned result and borrowed amplitude/pulse
views. Borrowed views expire on return. `snapshotAmplitudes(maximumCount:)` is an
explicit allocating persistence operation. Input provenance includes the pulse
profile, supplied F0 identity and available source-profile identity. Supplied
amplitudes can instead declare their own source provenance.

## Queries, coverage and rolling use

`ShimmerCoverage` reports input, selected, source-accepted, positive and
normalization counts; accepted/candidate pairs and APQ neighborhoods; query and
accepted-pair durations; and rejection counts. Acquisition coverage in
`AnalysisTiming` is separate from cycle coverage. Rejection predicates can
overlap. Empty populations have zero coverage rather than NaN.

`canonicalJSON()` preserves profile identity, provenance, dependency timing,
query, estimates and coverage. Scalar `measurementResult` export allocates and
uses the dependency timing; persist the typed report to retain the selected
query and all counts. `queryCenterSourceSeconds` includes the optional source
clock anchor. Configuration identities include every threshold, fixed numerical
definition, precision, rate, applicability and integer rolling-window size.

`PreparedRollingShimmer` retains a bounded history of source-relative amplitude
records. Append each observation once with its complete source dependency. Query
with an Int64 source-sample clock; `requiredDependency(atSourceSample:)` supplies
the envelope for the corresponding `AnalysisTiming`. Returned sample-aligned
queries preserve exact integer endpoints even at large source-clock origins.
Reset starts a fresh epoch. Expired, stale or excluded data remain explicit.

Appending and expiring ring entries is amortized O(1). A result query recomputes
the bounded window in O(n), with fresh peak scaling and compensated sums to avoid
long-running update drift. Capacity bounds storage and query cost. This API is
incremental history management, not incremental constant-time statistics.
`evaluatedAmplitudeCount` exposes the scanned work. The PCM adapter itself analyzes
the complete supplied interval and defaults exploratory queries to its trailing
configured window; callers needing an amplitude history use the rolling worker.
The [performance protocol](../Tools/Shimmer/README.md#host-performance-matrix)
measures this cost explicitly. Target-hardware cadence and optimization decisions
remain tracked in [#160](https://github.com/plx/hdxl-voice-processing/issues/160).
