# Shared PCM scheduling

`PreparedAnalysisSchedule<Float/Double>` feeds Levels, YIN/tracker, CPP/CPPS, HNR and
optional SWIPE-prime kernels from one synchronous worker. Memory, file and transport adapters use
the same engine. Configure every enabled numerical recipe explicitly: “light” and
“full” describe benchmark compositions, not universal measurement presets.

## Preparing and supplying PCM

An `AnalysisScheduleProfile` contains the actual input `PCMFormat`, channel selection,
and optional `LevelConfiguration`, `YINProfile`, `CPPSProfile`, `HNRConfiguration`, and
`SWIPEPrimeConfiguration`. At least one algorithm
is required. Input supports integer rates from 4,000 through 192,000 Hz, 1–32 channels,
Float32/Float64 and interleaved/planar storage. All enabled algorithms must declare the
same input rate/precision. Each kernel retains its own stricter numerical limits.

Select one stored channel with `PCMChannelSelection(channelIndex:)`, or explicitly
request `.arithmeticMean`. The mean scales each sample frame by its largest absolute
channel value, sums normalized channels with compensated Double arithmetic, divides by
channel count and restores scale before rounding once to the input precision. This
avoids overflow for finite extreme channels. The conversion rule is part of the profile.
CPPS performs its declared conditioning/resampling on the worker; Levels/YIN retain
source-rate input. No worker method is suitable for a capture callback.

Enable SWIPE-prime with `swipePrime:`. Its result and completion have separate
`.swipePrime` fields; it neither replaces nor gates YIN. Omitting it preserves the
prior serialized schedule and identity. Enabling it changes the composition identity
while retaining each baseline estimator's native profile, support and numeric results.
Its F0 exports use `.fundamentalFrequency` with the SWIPE-prime algorithm identifier;
signed strength remains in the typed result and generic confidence stays nil.

Prepare a zero-length `AnalysisScheduleOrigin.source` at the original acquisition
start, with a separate `continuityEpoch`. Native algorithms start at local sample zero;
scheduled timing maps their support back to original source positions. Finite mode
requires `expectedSampleCount`, including zero. Continuous mode can omit it, but rejects
whole-interval CPPS with `unsupportedLiveProfile`; it never substitutes preview silently.
One region is limited to 2^48 source samples, and whole-interval kernels have smaller
limits. `setOriginBeforeInput` can install a newly learned first timestamp before any
sample is consumed. Subsequent discontinuities require `reset` or a new instance.

`processInterleaved` borrows native scalar samples. `processPlanar` borrows one descriptor
per channel, with equal frame counts. Callers must serialize all operations. Validation
checks the entire chunk, including finite samples in unselected channels, before state
changes. Epoch, position, precision, layout and rate must match the prepared contract.
Callbacks are synchronous and nonescaping; retaining their owned scalar metadata is an
explicit consumer choice. Detailed borrowed curves/candidates remain in the kernel APIs.

Input passes through a fixed source tile, default 256 frames and configurable 1–4,096.
Dispatch order within a tile is Levels, YIN, then CPPS. Matching tile capacity and input
produce identical callback order, native numeric values and timing regardless of caller
partitioning. A different capacity can alter inter-algorithm delivery order and reported
batching/delivery delay. It does not select a different numerical recipe. Full input
validation costs O(chunk frames × channels); callers bound their own memory chunks.

## Support, delay and clocks

`profile.requirements()` reports support width, output interval, filter warm-up,
filter lookahead, centered-smoothing lookahead, placement, retained history, reset
semantics and continuous-input applicability. Levels/YIN and CPPS preview use local
left-aligned integer grids. Whole-interval CPPS uses its explicit interval-centered grid.
Weighted levels and optional YIN tracking retain causal history within a region.

`ScheduledFrame.timing.source` covers full dependency support, including filter or
tracker history and CPPS smoothing support. `frameCenterSecondsFromOrigin` separately
describes measurement placement; a dependency midpoint is not the cepstral display
center. `value` preserves native local coordinates and typed numerical availability.
Weighted-level scalar exports keep the native measurement window while their enclosing
`ScheduledMeasurementExport` retains full filter dependency timing and coverage.

Native `effectiveDelaySeconds` is preserved. CPPS reports delay relative to its own
frame center. `workerBatchingUpperBoundSeconds` reports the additional source tile bound
separately. Do not add declared smoothing/filter lookahead to an effective delay that
already includes it. Neither value measures OS scheduling, capture-to-display latency,
or UI refresh. Mask provenance carries its own decision delay, separately from DSP delay.

Optional source seconds, monotonic host nanoseconds and Unix wall-clock seconds are
projections from supplied anchors at nominal source rate. They are not repeated hardware
measurements or drift correction. Missing anchors remain absent. Integer source ranges
stay exact above 2^53; absolute floating-point seconds are approximate. Host projection
splits integer seconds from the remainder and checks UInt64 overflow. Physical clock and
latency evidence remains [#74](https://github.com/plx/hdxl-voice-processing/issues/74).

## Finish, reset and cancellation

`finish` dispatches the actual partial source tile, then each kernel's declared tail
once. It never pads missing PCM with silence. Finite input must reach its declared
count; a premature finish is recoverable by supplying the remaining input. Native
completion records preserve unavailable/partial context and aggregate diagnostics.
Repeated successful finish returns the cached completion without emitting again.

`reset` validates the new origin/configuration first, then discards every kernel's
overlap, filter, tracker, smoothing and aggregate state. It returns acquired source,
dispatched samples, pending acquired samples discarded, reason and optional known loss.
Pending acquired samples are distinct from missing acquisition; nil loss means unknown
or unreported. Finish first when the old region's labelled tail is wanted. Ordinary
streaming resets reuse prepared storage. A changed whole-interval size prepares new
whole-interval buffers at that explicit boundary. Restart after cancellation allocates
again on the control path. Rate/format/profile changes use a new prepared instance.

`cancel` is supported synchronously inside output. Core workers suppress subsequent
emissions and release native scratch after active borrows return. Other threads must
not mutate a worker concurrently. Reentrancy is rejected. A kernel failure marks that
worker failed; explicitly reset or create a new worker rather than retrying partial work.

## Masks and coverage

Prepare `PreparedAnalysisMask(timeline:scope:)` from #34's resolved `MaskTimeline`.
Prefix counts provide allocation-free O(log segment count) coverage queries. Their
storage is reported by `preparedCountBytes`; preparation allocates once per plan.
`PreparedMaskedAnalysisSchedule` consumes the existing selected or eligible regions,
finalizing and resetting the shared engine at each boundary. It never joins separate
regions. `skipMissingAcquisition` advances only declared absent PCM; input chunks that
span missing acquisition are rejected instead of interpreting zeros as recordings.

Frames and region completions retain mask identity, policy, source provenance, unique
source/eligible/selected/missing counts and independent evidence-tag counts. Overlapping
tags must not be summed. `MaskedScheduleCompletion` counts original timeline positions
once, not overlapping frame supports. It emits numerical aggregates per region rather
than silently combining unequal regions. Empty eligibility/selection has a typed
outcome. Missing or uncertain pitch does not change speech coverage. Unmasked input means
all acquired samples are selected, with no implied speech or phonation label.

An immutable finite mask plan can be replayed from a file, memory or simulated continuous
delivery. Global LTSF/intensity decisions need their completed/two-pass plan. There is no
implicit online detector or final provisional-label policy in this scheduler. A fully
unknown-duration live stream can use the unmasked engine and explicit gap resets.
`resetToStart()` replays the same plan with fresh continuity epochs and reused streaming
scratch; finalize first when the previous run's aggregate report is needed.

## Audio product adapters

`PreparedPCMTransferSchedule` drains `PCMTransfer` on its worker. `maximumEvents` bounds
each drain (1–4,096); transport configuration bounds each input chunk. Packed native
bytes are copied to reusable typed scratch using unaligned loads, with prepared planar
descriptors. Channel identifiers stay attached to frame output. The first block's host
anchor, or supplied origin when absent, anchors each region. Later block timestamps do
not silently recalibrate it. A gap finalizes old acquired input, emits the transport's
loss record and resets analysis before the next valid block. Terminal gaps remain
observable without a subsequent block. Cancelling the worker does not close the producer;
the host still owns shutdown and capture quiescence.

`PreparedAudioFileSchedule` uses AVAudioFile with an explicit Float32/Float64 processing
format and layout. Rate/channel count must match the profile. Output carries on-disk
ASBD, decoded format, file length, URL, decoder identifier and OS version. Codec decoding
is distinct from numerical conditioning. A prepared PCM buffer is reused; opaque system
codec allocations are outside the core scratch guarantee. The OS 27 EOF contract is
respected by requesting only remaining declared frames. A new instance handles each
file/seek, preserving original file sample positions. Supplied missing-acquisition mask
intervals are skipped by seeking, without decoding placeholder PCM.
Callers assign distinct source epochs to independent recordings. Replays can retain a
recording's original source identity while starting a fresh analysis continuity epoch.

`AudioFileAnalysisBatch.run` creates an independent worker per input and synchronously
emits frames, region aggregates and each input's result. Control is sampled before
preparation and between bounded reads. `cancelInput` permits later inputs to run;
`cancelBatch` marks remaining inputs cancelled without opening them. Preparation and
processing failures are recorded per input. The batch retains no frame history.

The core consumer example demonstrates selected-region scheduling without importing
AVFAudio. Policy attention is recorded in [#123](https://github.com/plx/hdxl-voice-processing/issues/123).
The [host benchmark guide](../Tools/Scheduling/README.md) defines the light/full matrix,
independent output checks, prepared-scratch evidence and throughput denominators.
