# Digital levels and K-weighted energy

`PreparedLevelAnalyzer<Float>` and `<Double>` analyze original finite mono PCM on a serialized
worker. They produce owned, immutable `LevelWindowResult` values containing sample peak,
mean-square/RMS, dBFS, crest factor, input diagnostics, and optional K-weighted energy.
They require no capture framework, UI, microphone permission, or network. Prepare away from
the capture callback; the synchronous worker deliberately is not `Sendable`.

## Reference, averaging, and units

The reference is **unit peak PCM**. For a window of N samples:

```
peak = max(abs(x))
meanSquare = sum(x*x) / N
rms = sqrt(meanSquare)
dBFS = 10*log10(meanSquare) = 20*log10(rms)
crestFactor = peak/rms
crestFactorDB = 20*log10(crestFactor)
```

A constant magnitude of 1 has 0 dBFS RMS. A full-scale sine has approximately
-3.01029995664 dBFS RMS and 3.01029995664 dB crest factor. Amplitude doubling raises level by
6.02059991328 dB. `samplePeakDBFS` is distinct from RMS-based `unweighted.digitalLevel`.
Inputs above magnitude 1 are accepted and can produce positive dBFS. No implicit normalization,
downmix, pre-emphasis, gain, or resampling occurs.

Every profile declares rectangular mean-square averaging, window/hop samples, rate, input
precision, Float64 arithmetic, mono-already-selected channel policy, reference, units, weighting,
warm-up, partial-window policy, filter phase policy, and exact coefficients. A SHA-256 identity
covers the complete validated configuration under `digital-level-windows/v1`.

`LevelEnergy` stores a peak scale and normalized mean square. Direct accumulation uses scaled
sum-of-squares to avoid squaring overflow or losing tiny nonzero input. The sliding method uses
compensated updates, an exact monotonic sample-peak queue, deterministic rebasing every N
updates, and a scaled direct fallback when cancellation or extreme squares make the recursive
sum unreliable. Both use Float64 arithmetic even for Float32 PCM. This is explicit in profiles.

Zero energy is an actual state: linear RMS and mean square are zero, and `DigitalLevel.zeroEnergy`
has mathematical decibels of negative infinity. JSON carries a tag rather than a nonfinite
number. The shared finite-scalar adapter reports `.unavailable(.silence)` for that logarithm;
crest factor is also unavailable for silence. Very small or large **nonzero** energy retains
a finite logarithm even when a linear value cannot fit in Double; that scalar is
`.unavailable(.unsupportedRange)`. There is no arbitrary finite dB floor.

## Continuous K-weighting

The optional cascade implements the shelving and high-pass stages specified in
[ITU-R BS.1770-5, Annex 1, Tables 1 and 2](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en).
At 48 kHz it uses those tabulated coefficients exactly. At other rates, original code recovers
the analog denominator and shelf numerator through inverse bilinear transformation, recovers
each pole frequency, prewarps it at the requested rate, and transforms back. The high-pass
numerator stays `[1, -2, 1]`. Profiles expose `bs1770-5-prewarped-tables/v1`, the rate, and both
stages. `response(at:)` exposes magnitude, phase, and frequency-dependent group delay; DC has
zero gain and undefined phase/delay.

The two transposed direct-form-II stages retain state across contiguous input chunks. Reset
starts with zero history. Callers explicitly choose a nonnegative `warmupSampleCount`; there
is no hidden convergence claim. A weighted window is unavailable for insufficient data until
its **first** sample lies at or after the chosen warm-up boundary. Unweighted full windows are
independently available during that time. For example, 4,800 warm-up samples at 48 kHz is a
100 ms policy, not proof that an infinite-response filter has forgotten all prior samples.

`weighted` is nil when not requested, unavailable when ineligible, or an independent scaled
energy. Its digital logarithm uses the same unit-peak reference without an additive loudness
offset. This is **K-weighted mean-square energy**, not integrated LUFS, gated loudness, true
peak, or acoustic SPL. No channel weighting, gating, intersample reconstruction, or calibration
algorithm is implied.

The filter detects subnormal Float64 arithmetic or a nonzero product rounded to zero.
`weightedPrecisionLimited` then stays true until reset, and eligible weighted windows report
unsupported range. Unweighted scaled energy remains usable. Float32 subnormal input promoted
to Float64 normally avoids this limitation. Very long decaying tails can also enter Float64's
subnormal range, so hosts must inspect the flag and explicitly reset to start a fresh history.
This conservative policy and its usability are tracked in [attention #100](https://github.com/plx/hdxl-voice-processing/issues/100).
Nonfinite filter output instead fails the worker until reset; no affected window is published.

## Source grids, timing, and lifecycle

The first window begins at the supplied epoch origin; later starts advance exactly H samples.
H must be between 1 and N, inclusive. Source coordinates use Int64 integer arithmetic, including
origins near Int64.max. Input chunks must match epoch, expected start, count, and sample rate.
Invalid metadata or any nonfinite sample rejects the entire chunk before consuming it. Inspect
`LevelError.nonfiniteInput` for NaN, positive/negative infinity, rail, over-range, and subnormal
counts; it is not a missing-data or valid-zero result.

The worker buffers new samples and updates the accumulators/filter at each window boundary.
It emits every complete window synchronously, with identical results across chunk partitions.
The result's `source` is the actual rectangular averaging support. `filterHistorySource` separately
records all causal history since reset, including warm-up. The source interval is never shifted
to compensate filter phase. Timing records the actual window-center-to-delivery buffering delay,
excluding host compute/scheduling; K phase is frequency-dependent and remains separately
inspectable. Weighted timing has zero included samples while the weighted estimate is unavailable.

`finish` never pads with invented zeros. It either discards the earliest incomplete grid window
or emits it unavailable with actual observed support and `missingSampleCount`. It emits at most
one partial window, even for heavy overlap. That tail may overlap earlier complete windows;
use `completion.observedSource` for unique input coverage. Repeated successful finish returns
the same completion without another callback. Empty input produces no measurement.

`reset(for:)` acknowledges an explicit `SourceDiscontinuity`, checks any known missing interval
begins at the next expected input, clears pending data/filter/window history, advances the epoch,
and restarts source positions at zero. Ordinary reset reuses buffers; reset after cancellation
prepares new storage. `reconfigure` prepares a new validated configuration/identity/storage before
replacing the old plan, and also requires an explicit successor or new-source epoch.

`cancel` releases storage. Cancellation from a result callback stops at that emitted window and
returns the consumed prefix. Recursive process/finish/reset/reconfigure is rejected. A consumer
may retain a result indefinitely: it owns no borrowed PCM or mutable workspace. Scalar adapters
may allocate warning arrays and belong outside the prepared kernel.

Supported unweighted rates are integer 4,000–192,000 Hz; K-weighting requires 16,000–192,000 Hz.
N is 1–262,144 samples; warm-up is at most ten seconds. `preparedBufferBytes` counts owned
sample rings and peak queues, excluding object/scalar/allocator overhead; it is not process RSS.
Configuration and result decoding reject inconsistent derived units, identity, timing, support,
eligibility, and diagnostic counts.

## Clipping, microphone gain, and acoustic SPL

Exact magnitude-1 hits and values above magnitude 1 have separate counts. Their sum is the
**possible** clipping fraction, and shared available scalar estimates carry a clipping warning.
Digital samples cannot establish physical ADC saturation: an earlier analog stage may clip
below digital full scale, or a legitimate processed signal may exceed unit magnitude.

Microphone/preamp gain, microphone sensitivity and distance, the acoustic field, and later
digital gain all influence recorded amplitude. Changing digital gain changes dBFS without
establishing a new acoustic pressure. Calibrated SPL needs a known pressure reference and a
documented complete recording chain; adding a constant such as 100 to dBFS is not calibration.
See the [ASHA instrumental-assessment recommendations](https://pubs.asha.org/doi/10.1044/2018_AJSLP-17-0009)
for recording and calibration context. These outputs are not a clinical voice-quality score.

## Example and validation

```swift
let configuration = try LevelConfiguration(
    sampleRate: 48_000, inputPrecision: .float32, windowLength: 2400, hopLength: 480,
    accumulation: .compensatedSliding, weighting: .bs1770Revision5(warmupSampleCount: 4800))
let epoch = StreamEpoch(streamID: UUID())
let analyzer = try PreparedLevelAnalyzer<Float>(configuration: configuration, epoch: epoch)
// On the serialized analysis worker; sourceInterval describes this original mono chunk.
try samples.withUnsafeBufferPointer { input in
    try analyzer.process(input, interval: sourceInterval) { result in
        // Publish the owned result; inspect each outcome before using a numeric value.
    }
}
try analyzer.finish { partial in
    // Explicit insufficient-data result; no fabricated zero-valued measurement.
}
```

Offline tests compare 240 original synthetic cases at ten rates and both input precisions
against independently obtained coefficients and an 80-digit Decimal direct-form-I filter.
They cover full and attenuated sine, DC, steps, white/pink noise, impulse, Nyquist, over-range
and tiny signals, plus chunking, warm-up/reset, long streams, extreme dynamic range, lifecycle,
strict serialization, and bounded diagnostic scopes. See [reference tooling](../Tools/Levels/README.md).
The [performance evidence](Evidence/levels.md) covers the required 10/50/400 ms windows and
16/44.1/48 kHz rates, preparation, direct/sliding execution, combined weighted/unweighted work,
silence, denormals, and independently configured workers. Physical measurements remain
[follow-up #74](https://github.com/plx/hdxl-voice-processing/issues/74).
