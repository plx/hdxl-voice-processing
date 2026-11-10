# Deterministic framing and windows

`PCMFramer<Float>` and `PCMFramer<Double>` operate on finite mono analysis PCM.
Channel selection and resampling happen upstream. Values after pre-emphasis may
exceed ±1. The primitive has no audio-engine, microphone, UI, file, or network
dependency. It emits observed sample buffers, not scalar voice measurements, so
it follows the lifecycle of `PCMProcessor` without claiming that conformance.

## The integer sample grid

For input beginning at sample `S`, first-frame offset `O`, frame length `N`, hop
`H`, and ordinal `k`, the half-open frame is `[S + O + k*H, S + O + k*H + N)`.
A frame becomes eligible only after its entire observed support arrives. Given
`L` contiguous input samples, the complete count is zero when `L < O + N`, and
`1 + (L - O - N) / H` otherwise, using integer division. The grid never changes
when a caller changes chunk sizes or finishes the stream. Hops larger than the
frame are allowed: samples between frames remain observed input but do not
contribute to a frame. An offset may similarly leave an unframed prefix.

These examples use `S=O=0`, requested support 25 ms, requested hop 2 ms, and
nearest rounding with ties away from zero:

| Rate | N | H | First three intervals | Actual support / hop |
| --- | ---: | ---: | --- | --- |
| 16 kHz | 400 | 32 | [0,400), [32,432), [64,464) | 25 / 2 ms |
| 44.1 kHz | 1103 | 88 | [0,1103), [88,1191), [176,1279) | 25.011338 / 1.995465 ms |
| 48 kHz | 1200 | 96 | [0,1200), [96,1296), [192,1392) | 25 / 2 ms |

`SampleCountQuantization` records the requested seconds, sample rate, rounding
rule, integer count, actual seconds, and error. It rounds the binary64 product
`seconds * sampleRate` once; it does not imply exact decimal or rational-time
arithmetic. A fixed 88-sample hop at 44.1 kHz has a declared quantization error
relative to 2 ms. Integer indices prevent additional accumulated floating-point
drift; they do not remove that quantization error. Pure grid helpers test hour-long
timelines without allocating audio. Absolute floating-point timestamps eventually
lose precision; `SourceInterval`'s integer indices remain authoritative.

This grid differs from Praat's whole-segment-centered CPPS grid, whose alignment
depends on the final segment length and whose floating-time eligibility can differ
at boundaries. `firstFrameOffsetSamples` allows an explicit integer anchor; it
does not implement every Praat alignment rule. A downstream named CPPS recipe must
select its own reference alignment before claiming reference parity. See
[the reference recipe](Evidence/references.md) and [attention issue #91](https://github.com/plx/hdxl-voice-processing/issues/91).

## Lifecycle, tails, and ownership

Construction prepares a cached window, an N-sample ring, and an N-sample emission
buffer. The maximum N is 131,072; H is 1...Int32.max and O is 0...Int32.max.
The larger bound supports the longest SWIPE-prime window (192 kHz, 20 Hz floor).
`preparedBufferBytes` reports these three sample payloads: at the limit, 1,572,864
bytes for Float and 3,145,728 bytes for Double, excluding object/allocator overhead.
Reset reuses the payloads; cancellation drops ownership and reports zero (an active
synchronous borrow remains valid until its callback returns). Bounded 64-bit
sample-buffer arithmetic cannot overflow at this limit; timeline advances retain
their separate checked Int64 arithmetic. Existing version-1 definitions and
configuration identities are unchanged for previously accepted sizes.
Configuration identities include window definition/version, count, rate, precision,
hop, offset, and tail policy. Projection initializers from `AnalysisProfile`
validate only framing/window fields; the consuming algorithm validates its full
profile. No implicit channel selection is performed.

`process` validates interval rate, epoch, contiguity, sample count, and every finite
sample before changing state. Empty matching buffers are valid no-ops. A gap must
be represented by `SourceDiscontinuity` and `reset(for:)`; an unexpected position
is rejected. Reset discards pending support and starts position zero in the new
epoch, reusing storage. A known missing interval must start at the old next-input
position with the old analysis sample rate. No pre-gap samples can complete a
post-gap frame. `reconfigure` prepares replacement state before committing it;
failure preserves the old worker. The new epoch must be the next same-stream
epoch or epoch zero of a different stream.

`finish` returns unique observed input support, the complete frame count, and an
explicit disposition. Empty input yields `.empty`; input wholly before the first
eligible start yields `.noEligibleFrame`. With a pending partial frame, `.discard`
reports `.discardedPartial` without emitting, while `.emitUnavailable` emits only
the earliest incomplete grid frame with actual observed samples and
`.insufficientData`, then reports `.unavailablePartial`. There is no zero padding
in a framer callback. For N=4, H=2, and input `[0,1,2,3]`, the complete frame is
`[0,4)` and the unavailable tail is `[2,4)`. Further overlapping partial starts
are not emitted. Repeated finish returns the same report and emits nothing.

A callback's pointer is borrowed only until that callback returns. Copying it to
an owned array is an explicit consumer choice outside the no-allocation claim.
Do not reenter process/reset/reconfigure/finish from an emitter. Cooperative
`cancel()` is allowed: storage survives the current borrow and is then released;
the process report identifies the consumed prefix. Cancel is idempotent. Reset
after cancellation allocates new storage. A worker is intentionally not Sendable;
serialize access and run it on a worker, never in a real-time capture callback.

Frame eligibility is geometric, not evidence of voice, silence, or a valid scalar
estimate. Overlapping frame/tail durations must not be summed as unique coverage.
`observedCenterSeconds` describes actual observed support, including a shorter
partial tail. It is separate from processing completion time and effective delay.

## Exact window definitions

For zero-based sample `n`, use `D=N` for periodic windows and `D=N-1` for symmetric
windows. Definitions are version 1, with no gain normalization:

| Identifier | Coefficient |
| --- | --- |
| `rectangular` | 1 |
| `hann-periodic`, `hann-symmetric` | `0.5 - 0.5*cos(2*pi*n/D)` |
| `hamming-periodic`, `hamming-symmetric` | `0.54 - 0.46*cos(2*pi*n/D)` |
| `praat-gaussian-2-physical` | `u=(2*n+1-N)/N`; `(exp(-12*u*u)-exp(-12))/(1-exp(-12))` |

All N=1 windows explicitly equal `[1]`. Symmetric Hann at N=2 is `[0,0]`, with
zero gain; downstream gain correction must handle that degeneracy. Float32
coefficients are rounded from the declared binary64 calculation. Reported coherent
gain is `sum(w)/N`, and energy gain is `sum(w*w)/N`, accumulated as Double from the
actual prepared precision. Energy gain is not the square root or an applied
amplitude correction. Symmetric and periodic windows have different identities.
Praat's half-sample Hann/Hamming conventions are not aliases for these definitions.

Gaussian nominal physical support is `N/sampleRate`, with effective duration half
that value; the endpoint coefficients are positive. This matches the selected
Gaussian2 definition, not an arbitrary Gaussian parameterization. The
[Praat formant manual](https://www.fon.hum.uva.nl/praat/manual/Sound__To_Formant__burg____.html)
explains effective versus physical duration; the
[PowerCepstrogram manual](https://www.fon.hum.uva.nl/praat/manual/Sound__To_PowerCepstrogram___.html)
specifies the effective `3/pitchFloor` analysis window. Original implementation
equations were checked through the pinned 7.0.02 CLI and independent 70-digit
Decimal arithmetic. No reference implementation source is copied or linked.

`PreparedWindow.write` requires input length ≤N and destination length ≥N. It
multiplies the observed prefix, zeroes missing window positions, then zeroes any
additional transform padding. Its report distinguishes all three counts; missing
window positions yield `.insufficientData`. Neither kind of padding is observed
silence or duration. Exact in-place operation is supported; partial overlap and
nonfinite input are rejected before any output write. The caller owns an exclusive
valid output buffer. Window coefficients can be shared immutably; snapshots are
explicit debug output. Pre-emphasis, de-meaning, and transform ordering remain the
consumer's declared algorithm, not implicit framer behavior.

## Validation and measurement

`swift test --filter 'framing|window'` runs integer-slice oracles, all-position
impulses, constants, empty/short/tail cases, one-shot/prime/alternating/seeded
partitions, explicit gaps, restart/reconfiguration, cancellation, overlap rejection,
large integer positions, hand windows, and pinned Gaussian coefficients. The
default test run needs no reference executable. Regenerate/verify the black-box
fixture using `Tools/Framing/reference.py`; see [its developer guide](../Tools/Framing/README.md).

The isolated benchmark matrix covers Float32/Float64, 20/50/100 ms Gaussian support,
2/5/10/30 ms requested hops at 16/44.1/48 kHz, maximum support at all rates, and
every other window shape at 48 kHz. It separates setup/destruction, cached window
writes, resets, whole-input processing, and 17-sample chunks. Metadata records
actual rounded lengths, profile identities, input duration, hardware, and exact
operation counts. Timing runs disable allocator instrumentation; allocation runs
require a positive malloc/ARC control and zero maximum observed allocations in
every steady-state histogram. Setup, reconfiguration, cancellation recovery,
diagnostic sinks, and consumer-owned copies are outside that allocation claim.

Worker diagnostics wrap each completed/partial frame's ring-to-emission copy in
bounded `FrameAssembly`/`AnalysisFrame` scopes. Input validation/ring ingestion and
consumer callbacks are outside those scopes; whole-call benchmarks include them.
Metadata contains sequence, sample count, geometry status, and process-local token
24, never PCM. Disabled diagnostics are the default; sampled/detailed modes retain
the shared instrumentation policy. Host benchmark evidence is not physical-device
evidence; [#74](https://github.com/plx/hdxl-voice-processing/issues/74) retains that work.
The [A01 evidence record](Evidence/framing.md) summarizes correctness, allocation
controls, and representative host timings.
