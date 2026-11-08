# Acoustic pulse tracking

`PreparedPulseTracker<Float>` and `PreparedPulseTracker<Double>` locate acoustic
waveform landmarks using an explicit F0 contour. They return raw points, every
attempted tracking step, individual periods, adjacent-period pairs, and cycle
amplitudes. These are inferred acoustic landmarks, not measurements of glottal
closure or vocal-fold health.

The tracker accepts finite mono PCM in `[-1, 1]` and a declared sample rate. It
requires no audio engine, microphone, UI, or network. Float32 input is converted
exactly to Float64 for analysis. Configuration identity includes input precision,
arithmetic, support definition, period limits, and numerical conventions.

## Preparing an interval

Create a `PulseConfiguration` with the input sample rate and precision. Supply a
`PulseF0Contour` with the same sample count and rate, its first frame center,
uniform step, frequency ceiling, and selected frequencies. Zero means unvoiced;
positive values must fit the configured frequency range. Unsupported contour
edges remain unsupported; interpolation never crosses an unvoiced nearest frame.
The contour owns its frequencies and computes their content identity during
preparation. A result carries that identity and the optional supplying estimator's
profile. An unidentified supplied contour does not become an oracle by default.

Prepare the worker with explicit maximum PCM, F0-frame, and tracking-attempt
capacities. Attempt capacity includes failed matches. Exhausting it throws without
publishing an incomplete result. Workers own reusable buffers and are single-owner
objects; prepare and invoke them on an analysis worker, outside the audio capture
callback. Output arrays are borrowed only for the synchronous callback. An owned
`snapshot(maximumRecordCount:)` is an explicit allocating operation that budgets
all five retained arrays together.

`AnalysisTiming.source` identifies the complete acquired interval. Pulse times
are seconds relative to its integer `startSample`. Compute periods in that relative
coordinate system, before adding a large absolute clock offset. Source time,
epoch, input precision, F0 identity, and configuration identity stay separate.

## Complete support and chunked delivery

Each maximal voiced F0 interval starts from an absolute waveform extremum near
its midpoint. Matching follows approximately one period in both directions. The
seed and global amplitude reference depend on the complete PCM input. This
definition is not causal or prefix-stable.

`completeInterval` describes an offline interval. `independentlyAnchoredBlock`
describes a finite live block with a distinct profile identity. Both wait for all
declared input. Result support is the complete block; its center-based effective
delay is at least half the block duration. Individual early landmarks may wait
almost the full duration. No period continuity is claimed between independently
anchored blocks.

`PreparedPulseStream` accepts arbitrary delivery chunks for one declared block.
Each chunk must have the exact next integer source position, epoch, and sample
rate. Gaps, overlaps, wrong contexts, and invalid PCM are rejected before any
samples are consumed. No partial sequence is emitted. An incomplete `finish`
remains resumable; a successful finish emits once and is idempotent. Cancellation
emits nothing. Analysis or callback failure requires reset. Reset validates the
new complete context before changing state and fits the original capacities;
no pulse, attempt history, or run ID carries into the next interval. Reentrant
operations fail while a callback holds borrowed output.

For a real acquisition gap, finish or cancel the preceding block and reset to a
new source interval. Never concatenate the available sides and claim continuous
sample positions. Exclusions are sorted, nonoverlapping, nonempty sample ranges
relative to the source start, with matching `includedSampleCount`. Raw matching
still uses the complete waveform and its global peak; exclusions invalidate
intersecting support and periods. They are not a mechanism for erasing excluded
audio's influence from raw diagnostics.

## Raw points and eligible measurements

The pinned reference may return an extra point outside the acquisition. Raw
diagnostics preserve it. Native eligibility additionally requires half-open
acquisition and voiced-interval membership, complete seed/matching support,
at least three observed samples, varying waveform support, a resolved quadratic
peak, and no intersecting exclusion. A range-fallback match is not usable timing.
An interpolated correlation may exceed one; it is not a confidence probability.

Every proposed match is retained, even if it fails acceptance. Contiguous run
IDs require adjacent successful tracking steps in the same voiced interval and
valid period bounds. A missed step, excluded region, unsupported point, or invalid
period breaks the run. The output retains all adjacent raw intervals rather than
filtering points and joining the survivors.

Individual periods use the configured minimum and maximum duration. Adjacent
period pairs independently use the maximum ratio. Rejecting one ratio does not
erase both periods from other statistics. Downstream jitter and shimmer must use
the relevant eligibility records, not the flat list of timestamps. Boundary
fragments and failed matches remain visible in their denominators' audit trail.

An amplitude needs two eligible neighboring periods and an eligible pair. It is
Hann-weighted RMS over 0.2 times the preceding/following period on each side of the
landmark, with at least three observed samples and positive energy. Silent,
unsupported, or rejected amplitudes remain unavailable, never numeric zero.
Exactly constant PCM can produce reference raw points but has no usable cycle
timing; all such periods and amplitudes are rejected.

Two eligible landmarks are necessary for one period; three are necessary for
one adjacent pair or cycle amplitude. They are not sufficient: support and quality
gates still apply. There is no F0-independent minimum duration that guarantees
usable cycles. Short fragments and unvoiced blocks are valid unavailable results.

## Numerical and reference scope

The [search equations](../Tools/Pulses/SEARCH.md) specify coordinate rounding,
seed selection, candidate bounds, finite-table peak selection, and interpolation.
Native dot products use explicit fused multiply-add accumulation. If the product
of raw energies is subnormal, the two observed vectors are separately scaled by
their peaks before evaluating the same normalized dot product. This preserves
representable quiet waveforms; it does not invent information lost when input
precision rounded samples to zero. Cycle RMS independently scales its energy sum.

The pinned development route is Praat 7.0.02 on the locked ARM64 host, with the
same supplied F0 and actual PCM precision. The [comparison policy](../Tools/Pulses/COMPARISON.md)
separates raw reference agreement, isolated stage equations, and known-source
timing. The 110-case reference catalog includes licensed speech, noise, missing
cycles, polarity, modulation, varying F0, and short/degenerate inputs. All 255 F0
boundary queries and 96 complete matching-stage tables are independently retained.
Reference raw agreement does not by itself validate native run qualification,
an upstream pitch estimator, or physiological accuracy.

A separate 50-case history catalog checks both direct and irregularly chunked
processing against original high-precision matching equations and a graph of
successful tracking steps. It covers failed matches, exclusions, unvoiced gaps,
short fragments, period limits, adjacent-period ratios, and every rejection
reason. Exact binary templates provide closed-form timing anchors at
80/150/300/600 Hz. Their seed convention matters: an extremum at the edge of the
seed-search window is not fractionally refined, and its phase bias can persist
through a periodic track. A seed in a silent gap can also reacquire a different
waveform phase; usable timing does not guarantee a usable cycle amplitude.
These observations do not establish arbitrary-waveform timing accuracy.

The separate YIN integration recipe uses complete raw YIN frames, places their
frequencies at the midpoint of their observed support, and retains the original
uniform hop. Only `.voiced` frames supply a positive frequency; uncertain,
unvoiced, and unavailable frames supply explicit unvoiced entries. Partial tails
are omitted and unsupported edges are preserved. If no complete frame exists,
report insufficient upstream support rather than inventing an F0 contour. This
is a documented caller choice, not an automatic gate inside the pulse tracker.
The contour records the supplying YIN profile, while its own identity binds the
actual selected frequencies and grid. Persist the recipe choice as part of a
combined pipeline configuration.

Sixteen integration cases compare native scalar and FFT YIN plus pulses with
independent YIN equations plus the pinned external pulse route. Both whole-input
and irregular YIN chunk delivery produce identical pulse snapshots. Upstream
frequency error and downstream pulse error are reported separately. Licensed
speech and noisy cases retain unavailable results; this catalog is not a claim
of complete voicing coverage or human-labeled pitch accuracy.

Worker diagnostics expose bounded `PulseMatching`, `PulseInterpolation`, and
`PulseSequences` spans inside `Pulses`. Consumer callbacks run outside `Pulses`.
The shared record budget and every-sixteenth-frame sampling policy still apply;
long blocks can suppress later stage records. These sampled spans are not an
unbiased per-cycle performance distribution. Dedicated workloads must measure
accepted/rejected cycle costs and complete throughput separately, with setup and
snapshot allocation outside steady-state measurement.
