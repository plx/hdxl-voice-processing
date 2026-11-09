# Internal instrumentation

`WorkerDiagnostics` is a package-scoped, synchronous, single-owner facade. It is
shared by root-package targets without becoming public consumer API. Every
analyzer creates its own instance on a worker/control path. It defaults to
`disabled`; applications do not acquire microphone permissions or configure
logging by importing core. There are no external runtime dependencies.

`PreparedYIN` uses a `Pitch` interval with profile token 38, frame index, observed
sample count and full/partial geometry status. Accelerate kernel `FFT` spans nest
inside it. Optional candidate tracking has a separate `PitchTracking` interval
and token 3801. Framing, estimation and tracking each finish their scoped work
before invoking downstream consumers. Whole-frame sampling admits indices 0,16,…;
there are no per-lag/sample events or audio payloads. Streaming tests check balanced
intervals, partial metadata, reset epochs and callback cancellation in all modes.
See [YIN](YIN.md) for the distinction between current-frame and history-dependency
timing; neither signpost duration is physical capture latency.

The implementation follows [Apple OSSignposter](https://developer.apple.com/documentation/os/ossignposter)
and [Recording Performance Data](https://developer.apple.com/documentation/os/recording-performance-data).
The current macOS/iOS 27 deployment floor supports this API. `canImport(os)` and
`HDXL_DISABLE_SIGNPOSTS` guard the system sink; the same computations still run
when that sink is unavailable. The fallback is exercised with the current Swift
6.4 toolchain, not claimed as support for older deployment targets or other OSes.

## Modes and bounds

- **Disabled:** no sink construction, signpost calls, per-frame ID generation,
  or diagnostic counter updates. Construct the facade before processing; session
  allocation uses a control-path mutex even for a disabled instance.
- **Sampled:** select frame sequences divisible by 16, including frame zero.
  All nested stages use that selection; no independently sampled end calls.
- **Detailed:** select every frame. This is opt-in diagnostic work, not a normal
  capture mode.

Both active modes admit at most 64 starts/events per frame and eight concurrent
nested intervals. Ends are reserved by their accepted starts and never compete
for that budget. There is no application-side queue of diagnostic records.
Control events before/between frames use the remaining budget; initialization
starts with 64 slots, and only entry to a nonnested frame refreshes it. A control
event storm therefore exhausts the budget until the next frame. Nested frame
entry executes its body with the enclosing context and does not refresh limits.

`counts` contains saturating totals of submitted interval starts, submitted
events, suppressed records (sampling/budget/depth/identity exhaustion), and
unavailable records (no enabled sink). Submitted means the API accepted the call,
not that Instruments persisted it. The OS may discard records; trace validation
must detect missing intervals. No counters silently become unsupported zeros.

A session ID is a process-local monotonically allocated UInt64. Each record has
a session-local increasing span ID and a reset epoch. Exhaustion disables future
records rather than reusing an identity. Actual OS intervals additionally use
`makeSignpostID()` rather than `.exclusive`. `withInterval` closes its captured
state in `defer`, including early return, throw, cooperative cancellation, and a
reset inside the scope. Existing spans keep their starting epoch; subsequent
records use the incremented epoch. There is no API for an interval across an
`await`: asynchronous orchestration surrounds synchronous worker turns.

## Event dictionary

Subsystem: **`org.hdxl.voice-processing`**. Names are explicit `StaticString`
literals. The following vocabulary is reserved as implementations arrive; the
synthetic probe does not claim to implement the named DSP algorithms.

| Category | Names | Meaning/boundary |
| --- | --- | --- |
| lifecycle | Initialize, Reset, RouteChange, ConfigurationChange | Worker/control lifecycle observations |
| flow | CaptureHandoff, Dequeue | Worker observation of a delivered block, never a capture callback span |
| flow | QueueWait | Worker-side bookkeeping span; actual queue residence comes from timestamps in `queue_ns` |
| flow | Overrun, Drop | Worker observation of explicit discontinuity/drop information |
| worker | AnalysisFrame | One admitted synchronous synthetic/analysis worker turn |
| worker | Resample, PreEmphasis, FrameAssembly | Conditioning and frame assembly work |
| worker | FFT, Cepstrum, CPP, CPPSSmoothing, CPPSFitting, CPPSAggregation | Numerical scopes; CPPS boundaries below |
| worker | Pitch, HNR, Pulses, Perturbation | Algorithm scopes; integration details below |
| worker | SpeechActivity, MaskIntervals, EnergyEligibility, MaskResolution, MaskRouting | Mask worker/control stages; precise boundaries below |
| worker | ResultPublication | Worker-side result construction/publication work |
| worker | FeedbackStateChange | A personal-feedback state/reason/feature/model change; no personal values |
| delivery | ResultDelivery | Consumer observation bookkeeping; subscriber lag is timestamp-derived |
| rendering | Rendering | Explicit synchronous host rendering work, not display presentation |
| worker | Error, Cancelled | Worker outcomes with numeric validity reasons |

Begin/event payloads use only the following numeric fields. Ends carry no extra
payload. The facade cannot accept arbitrary messages, PCM, transcripts, paths,
calibration values, or dynamically formatted names.

| Field | Unit/meaning |
| --- | --- |
| session, epoch, span | Process-local diagnostic identities, not user identifiers |
| profile | Ephemeral numeric token assigned by the control plane; resolve to an approved algorithm profile outside the trace, never a personal label/hash |
| frame | Frame sequence within the analysis stream; UInt64.max outside a frame |
| samples | Samples per channel in the frame |
| depth | Queue depth in blocks, not nesting depth |
| validity | 0 unspecified, 1 available, 2 warmup, 3 discontinuity, 4 invalid input, 5 cancelled, 6 failed |
| processed | Count of completed processing turns before this one |
| queue_ns | Timestamp-derived queue residence in nanoseconds; UInt64.max means unavailable, while zero is a valid measured delay |

Call `event(_:validity:)` inside the frame scope when reporting frame failures.
Metadata is a copied value and is never read back into analysis configuration or
outputs. Profile/window configuration and numeric validity remain the analysis
implementation's responsibility.

## Capture callback policy

`CaptureDiagnostics` is a 28-byte payload (32-byte stride) of scalar counters and
one supplied host timestamp. Construct it before capture begins. Its `record`
method has bounded saturating arithmetic and stores only: callback count,
dropped-frame count, last host timestamp, and largest block size. It reads no
clock, constructs no interval state or string, generates no ID, locks nothing,
creates no task, and dispatches nothing. The release wrapper inspects its arm64
machine code and rejects calls, unsupported instructions, and backward branches.

Only the producer may mutate it. Copy its value through the eventual production
handoff header, or inspect it after capture has stopped; concurrent unsynchronized
reads are forbidden. This issue provides the diagnostic primitive, not the later
PCM handoff or capture implementation. There is no opt-in callback signposting
path. Use Audio Client instrumentation for callback behavior. Worker spans and
queue timestamps must never be relabeled as capture-time spans.

## Reproduce the evidence

Run from the repository root:

```sh
python3 Tools/instrumentation.py
python3 Tools/instrumentation.py --compiled-out
python3 Tools/trace-instrumentation.py
python3 Tools/trace-instrumentation.py --overhead
```

The first two commands need Swift/Xcode and Python only, not the benchmark
framework. They build release `InstrumentationProbe`, warm each path, rotate
four mode orders over eight trials of 10,000 frames, independently verify the
UInt64 workload checksum, check exact emission/sampling counts, and retain raw
trials plus min/median/max and paired differences from bare execution. They also
inspect the optimized callback counter routine. Results live under
`.build/instrumentation-artifacts/`. Timings are observations, not CI thresholds.
The normal probe checks enabled API calls; it does not infer that a recorder is
attached. The trace overhead command separately records the same probe.

The last two commands require local Instruments recording permission. They use
the Logging template and target only the synthetic executable. Pairing validation
checks all 128 intervals, two actually overlapping sessions, resets, cancellation,
errors, overruns, configuration changes, and numeric-only metadata. Its source is
synthetic integer work, with a trace-only sleep to expose overlap. FFT is a label
exercising the facade, not an FFT implementation. `queue_ns=123` in this probe is
explicitly simulated, not a measured queue latency.

Raw `.trace`/XML files under each `private/` directory may include host/process
metadata added by Instruments. Keep them local. Share only the JSON summaries,
trials, redacted command logs, and audited assembly; CI uploads these from the
system and compiled-out modes only. The bounded test sink independently verifies
pairing and task cancellation. `PCMFramer` now uses bounded `FrameAssembly` scopes
for each ring-to-emission copy, nested in a frame scope with token 24, ordinal,
sample count, and full/partial geometry status. Validation, input ring ingestion,
and consumer callbacks are outside these scopes. Its unit tests verify exact
mode counts, callback boundaries, and equal samples across modes. See
[framing measurements](../Tools/Framing/README.md) for full-call timing and
default-disabled allocation evidence. Broader production adoption and integrated
overhead remain #56/#62; sustained physical measurements remain #74.

`PreparedFourierTransform` accepts the same worker facade through a package-scoped
initializer. Its `FFT` scopes cover the Accelerate kernel only; packing, validation,
scaling, and conversion costs remain visible in full-call benchmark rows. It uses
the caller's enclosing frame metadata, with no new per-sample events. Tests verify
matching scope pairs and that rejected input emits no kernel interval. See the
[Fourier guide](FourierTransforms.md) and [workload matrix](../Tools/Fourier/README.md).

### Conditioning kernels (A03)

Both prepared conditioners accept the worker facade through package-scoped initializers.
They reuse its frame context and budget: `Resample` surrounds source processing or whole-interval
conversion, `FFT` nests for reference global filtering, and `PreEmphasis` surrounds each emitted
block's raw filter (one whole block for a reference interval). There are no PCM payloads or
per-sample events. Tiny output capacities still obey the shared 64-start/event budget; a test
checks bounded, balanced spans even at capacity one. Input validation occurs before these spans.
Disabled/default instrumentation is used in timing/allocation workloads. See the
[conditioning guide](Conditioning.md) and [workload matrix](../Tools/Conditioning/README.md).

Conditioning kernel spans end before invoking the borrowed-buffer consumer. Downstream FFT
or other analysis therefore does not become resampler time; tests assert this at callback entry.

### Digital levels and K-weighting (A04)

`PreparedLevelAnalyzer` uses `AnalysisFrame` with profile token 32 and the emitted grid index.
`LevelEnergy` surrounds ingestion of newly pending samples and window aggregation;
`KWeighting` surrounds the two-stage continuous filter over those samples. A complete first
window processes N samples; subsequent windows process H new samples, independent of input
chunking. At most four intervals occur per emitted window. All end before the owned-result
consumer runs. Validation and pending input copies are outside these scopes and remain part
of full-call benchmark timing. No per-sample events or PCM payloads are emitted.
Tests check exact sampling counts, numeric metadata, exception pairing, reset epochs, and
callback boundaries. See [the level guide](DigitalLevels.md) and [workloads](../Tools/Levels/README.md).

## Voice corpus loading

The test-only corpus benchmark uses `FixtureLoad` around warm-cache `Data` reads and
`FixtureDecode` around preloaded RIFF validation and owned Float64 decoding. Preparation,
hash checks, compilation and full-output consumption occur outside these intervals.
Each trial opens a fresh worker diagnostic frame with a process-local subset token
2700–2703, ordinal and aggregate sample count. Signposts contain no paths, source IDs,
transcripts or PCM. These scopes describe fixture handling, not analysis or capture
latency. See [VoiceCorpus.md](VoiceCorpus.md) for the four stable subsets and explicit
allocation-evidence limits. Production callback adoption remains in its own workstream.

## Cepstral worker scopes

The prepared power-cepstrum kernel uses sampled `analysisFrame` → `cepstrum` scopes
with separate forward/inverse `fft` spans. Metadata uses stable token 33, frame
sequence, supplied sample count and support availability. Spans end before the
borrowed-output consumer executes, so owned export cost is not attributed to the
transform. The preview pipeline additionally uses block-level `preEmphasis` and
existing conditioning/framing scopes. Whole-interval conditioning retains its own
whole-input scope. No PCM, participant identity or per-sample event is logged.

`CepstrumDiagnosticsTests` verifies balanced nested scopes, frame sampling at
indices 0 and 16, and consumer exclusion. The dedicated 38-case benchmark matrix
separates construction, prepared checksum consumption and explicit owned exports;
these observations do not replace Instruments/device capture tracked under #74.

## Mask worker integration

`PreparedLTSFDetector` uses token 34. Each instantaneous spectrum and the temporal
features that become ready during it are enclosed in `SpeechActivity`, with the
existing nested `FFT` span. `MaskIntervals` encloses final feature flushing,
relative-intensity thresholding and interval cleanup/combination. Its frame
sequence is zero so sampled mode admits finalization. Final selection still waits
for the complete declared source; these spans measure worker computation, not
acoustic or capture latency.

`PreparedEnergyEligibility` uses token 3401. `EnergyEligibility` encloses each
consumed window fragment, its scaled energy update and any completed-window state
transition. The diagnostic sequence counts consumed fragments, so chunk delivery
changes diagnostic sampling, while numerical windows and outputs remain invariant.
`PreparedMaskCursor` uses token 3402. `MaskRouting` encloses construction of each
borrowed slice's source/region context, with a monotonic slice sequence. It excludes
input validation, skipped-region scanning and consumer analysis. Full routing cost
is measured by the complete benchmark operation. `MaskResolution` uses token 3403
and encloses the complete allocating event sweep, region construction and coverage
calculation on the control path; its sequence is zero.

Every stage is nested in `AnalysisFrame`. The `samples` field counts the physical
frame, consumed energy fragment, routed slice or complete source, respectively;
whole-source counts saturate at UInt32.max. These numeric tokens carry no labels,
model identifiers, PCM or paths. All intervals end before borrowed output callbacks;
reset and idempotent cancellation use the existing lifecycle events. Tests cover
balanced pairing, sampling, reset epochs, consumer boundaries and identical output
values across all three modes. Integrated active-trace overhead and physical
capture evidence remain in #56/#62 and #74; mask performance baselines use disabled
diagnostics.

## CPPS worker integration

`PreparedCPPS` uses profile token 37 and the original frame index for
`CPPSSmoothing`, covering time integration followed by quefrency integration.
The final `PreparedCPP` kernel uses `CPPSFitting` with token 37. Its scope closes
before the borrowed result is delivered. The unsmoothed diagnostic fit retains
`CPP` and token 35. Each numerical scope has a frame sampling boundary, so sampled
mode admits only frame indices divisible by 16, including delayed finish output.

`PreparedRollingCPPS.result` uses `CPPSAggregation`, token 3701, the latest frame
index, and retained record count. It measures mask membership, coverage unions,
freshness decisions and the compensated mean. No PCM, cepstral arrays, labels,
source UUIDs or user-provided strings enter diagnostic metadata. Immutable
region-report construction is an owned control-plane operation.

`CPPSDiagnosticsTests` checks disabled/sampled/detailed numerical equality,
frame sampling, balanced scopes and completion before consumer callbacks.
The [CPPS benchmark protocol](../Tools/CPPS/README.md#host-performance-matrix)
measures complete pipelines with diagnostics disabled; its allocation mode is a
separate binary. Physical capture and device traces remain tracked by #74.

## HNR worker integration

HNR uses profile token 39 and original frame indices. `HNRNormalization` measures
one complete acquired reference: once for a whole interval, or once per admitted
causal frame. `HNRWindow` includes scale, mean, window, intensity and forward-pair
preparation. `HNRCorrelation` includes the method-specific FFT correlation and
normalization; `HNRPeriodSearch` includes candidate detection, interpolation,
refinement and final selection. `HNR` encloses the last three stages. Normalization
is separate from per-frame computation and retains its full dependency sample
count. Silent frames skip correlation/search. Whole-frame sampling admits all
sub-stages together; every scope ends before the consumer callback, including
failure and cancellation. Disabled mode uses the same numerical path without a
sink. Metadata is numeric only; no PCM or candidate curves enter signposts.

`HNRDiagnosticsTests` verifies sampled/detailed coverage, exact disabled-mode
results, failure balance and consumer/cancellation/reset boundaries. The separate
[HNR stage probe](../Tools/HNR/README.md#host-performance-matrix) reports inclusive
stage cost and its clock/lock overhead alongside disabled full-batch trials.

## Pulse worker integration

Pulse tracking uses profile token 42 and the complete interval's analyzed sequence
number and acquired sample count. `Pulses` encloses waveform tracking and sequence
construction. `PulseMatching` includes each finite lag table and peak selection;
`PulseInterpolation` refines a selected peak and is absent when no peak was
selected. `PulseSequences` constructs runs, periods, pairs, and cycle amplitudes.
`ResultPublication` starts after `Pulses` ends, keeping consumer work separate.
No PCM, F0 arrays, pulse coordinates, or per-sample events enter signposts.

Whole-frame sampling and the shared 64-record budget remain in force. A long
interval can exhaust the budget before later attempts, sequence construction, or
publication; its signposts are therefore not an unbiased per-cycle distribution.
`PulseDiagnosticsTests` checks numerical equality, balanced failure/publication
scopes, and reset behavior after exhaustion.

The [pulse stage probe](../Tools/Pulses/README.md#host-performance-matrix) replays
every actual attempted kernel call with a separate diagnostic frame for each
attempt. This is a developer measurement recipe, not a change to production
sampling. It retains accepted/rejected and eligible/ineligible groups separately,
checks identical results with instrumentation disabled, and reports clock/lock
overhead explicitly. Missing samples are null; a measured zero duration means
the call completed below the clock's resolution. Complete analyzer throughput
and allocation measurements come from the separate public-worker benchmark.
