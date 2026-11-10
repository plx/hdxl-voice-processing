# Power cepstrum and cepstrogram

These worker primitives transform finite mono PCM into inspectable power-cepstral
frames. They accept explicit sample rates, input precision, bandwidth, profile and
source coordinates. They do not require a pitch estimate: noisy and low-periodicity
speech is analyzed under the same numerical rules. CPP peak/background extraction
is a separate consumer implemented in #35.

Prepare off the audio capture callback and serialize operations on one worker.
Plans and borrowed output are deliberately not `Sendable`. The normal path reuses
windows, transforms, conversion and frame buffers; it retains no output matrix.
Borrowed pointers are valid only during the synchronous output callback.

## Numerical definition

The versioned `praat-7.0.02-power-cepstrum` definition reproduces the pinned full
Sound-to-PowerCepstrogram route, including its treatment of the final frequency bin.
It is not interchangeable with a standalone Spectrum-to-PowerCepstrum command.

For analysis rate `fs`, pitch-floor setting `p`, and `dt = 1/fs`, the physical
Gaussian support is `6/p` seconds. The observed frame length `M` is that duration
in samples, rounded to nearest with ties away from zero; transform length `N` is
the next power of two. The default `fs=10000`, `p=60` gives `M=1000`, `N=1024`,
513 nonnegative-frequency/quefrency bins. The pitch-floor setting controls support;
it does not gate on an estimated F0.

1. Resample the separately declared source interval or preview stream to `fs`.
2. Apply raw pre-emphasis with `a = exp(-2π × preEmphasisFromHz × dt)`:
   the first resampled value is unchanged; later values use fused `x[n] - a*x[n-1]`.
   History survives input chunks and is discarded on reset. Zero Hz requests a
   first difference. There is no peak or RMS normalization.
3. Remove the observed-frame mean, multiply by the unnormalized Praat Gaussian2,
   and append transform zeros. Windowing does not include padded zeros in the mean.
4. Compute the canonical negative-exponent DFT and multiply both components by `dt`.
5. Form `2*(real² + imaginary²)` at **every** bin, including DC and Nyquist.
6. Take the natural logarithm of `power + 1e-300`, except **Nyquist uses `log(power)`**.
7. Invert the even real log spectrum with `1/N` normalization, multiply by `fs`,
   and square its first `N/2+1` values. Output is linear power, not decibels.

Both Float32 and Float64 **source PCM use Double conditioning and analysis**.
Float PCM is widened exactly into prepared scratch before conditioning. Input
precision and analysis precision remain separate serialized facts and participate
in profile identity. Deep spectral minima make Float arithmetic materially change
logarithms and availability; [decision #105](https://github.com/plx/hdxl-voice-processing/issues/105)
records that finding and the conditions for a future fast profile.

| Stage | Horizontal axis | Value unit/scaling |
| --- | --- | --- |
| `windowed` | seconds, step `dt`, including trailing zeros | normalized amplitude, Gaussian2 after mean removal |
| `spectrumReal`, `spectrumImaginary` | Hz, step `fs/N` | normalized amplitude × seconds; `dt * DFT` |
| `powerSpectrum` | Hz, step `fs/N` | normalized amplitude² × seconds²; twice squared complex magnitude |
| `logPowerSpectrum` | Hz, step `fs/N` | dimensionless natural log relative to one amplitude²-second² |
| `signedCepstrum` | quefrency seconds, step `dt` | inverse seconds; `fs * inverse(logPower)` |
| `powerCepstrum` | quefrency seconds, step `dt` | inverse seconds²; signed cepstrum squared |

All stage coordinates start at zero. The local `windowed` axis is relative to the
extracted frame; the frame context separately locates it in the source interval.
`CepstralStage` exposes units, axis step and scaling. These numerical units are not
acoustic calibration, vocal loudness, or a clinical interpretation.

## Whole interval and preview

`PreparedPowerCepstrum` accepts **already-conditioned Double samples** and an explicit
`CepstralFrameContext`. Use it when a caller owns conditioning and framing. Its profile
identifies the frame recipe; the two pipeline wrappers identify the full PCM recipe.

`PreparedIntervalCepstrogram<Float/Double>` prepares a positive fixed source length,
accepts contiguous chunks, then emits only from `finish`. It uses depth-50 pinned
whole-interval conditioning. Frame count and symmetric centering preserve reference
floating-point endpoint behavior; center evaluation is fused before the nearest
one-based sample-index decision. `IntervalCepstrogramLayout` exposes these axes.
Its source dependency support is conservatively the entire conditioned interval,
while each frame's center and first analysis-sample index are explicit separately.
The inherited timing delay describes whole-interval buffering from the source
midpoint; it is not a per-frame capture-to-result latency.

`PreparedPreviewCepstrogram<Float/Double>` uses finite Blackman-windowed FIR resampling
and a left-anchored integer hop grid. It is a **different numerical profile**. It emits
when FIR lookahead and a complete frame are available. Source support includes the
previous resampled sample needed by pre-emphasis. Leading/trailing zero extension
is explicitly labelled and does not increase the original observed source count.
Frame timing records delivery delay from the analysis-frame midpoint to the consumed
input edge, including batching, excluding computation and host scheduling. The
100 ms default frame support and FIR lookahead remain relevant even at a 5 ms hop.

Both paths expose a zero-length original-clock origin, separate analysis indices,
relative center, dependency timing, supplied target-sample count and boundary flag.
They preserve large absolute source positions as integers. Neither silently joins
samples across gaps. Preview reset validates an original-clock discontinuity and
starts a fresh epoch at position zero; whole-interval reset starts a separate source
interval of the same prepared size and rate.

## Availability and lifecycle

- Too little positive input emits one `.insufficientData` result on finalization;
  empty preview input emits none. Whole-interval preparation requires positive input.
- Zero input preserves all finite intermediate stages, but its unfloored zero Nyquist
  makes the cepstrum unavailable with `.silence`. Other numerical singularities use
  `.analysisFailure`. No epsilon is silently added to the final frequency bin.
  [Decision #104](https://github.com/plx/hdxl-voice-processing/issues/104) records this rule.
- A failed stage preserves its finite prefix and reason. Later uncomputed stages are
  empty and unavailable. Numerical zero in a complete stage remains a valid number.
- Inadequate declared bandwidth is a configuration error. Nonfinite input or incorrect
  chunk coordinates reject the entire chunk before mutation. Conditioning arithmetic
  failure throws; explicit reset recovers a failed worker. No invalid row is fabricated.
- Repeated `finish` returns the original completion without repeating callbacks.
  `completeFrameCount` counts full temporal support, including numerically unavailable
  frames; `unavailableFrameCount` independently counts unavailable outputs.
- Recursive processing/reset/finish throws. Cancellation is allowed from a callback:
  it releases retained workspace after the active borrow completes and is terminal.
  Preview reports the actually consumed input prefix. A new plan is required afterward.

## Explicit owned output

Inside a callback, `output.stage(.powerCepstrum)` borrows one stage. `output.export`
copies a requested stage set under `IntermediateOutputPolicy.maximumScalarCount`;
each `CepstralStageSnapshot` pairs finite `IntermediateSnapshot` data with expected
length and unavailability. Keep the output configuration, profile and context with
an exported diagnostic so the axis, source and numerical recipe can be reconstructed.

`BoundedCepstrogram` retains owned `PowerCepstrumFrame` rows only when explicitly
created. Both frame and scalar capacities are required, checked before appending,
and never silently evict old rows. A new interval needs a new collector. Owned rows
are strictly Codable: decoding rejects contradictory profile hashes, geometry,
availability or nonfinite values. Copies and serialization may allocate; their
performance is measured separately from prepared borrowed processing.

```swift
let configuration = try CepstrogramConfiguration(
    sourceSampleRate: 48_000, inputPrecision: .float32,
    hopSeconds: 0.005, declaredInputBandwidthHz: 20_000,
    conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
let epoch = StreamEpoch(streamID: UUID())
let worker = try PreparedPreviewCepstrogram<Float>(
    configuration: configuration, epoch: epoch)
// Each chunk has contiguous original 48 kHz coordinates in sourceInterval.
try samples.withUnsafeBufferPointer { input in
    try worker.process(input, interval: sourceInterval) { output in
        let power = output.stage(.powerCepstrum)
        if power.isComplete {
            // Consume synchronously; inspect support and boundary applicability.
        }
    }
}
try worker.finish { output in
    // Includes the explicitly unavailable partial tail, when present.
}
```

## Bounds and evidence

Analysis rates are integer 4–192 kHz; pitch-floor settings are 20–1000 Hz, additionally
bounded by this profile’s 65,536-sample limit (`maximumFrameLength`), independent
of the larger shared framing capacity. Hops are 0.1 ms through physical frame
support, and preview hops must land on the integer analysis grid. Pre-emphasis is
0 Hz through analysis Nyquist. Declared source bandwidth must support analysis
Nyquist; upsampling cannot supply absent bandwidth. Lower-level conditioning limits
are documented in [Conditioning](Conditioning.md). The optional matrix is bounded to
30,000 rows and 16,777,216 scalars. `scalarWorkspaceBytes` counts owned scalar buffers,
excluding object overhead and opaque Accelerate tables; it is not process RSS.

[Reference tools](../Tools/Cepstrum/README.md) describe 41 external-reference cases,
197 selected frames and every intermediate bin, including licensed low-periodicity
speech. Deep-minimum numerical budgets are explicit and separate from ordinary speech;
passing these tests does not imply universal error bounds or clinical validity.
[Evidence](Evidence/cepstrum.md) records observed results and the 38-case host matrix.
Physical capture, device latency, sustained thermal/energy behavior and applicability
measurements remain [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
