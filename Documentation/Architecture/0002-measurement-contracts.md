# ADR 0002: Measurement, profile, timing, and processor contracts

Status: accepted for foundation issue #15, 2026-11-04. These are shared contracts;
they do not assert that any acoustic algorithm has been implemented or validated.

## Identity and interpretation

`MeasurementDescriptor` pairs a named quantity with a permitted `MeasurementUnit`
and a versioned algorithm identifier. CPP and CPPS are separate quantities. YIN and
SWIPE-prime can estimate the same fundamental-frequency quantity but have different
algorithm identities. Autocorrelation and cross-correlation HNR likewise require
different algorithm identities. Profile versioning is independent of package SemVer.

The unit enum distinguishes dB ratios, digital full-scale dB, and calibrated SPL;
fraction and percent are distinct units. There is no implicit percent conversion or
unit-erasing convenience numeric property on a result. Select a descriptor/profile
with the intended unit and explicitly compute the corresponding value. Calibration
identity/settings must accompany any future SPL algorithm. An SPL descriptor alone
is not evidence of physical calibration. Algorithms validate physically meaningful
ranges in addition to the shared finite-number checks.

`MeasurementOutcome.available` contains a finite `ScalarEstimate` and optional
algorithm-defined confidence in [0, 1]. Warnings retain inspectable estimates with
clipping, low confidence, partial coverage, or exploratory applicability visible.
`unavailable` has a reason and no number. Valid zero is an explicit available
estimate; silence, insufficient support, failure, and inapplicability never become
zero, NaN, or infinity. A non-value reason may be:

| Reason | Meaning |
| --- | --- |
| insufficientData | Too little support, including warmup or an incomplete final window |
| silence | The profile's signal/energy criterion is not met |
| clipping | The profile declines estimation because input clipped |
| unsupportedRange | Input or requested search range is outside this algorithm's support |
| inapplicableTask | The selected speech task violates this measurement's assumptions |
| lowConfidence | An estimate exists internally but fails the profile's publication threshold |
| invalidInput | Malformed PCM, nonfinite samples, or an inconsistent format |
| discontinuity | Required support crosses a gap, reset, or route/profile boundary |
| analysisFailure | The algorithm cannot produce a finite supported estimate |
| cancelled | The caller stopped analysis before the result was available |

No confidence score denotes probability of health, physical effort, attractiveness,
or usefulness to a particular person. Later algorithm issues define thresholds,
applicability, and warning-versus-unavailability policy with evidence.

## Profiles and persistence

`AnalysisProfile` stores format/layout/encoding, channel selection, analysis rate,
arithmetic precision, frame/hop lengths, versioned window convention, preprocessing,
algorithm settings, and final-window policy. `PCMFormat` describes normalized Float32
or Float64 input; analysis precision is a separate choice. Channel selection is an
explicit zero-based index or arithmetic mean. Source sample frames, interleaved
scalar elements, and analysis frames are distinct counts.

Common validation rejects invalid sizes/rates, nonexistent channels, integer sizing
overflow, nonfinite numeric settings, and malformed identifiers. Typed settings
(`integer`, `real`, `boolean`, `text`) allow algorithms to define their own parameters
without placing the full future suite in one configuration enum. This validation is
**structural**, not a guarantee that a named algorithm accepts the configuration.
Each executable algorithm factory must reject unknown/missing keys and unsupported
combinations, and materialize every default before computing identity. For example,
CPP/CPPS settings must specify frequency/search bounds, interpolation, regression,
smoothing windows/order, eligibility selection, averaging domain, and log floors.
Reference-specific coefficients and resampling conventions belong in preprocessing.
The contract fixture contains representative settings, not a published CPPS profile.

`canonicalJSON()` version 1 uses compact UTF-8 `JSONEncoder` output, sorted object
keys, unescaped slashes, finite numbers, normalized negative zero, and NFC-normalized
text settings. Canonically equivalent Swift strings have the same identity. It is a pinned
encoding convention, not RFC 8785. A SHA-256 over every byte forms `ProfileIdentity`,
together with the human-readable identifier/version. Compute it during setup and
reuse it for scalar results. Dictionary insertion order does not affect identity;
changing any profile dimension does. Golden bytes and an independently computed
Python SHA-256 detect toolchain encoding drift. A future drift requires an explicit
schema/canonicalization migration, not silent regeneration of golden fixtures.

Profiles and results have `schemaVersion = 1`. All contract structs and tagged
settings/outcomes reject unknown fields, enum cases, missing required fields, and
unsupported schema versions. This fail-closed policy avoids discarding future
configuration and accidentally reusing a hash/calibration with changed semantics.
Optional absent metadata stays absent; decoding uses the same validators as normal
construction. A later importer can implement an explicit migration before decoding.
An identity is provenance, not an authenticity signature: session import must look
up the full profile, recompute its hash, and match its descriptor before reuse (#58).

## Source time, coverage, and boundaries

`StreamEpoch` combines a stream UUID with a checked UInt64 sequence. `SourceInterval`
is a half-open `[startSample, endSample)` range of source sample frames, with Int64
positions and a source rate. Counts remain integer until duration conversion, so
short intervals at very large positions retain their duration. Floating absolute
display times are approximate; integer sample positions are authoritative.

`AnalysisTiming` carries that source support, included count, optional source-clock
anchor at its first sample, optional monotonic host nanoseconds at that sample,
optional completion host nanoseconds, and effective algorithmic delay in seconds.
Hosts convert raw clock ticks to nanoseconds explicitly. Source-clock and host-clock
values are not interchangeable. The display anchor is the center of source support;
completion time and effective delay do not move it. Measured-window length includes
excluded samples. Included/excluded duration and coverage are derived without
stitching exclusions. Empty support has zero coverage and cannot carry an available
numeric result. An aggregate result must count unique source support, not count
overlapping analysis frames as extra audio.

`SourceDiscontinuity` identifies old/new epochs, reason, and a known missing source
interval when available. Unknown loss is nil rather than invented zero duration.
For reset, drop, pause, route change, or profile change, advance the same stream's
epoch exactly once; a new source gets a new UUID and sequence zero. Sample position
restarts at zero in the new epoch, with a fresh source/host anchor when available.
Consumers preserve the boundary even when the lost duration cannot be calculated.

## Mutable processor ownership and lifecycle

`PCMProcessor` is a synchronous single-owner worker protocol, deliberately without
a Sendable requirement. No implementation or audio capture loop is supplied by this
foundation. Implementers must satisfy these rules, tested with real processors in
the dependent framing/scheduling/lifecycle issues:

1. Setup validates the executable profile and intermediate policy, caches identity,
   allocates scratch/transform plans, and begins a supplied epoch. Do not do setup
   or DSP work inside the capture callback.
2. `process` borrows an interleaved buffer for the duration of the call only. Its
   scalar type/length/rate/epoch must agree with the profile and source interval.
   Check multiplication overflow and all metadata before reading samples. Reject
   nonfinite samples as invalid input. Calls must be contiguous within an epoch;
   a gap must trigger an explicit boundary/reset, never concatenation.
3. A single actor or serial worker owns mutable state. Calls are neither concurrent
   nor reentrant, including from `emit`. The emitter is synchronous and nonescaping.
   It may hand owned immutable results to a bounded queue, but must not create a
   new unbounded task or unbounded AsyncStream buffer for every result. Overflow
   policy and dropped-result counters belong to #54. A subscriber dropping results
   does not itself break PCM source continuity.
4. `reset` validates the previous epoch, discards partial windows and all filter,
   pulse, smoothing, and resampling state, and
   warms up again in the new epoch. Route changes also require validating the new
   format through reconfiguration; stale old-epoch buffers must be rejected.
   The owning scheduler forwards the boundary event to consumers; `reset` itself
   does not emit a numeric result.
5. `reconfigure` validates and allocates first. On failure the old profile, epoch,
   and state are intact. On success use the next epoch and discard old state. The
   scheduler publishes the profile-change boundary and invalidates incompatible
   personal calibration.
6. `finalize` flushes complete supported windows once, then either discards the final
   partial window or emits `insufficientData` over its actual support according to
   the profile. It never pads invented samples or bridges gaps. Repeated finalization
   emits nothing. Processing after finalization requires reset/reconfiguration.
7. `cancel` immediately discards pending work and releases scratch, is idempotent,
   and emits nothing. Synchronous processing checks cancellation between bounded
   units of work through the owning scheduler. Resuming requires setup/reset;
   no borrowed pointer survives cancellation or any call.

Runtime delivery, scratch allocation, and cancellation latency are measured once
their implementations and benchmark harness exist; these contracts make no zero-
allocation claim. There are no unchecked Sendable conformances in this foundation.

## Intermediate lifetime and budget

The default result has no intermediate arrays. `IntermediateOutputPolicy` opts in
to a maximum count of Double scalars **across all arrays in one result**, with byte
multiplication checked for overflow. Producers check the budget before materializing
data. Result construction also rejects excess retention. Each nonempty snapshot owns
immutable values, versioned stage identity, source support, and explicit axis units,
origin, and spacing. It shares the result's epoch and retains no borrowed scratch.
Array copy-on-write preserves snapshots when the producer changes its original array.

This bounds retained numeric payload per result, not allocator overhead or session
history. Queues, history, and matrix products need separate budgets (#41/#54/#67).
Decoding an external file is not a bounded streaming parser: importers must limit
input bytes before Codable allocation (#58). Never enable history merely to obtain
a scalar. Stage transforms or profile changes require new stage/profile identities.

Sources: [Swift concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/),
[Praat CPPS settings](https://praat.org/manual/PowerCepstrogram__Get_CPPS___.html).
