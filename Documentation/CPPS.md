# CPPS

CPPS smooths the linear power cepstrum before estimating prominence. Averaging a
history of scalar CPP values is a different statistic. The core module accepts
mono PCM, source timing and explicit configuration; it needs no microphone, audio
engine, UI, reference executable or network.

`CPPSProfile.murtonRecipePraat7` binds the published recipe to Praat **7.0.02**:
60 Hz construction floor, 2 ms hop, 10 kHz analysis, 50 Hz pre-emphasis, no pretrend,
10 ms time and 1 ms quefrency smoothing, 60–330 Hz search, tolerance 0.05,
parabolic interpolation and the pinned straight robust fit. Requested fit bounds
are 0.001–0 seconds; the pinned autowindow resolves to the full quefrency domain,
then excludes q=0. This is not a claim of historical Praat 6 parity.

Every requested setting is serialized, including pitch tolerance, which the
pinned matrix path does not use. The complete conditioning recipe is part of the
identity. Changing the smoothing, fit, hop, source rate or preview conditioning
changes that identity. Population and aggregation settings have their own complete
`CPPSStatisticProfile` identity.

## PCM processing and timing

```swift
let profile = try CPPSProfile.murtonRecipePraat7(
    sourceSampleRate: 48_000,
    declaredInputBandwidthHz: 24_000,
    inputPrecision: .float32)
let processor = try PreparedIntervalCPPS<Float>(profile: profile, source: source)
try pcm.withUnsafeBufferPointer { try processor.append($0, interval: source) }
let completion = try processor.finish { output in
    consume(output.result) // small owned scalar metadata
}
```

`source` is an original-clock `SourceInterval`; appending contiguous chunks is
equivalent to the single append above. Whole-interval conditioning waits for the
declared interval to finish. Its frame dependency support is conservatively that
entire interval, even when the displayed frame center is near the beginning.

For bounded live processing, construct `CepstrogramConfiguration` with
`.streamingPreview(lobes:cutoffFraction:)`, bind it to `CPPSProfile`, and use
`PreparedPreviewCPPS`. That finite-FIR recipe has a distinct identity. Delivery
chunking can change reported delivery delay; it does not change values or frame
positions. Reset for a declared discontinuity clears conditioning, framing,
smoothing and aggregate history. Finish first when old-interval tail results are
wanted; resetting deliberately discards pending frames.

The smoother retains at most `2 * lookaheadFrames + 1` frames. An axis activates
only when `floor(window / gridStep) > 1`. A 10 ms time window on a 2 ms grid needs
the interpolation frame 6 ms ahead. Temporal edges use available-support
normalization; they do not insert zeros into the cepstrogram. Quefrency smoothing
uses the same interpolated integration with the q=0 domain boundary. The declared
lookahead describes the nominal smoothing requirement. Reported preview delay is
computed from the latest dependency delivery time relative to the output frame
center, including the final source boundary when an edge waits for finish. It does
not add lookahead a second time to delays already reflecting those dependencies.

When isolated input frames carry source-clock or host-clock anchors, the smoother
preserves each clock independently and rebases its earliest available anchor to
the combined dependency support. Sample offsets are subtracted in integer space;
host offsets round to the nearest nanosecond with ties to even. An unrepresentable
host timestamp fails with `ContractError.invalidTiming`. Missing anchors remain
absent. Upstream completion timestamps do not become CPPS completion timestamps:
the smoother does not sample a host completion clock.

A short PCM tail is not another sample on the complete-frame grid. Finish first
flushes that grid with its true boundary, then emits the tail as unavailable.
The strict `CPPSCompletion.meanDB` requires every emitted frame to be available.
Its frame counts retain failed/short frames. `PreparedCPPS.receivedFrameCount`
counts complete-grid inputs; its emitted count also includes an optional terminal
short-frame report. Repeated finish does not emit again.

The lower-level `PreparedCPPS.finish` also requires the expected input frame count,
including a terminal short-frame report. PCM wrappers supply their upstream count;
isolated power-object callers supply the object's explicit grid count. An omitted
suffix fails completion and can be supplied before retrying. Constructed power
objects need not inherit the binary64 frame-count rounding of a PCM conversion.

## Selection and aggregation

Use #34's `MaskTimeline` and `PreparedMaskCursor` to preserve original positions.
Each selected region must start independent conditioning and smoothing state.
Never concatenate selected PCM across a gap. `CPPSRegionReport` requires one
completion for every exact selected region and preserves the entire mask plan,
including provenance, exclusions and original selected/eligible/missing duration.

Region-duration weighting averages each available region's frame mean using that
region's original sample count. Equal-frame weighting uses available frame counts
instead; it has a different identity. Regions without a complete result retain
their unavailable status and contribute no observed duration. Partial reports
carry coverage warnings. Overlapping frames never multiply the observed duration.

All-eligible, silence-excluded and voice-only populations are separately identified.
Voice-only requires explicit external selection annotations; a speech-activity
detector does not supply phonetic voicing labels. The current task annotations
remain provisional under [#102](https://github.com/plx/hdxl-voice-processing/issues/102).
Region masking alone does not reproduce every preprocessing step of a published
voice-only analysis protocol.

`PreparedRollingCPPS` maintains a bounded 1–5 second equal-frame statistic. Query
it with an advancing original source clock and the current mask. It floors frame
centers to source-sample ticks and uses a half-open window. Selection is checked
against each frame's **complete dependency support**, including conditioning and
time smoothing. The mask must cover the query window, and the query must be at or
after all observed frame dependencies. Window coverage and the full dependency
union are exported separately.

Current missing/excluded input, the latest unavailable frame, or the absence of a
valid frame in the current selected region suppresses the number. Old values
expire with the window and cannot become a fresh zero. Every result includes the
age of the latest frame. Reset clears all retained scores for a new continuity
epoch. Missing acquisition, exclusion, insufficient input, analysis failure and
staleness are distinct states.

## Diagnostics and numerical scope

Borrowed output is valid only inside its synchronous callback. It separates raw
CPP, original power, optionally pretrend-normalized power, time-smoothed power,
final power, final fitted background/residuals and CPPS. Owned exports are explicit
and scalar-budgeted. Power normalized by a subtracted dB trend is dimensionless;
original cepstral power has inverse-seconds-squared units. Consumer display
smoothing is outside these canonical measurements.

Pretrend clips negative dB residuals before converting back to power, and final
CPP fits again. Consequently, disabling smoothing does not make pretrend strictly
irrelevant on every constructed input. The independently observed behavior and
version-specific decisions are recorded in
[#111](https://github.com/plx/hdxl-voice-processing/issues/111).

The [reference tools](../Tools/CPPS/README.md) define frozen numerical budgets and
separate same-input smoothing checks from whole-PCM comparisons. Explicitly
zero-filled acquisition loss can produce sensitive spectra after noncausal
conditioning. Its unmasked per-frame disagreement remains diagnostic evidence,
not a parity pass; acquired regions are independently conditioned and verified.
See [#112](https://github.com/plx/hdxl-voice-processing/issues/112). A numerical CPPS
value is not a diagnosis or a measure of pleasantness.

These processors are synchronous single-owner workers. Serialize calls and use
them away from capture callbacks. Scalar buffers and record storage are bounded
and exposed separately; opaque FFT tables and object overhead are not included
in those byte counts. Configuration, mask resolution and owned exports allocate
outside prepared processing.
