# Conditioning mono analysis PCM

Conditioning accepts finite mono `Float` or `Double` PCM with explicit rates, bandwidth,
precision, and source coordinates. It never changes the caller's buffer. Keep the original
PCM for levels, harmonic analysis, and any measurement that needs an unfiltered signal.
There is no microphone, AVAudioConverter, UI, or network dependency.

Both implementations are synchronous worker primitives. Prepare them away from the capture
callback; serialize access on one worker. They deliberately are not `Sendable`. Emitted
buffers are borrowed only for the callback. Copy when retention is needed. Output is a
conditioned signal, not a scalar clinical measurement or a claim about vocal intensity.

## Choose the numerical profile

| Property | `praat7WholeInterval(interpolationDepth:)` | `streamingPreview(lobes:cutoffFraction:)` |
| --- | --- | --- |
| Identifier, version 1 | `praat7-whole-interval-conditioning` | `blackman-polyphase-preview-conditioning` |
| Filtering support | Entire declared source interval | Finite FIR plus one prior resample if pre-emphasis is enabled |
| Anti-aliasing | Pinned Praat 7 whole-input Fourier filter | DC-normalized Blackman-windowed sinc |
| Output count | Reference nearest-integer duration × target rate; ties away from zero | Exact floor(N × target/source) |
| First output center | Duration-centered reference grid; special identity and 2× cases | 0.5 / target rate from the input interval's starting edge |
| Boundaries | Reference zero-padded FFT and depth-dependent interpolation | Explicit leading/trailing zero extension |
| Delivery | After the complete interval | When FIR lookahead is available; bounded borrowed blocks |
| Delay | Half the entire input duration, excluding computation | Recorded per block from the target-block midpoint to consumed input time; excludes host scheduling/computation |

The profiles intentionally produce different samples, counts, and boundary behavior. Do not
use preview output as evidence of Praat parity. Profile identity hashes the complete validated
`ConditioningConfiguration`; results serialize it through their layout. Preview output block
capacity controls delivery, is serialized in the layout, and does not change numerical identity.

## Pre-emphasis and gain

After resampling, the raw filter is

```
a = exp(-2π × preEmphasisFromHz / targetSampleRate)
y[0] = x[0]
y[n] = x[n] - a × x[n-1]
```

`nil` disables pre-emphasis; zero requests a first difference. Finite nonnegative frequencies
are accepted, including high values whose coefficient underflows to zero. Coefficients are
prepared in binary64 and rounded once to the working precision. The first sample has no
prehistory; reset discards both FIR and pre-emphasis history. Processing chunks does not reset
that history. No peak, RMS, or vocal-intensity normalization is applied (`gainPolicy: none`).

The [Praat manual's filter equation](https://www.fon.hum.uva.nl/praat/manual/Sound__Pre-emphasize__in-place____.html)
is the raw operation. In pinned Praat 7.0.02, **both menu commands also scale peak amplitude to
0.99**, including the in-place menu command. Internal analysis code uses the raw operation.
The independent fixtures therefore combine external resampling with an original scalar
implementation of the published equation. A separate seven-sample calibration records the
menu scaling. [Attention #97](https://github.com/plx/hdxl-voice-processing/issues/97) tracks this
API/documentation distinction. Multiplying a source by two multiplies output by two; changing
its harmonic balance is separately tested and is not described as an amplitude adjustment.

## Reference whole-interval behavior

`PreparedIntervalConditioner` prepares a fixed positive input count. Append any contiguous
partition of that declared `SourceInterval`, then call `finish`. No output is emitted before
all input is received. Repeated finish returns the same metadata without another callback.
`reset(source:)` reuses storage for a new separately conditioned interval of the same size and
rate; prepare a new plan to change size or profile. Unknown-duration recordings must retain
original PCM until a whole interval can be declared.

Downsampling pads 1,000 samples before the original input and at least 1,000 afterward, using
the next power-of-two Fourier length. The reference cutoff is defined on its packed real-FFT
component order, so its last partially retained bin can preserve a cosine component while
removing its sine component. The native canonical complex representation reproduces that
observed projection. This is a reference compatibility rule, not a substitute ideal filter.

General interpolation uses the duration-centered grid. Explicit depth 1 uses linear
interpolation with zero outside its eligible adjacent pair. Larger depths clamp outside
endpoints, return exact integer positions unchanged, and reduce depth symmetrically near
ends: linear at effective depth 1, cubic Hermite at 2, and sinc multiplied by a raised-cosine
window with denominator `depth + 0.5` at 3 or higher. These reference weights are not
renormalized for DC. Identity rates copy input. The special 2× reference branch applies its
high-frequency packed-component taper and zero-extends the Fourier grid; its observed phase
is covered by independent fixtures. No GPL implementation code is embedded in the package.

`ConditionedInterval.timing.source` is the **original** full source interval. It never becomes
a target-rate interval. `layout.outputCenterSeconds(at:)` is relative to the original starting
edge. Large absolute source positions remain exact integers; conversion to absolute seconds
is necessarily approximate. The output's reference domain retains the source duration even
when output count is rounded.

## Streaming preview support and boundaries

A preview plan uses half-width `ceil(lobes / min(1, target/source))` in source samples. The
kernel is a sinc with cutoff `cutoffFraction × min(sourceRate, targetRate) / 2`, multiplied by
a symmetric Blackman window and normalized independently for each rational phase. Coefficient
preparation uses binary64. Float execution uses Float coefficients, convolution, and filter state.

The target clock uses exact quotient/remainder arithmetic for
`((j + 0.5) × sourceRate / targetRate - 0.5)` in source sample-center coordinates. It never adds
floating-point time steps or multiplies the absolute source origin by a rate. Its phase period
is the reduced ratio numerator. A mirrored finite history and prepared coefficient/output
buffers avoid growing storage during processing. At finish, only enough zeros to evaluate the
remaining `floor(N × target/source)` outputs are supplied; padding does not increase observed
source count.

`PreviewConditionedBlock` records the numerical layout, original zero-length origin, separate
target index/count, delivery input count, original source support, finalization state, and
leading/trailing zero-extension flags. Pre-emphasized support includes the preceding raw
resampled value's FIR support. `usesBoundaryExtension` means a downstream algorithm must make
an explicit applicability decision; boundary-extended values are not automatically valid
measurements. Empty or too-short streams finish with `hasOutput == false`, not a fabricated
zero-valued measurement. The completion count includes any explicitly labelled boundary samples.

`maximumFilterLookaheadSeconds` is `(radius + 0.5) / sourceRate`, an upper bound from the target
center to acquisition of the FIR's rightmost sample. Output batching adds delivery latency.
Each block's `timing.effectiveDelaySeconds` instead records its actual input-clock delay,
including batching, from the block's target midpoint. At finalization, known trailing zeros
require no physical acquisition time. Pre-emphasis adds previous-sample support but no future
lookahead; its frequency-dependent phase is not represented as a constant extra delay.

## Continuity, errors, and limits

Each input chunk must match the expected epoch, rate, original starting sample, and count.
Invalid metadata or nonfinite samples reject the whole chunk before mutation. A gap is an
error; explicitly reset to acknowledge a separately conditioned interval. Preview reset takes
an explicit epoch and origin and discards pending history. Whole-interval reset takes a new
full source interval. Cancellation releases storage and prevents further processing. Cancellation
from an emitter preserves the active borrow until the callback returns; preview reports the
consumed prefix. Recursive process/finish/reset throws `reentrantCall`.

Nonfinite numerical output moves the plan to a failed state without emitting that block.
Previously emitted blocks remain delivered. Explicit reset can recover a failed plan; a
cancelled plan requires a new preparation. Configuration, layouts, and result records use
strict versioned decoding and validate derived geometry and timing, rejecting inconsistent data.

- Source and target rates: integer Hz, 4,000–192,000; never rounded to a supported rate.
- Whole interval: at most 2,880,000 input samples and 4,194,304 output/FFT samples. A 2× inverse
  can exceed the FFT bound even when output count fits; this is rejected explicitly.
- Whole-interval interpolation depth: 1–128. Phases with numerator ≤4,096 are cached; larger
  numerators use prepared scratch storage and per-output coefficient evaluation.
- Preview: 8–64 lobes, cutoff fraction 0.5–0.98, reduced numerator ≤4,096, at most 1,048,576
  cached coefficients, output capacity 1–4,096, at most 2^48 source samples per continuity interval.
- Declared source bandwidth must be positive and no greater than source Nyquist. Required
  analysis bandwidth must fit both declared source bandwidth and target Nyquist. Upsampling
  cannot add absent bandwidth. These checks do not certify physical microphone bandwidth or
  promise a flat response up to the declared limit.

Unsupported choices throw a specific `ConditioningError`. Float/Double precision mismatch is
an error. `scalarWorkspaceBytes` reports owned scalar buffers, excluding object/allocator
bookkeeping and opaque Accelerate setup. Zero returned after cancellation means buffers were
released; it is not a process RSS claim.

## Example

```swift
let configuration = try ConditioningConfiguration(
    sourceSampleRate: 48_000, targetSampleRate: 10_000, precision: .float32,
    method: .streamingPreview(lobes: 32, cutoffFraction: 0.9),
    preEmphasisFromHz: 50, declaredInputBandwidthHz: 20_000,
    requiredInputBandwidthHz: 4_000)
let layout = try PreviewConditioningLayout(configuration: configuration)
let epoch = StreamEpoch(streamID: UUID())
let conditioner = try PreparedPreviewConditioner<Float>(layout: layout, epoch: epoch)
// On the serialized analysis worker, for each original contiguous chunk:
try samples.withUnsafeBufferPointer { input in
    try conditioner.process(input, interval: sourceInterval) { conditioned, support in
        // Consume synchronously; inspect support.usesBoundaryExtension before measurement.
    }
}
try conditioner.finish { tail, support in
    // Trailing extension is explicitly represented in support.
}
```

## Validation and performance

`Fixtures/Conditioning/praat.json` contains 184 cases generated with the pinned external Praat
binary and precision-rounded original inputs. Small vectors are complete; larger vectors use
64 independently exported positions and predecessor values. Cases include impulses, steps, DC,
pass/stop tones, sweeps, seeded noise, short boundaries, count ties, depths, identity, 2×,
pre-emphasis frequencies, gain scaling, and 60-second 16/44.1/48 kHz inputs. Reference axes have
a 1e-12-second budget; native absolute sample budgets are 2e-5 for Float and
`max(2e-12, 32 × ulp(1) × sourceCount)` for Double. Budgets are committed independently of native
outputs. Original input hashes are checked before and after processing.

Preview tests use a separate uncached scalar convolution on absolute target times, with
independent raw pre-emphasis. They cover both precisions, quality extremes, integer clocks,
large origins, resets/gaps, sample counts, exact support examples, cancellation, passband phase,
alias rejection, and a 60-second stream. The default 32-lobe/0.9 profile is tested below 0.0002
maximum passband waveform error through 4 kHz and beyond 70 dB rejection at 5.5 kHz/near source
Nyquist for the three input rates to 10 kHz. These bounds do not apply to every configurable
quality choice.

Run `python3 Tools/Conditioning/reference.py` to compare fresh pinned external outputs. Normal
correctness CI remains offline and validates committed fixtures/provenance. Reference regeneration
CI repeats the external comparison. `python3 Tools/Conditioning/benchmark.py timing` and
`allocation` measure 120 configurations, preparation, conditioning, and conditioning-plus-FFT
with separate timing/allocator binaries and positive allocation/ARC controls. See
[conditioning evidence](Evidence/conditioning.md). Diagnostics reuse the worker's frame budget
and emit `Resample`, nested `FFT`, and `PreEmphasis` intervals; they do not log PCM or per-sample events.

Physical evidence remains under [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
[Attention #98](https://github.com/plx/hdxl-voice-processing/issues/98) records policy choices to
revisit after those measurements; neither is a physical-evidence gate on initial bring-up.
