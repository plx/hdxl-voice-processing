# A10 SWIPE-prime evidence

The discrete mathematical contract and numerical budgets were committed before
the independent oracle and native estimator. This is the bounded first/prime
harmonic variant, named `hdxl-swipe-prime-centered-2008`; it does not claim parity
with every historical SWIPE implementation. The original equations are implemented
in repository-owned Python and Swift, without importing third-party SWIPE code.
See the [reference contract](../../Tools/SWIPE/README.md) and
[native guide](../SWIPEPrime.md).

## Independent numerical and streaming evidence

The catalog contains 74 cases, 374 SWIPE-prime frames (300 complete, 74 partial),
1,982 YIN frames, and 300 pairs aligned by actual support midpoint. Its 146
artifacts include exact inputs, both profiles, source identities, spectral and
candidate stages, kernel probes, and full applicability/error denominators.
Three speech cases use the existing governed PVQD excerpts and retain their
attribution. Synthetic Float32 inputs are rounded before storage as Float64 WAV.

The development native report compares 374 direct and 748 streamed frames,
1,655,517 magnitude cells, 645,585 loudness cells, 317,853 kernel cells, and 347,268
strength cells. Every candidate, selection, shape, status, and timing contract
is checked; numerical quantities retain the precommitted budgets.

Maximum fractions of those budgets at the native integration checkpoint:

| Quantity | Maximum budget fraction |
| --- | ---: |
| Magnitude | 4.968073658720947e-6 |
| Loudness | 0.8013150437664207 |
| Kernel | 0 |
| Strength | 0.011483601707152532 |
| F0 | 1.5577938938804436e-6 |

A fraction at most 1 passes. The audit rejects 42 deliberately corrupted receipts.
Native report SHA-256:
`1f03ddcdb85c5f35cf203a1f0bbbf415c6a2632c85a47795f79eba185ce38130`.
Catalog manifest SHA-256:
`8a6f33d2ca3cadcf1cd92922333710bd1e13adbad9d16b4db7752546e680b0f0`.
Independent oracle implementation SHA-256:
`d2580869d3c37c3c6bb0ec960ed7cbad0764c30004d8b4af907da987f7086d71`.

## Applicability and comparison denominators

The following original catalog cases retain each estimator's own support and
coverage. Every listed case also has one unavailable partial tail. The voiced
fractions below exclude that tail; e.g. 3/3 complete frames is 3/4 including the
tail. A numeric uncertain estimate is available without being voiced. Gross
error is more than 20% relative frequency error, counted over available estimates
with known synthetic truth. Undefined truth is not a zero-error result.

| Case | SWIPE voiced/full | YIN voiced/full | Support-matched pairs | SWIPE gross/known available | YIN gross/known available |
| --- | ---: | ---: | ---: | ---: | ---: |
| tone-123.45 | 3/3 | 24/24 | 3 | 0/3 | 0/24 |
| sawtooth | 3/3 | 24/24 | 3 | 0/3 | 0/24 |
| missing-fundamental | 3/3 | 24/24 | 3 | 0/3 | 0/24 |
| dominant-second | 3/3 | 24/24 | 3 | 3/3 | 24/24 |
| dominant-fifth | 3/3 | 24/24 | 3 | 3/3 | 24/24 |
| inharmonic | 3/3 | 0/24 | 3 | undefined | undefined |
| breathy | 3/3 | 0/24 | 3 | 0/3 | 12/24 |
| snr-0 | 3/3 | 0/24 | 3 | 0/3 | 16/24 |
| noise | 0/3 | 0/24 | 3 | undefined | undefined |
| chirp | 30/30 | 51/51 | 30 | 0/30 | 0/51 |
| octave-jump | 30/30 | 49/51 | 30 | 0/4 | 0/47 |
| speech-bl01-vowel-a | 6/6 | 20/20 | 6 | undefined | undefined |
| speech-bl02-consonant-rich | 0/6 | 0/20 | 6 | undefined | undefined |
| speech-bl03-all-voiced | 0/6 | 0/20 | 6 | undefined | undefined |

Frame indices are never treated as corresponding times. Full SWIPE-prime frames
match the nearest unused full YIN midpoint within half YIN's actual hop, with
earlier ties. The reports retain exact supports, midpoint offsets, overlap,
each estimator's support/2 delay, and unmatched rows. The different complete
frame and known-truth denominators above remain visible; an interval spanning a
pitch jump has no single synthetic truth. All three corpus slices have unknown
F0 ground truth, so their agreement/coverage does not establish accuracy. The
all-voiced source label is not used as an inferred pitch annotation.

Both estimators make gross errors on the dominant-second and dominant-fifth
fixtures. Their octave-error counts are 3/3 and 24/24 for dominant-second; neither
labels the dominant-fifth error as an octave error. SWIPE-prime retains voiced
outputs on the inharmonic case without inventing a target frequency. These are
characterizations, not universal rankings or evidence that strength is a
probability.

The independent oracle missed the original 10-cent pure-tone goal before Swift
implementation. The retained 228-frame investigation reached 34.49359025084032
cents and 138 goal misses. The explicit pre-native regression amendment is 50
cents for tones; the harmonic-complex ceiling remains 20 cents and native parity
budgets are unchanged. The original goal and further profile investigation remain
in [#162](https://github.com/plx/hdxl-voice-processing/issues/162). Human labels
remain in [#102](https://github.com/plx/hdxl-voice-processing/issues/102).

## Maximum support and workload preflight

The frozen 192 kHz / 20 Hz maximum requires 131,072 observed samples. The direct worker
already supported it; streaming exposed the old 65,536-sample shared-framer bound.
The separately reviewed foundation extension [#165/#166](https://github.com/plx/hdxl-voice-processing/pull/166)
resolved that boundary. Maximum Float and Double streaming tests now match direct
results under whole and irregular chunks, including partial tails and stable
storage/cancellation. Prepared payloads at the maximum are 24,713,192 bytes for
Float and 26,286,056 bytes for Double, below 64 MiB. Object bookkeeping and opaque
FFT setup tables are excluded; input bytes are separate.

The full 44-input / 88-row paired workload preflight passes. Its independent audit
checks every PCM hash, recipe/profile, identity, support/delay, buffer payload,
coverage count and owned export size. All 264 first/middle/last scalar probes pass
the existing SWIPE-prime and scalar YIN oracles. Maximum absolute errors are
9.099821340896597e-9 Hz / 1.9902599568411006e-9 strength for SWIPE-prime and
3.836930773104541e-13 Hz / 4.440892098500626e-16 periodicity for YIN. No numerical
budget was enlarged. These probes occur outside measured intervals and supplement
the complete staged fixture suite.

## Supplemental host measurements

The measurements below were collected on 2026-11-10 UTC from clean commit
`25d3b9d4f6238ad1b6287b38ebd92d2112000aae`: Mac13,1 arm64, macOS 27.0.1,
Xcode 27.2 (27B52), Swift 6.4.2, SDK 27.2, and Python 3.14.8. A retained local
wrapper explicitly recorded the toolchain difference and `exactHostedPinGate:
false`. The tracked runner continues to require Xcode 27.0 / Swift 6.4.0 / SDK
27.0. These are supplemental observations, not the pinned hosted gate;
[#163](https://github.com/plx/hdxl-voice-processing/issues/163) records the mismatch.

The timing shard uses identical two-second 48 kHz Double PCM with 125/250/375 Hz
harmonics (amplitudes 0.4/0.1/0.04; second-harmonic phase 0.13), 96 candidates per
octave, and the specified hop. Construction excludes input generation and
destruction. Run includes reset, 256-sample chunks, scalar consumption and
finalization. Timing uses an optimized binary without allocator interposition.

Every Run has one warmup and ten measured samples; construction has three warmups
and thirty measured samples here. All values below are p99 milliseconds of a
complete operation. With ten observations, p99 is effectively the observed
maximum, not a stable population tail. Whole-batch throughput does not establish
worst-frame, microphone, thermal, energy, or capture-deadline performance.

| Range (Hz) | Hop (ms) | Estimator | Full frames | Prepare wall / CPU (ms) | Run wall / CPU (ms) |
| --- | ---: | --- | ---: | ---: | ---: |
| 80–400 | 5 | SWIPEPrime | 366 | 4.150 / 4.152 | 288.895 / 288.702 |
| 80–400 | 5 | YINFFT | 395 | 0.692 / 0.693 | 41.943 / 41.809 |
| 80–400 | 10 | SWIPEPrime | 183 | 4.050 / 4.036 | 146.500 / 146.414 |
| 80–400 | 10 | YINFFT | 198 | 0.652 / 0.653 | 22.247 / 22.102 |
| 80–400 | 20 | SWIPEPrime | 92 | 3.995 / 3.975 | 74.731 / 74.666 |
| 80–400 | 20 | YINFFT | 99 | 0.663 / 0.664 | 12.477 / 12.370 |
| 25–2000 | 5 | SWIPEPrime | 332 | 8.761 / 8.716 | 587.063 / 584.783 |
| 25–2000 | 5 | YINFFT | 384 | 1.537 / 1.539 | 1973.589 / 1948.620 |
| 25–2000 | 10 | SWIPEPrime | 166 | 8.592 / 8.571 | 296.373 / 295.825 |
| 25–2000 | 10 | YINFFT | 192 | 1.818 / 1.819 | 985.793 / 978.607 |
| 25–2000 | 20 | SWIPEPrime | 83 | 9.283 / 8.367 | 149.673 / 149.267 |
| 25–2000 | 20 | YINFFT | 96 | 1.453 / 1.454 | 503.379 / 491.394 |

Every row also emits one unavailable partial tail. Support and owned buffer
payload differ even though PCM and requested range/hop agree:

| Range (Hz) | Estimator | Support (samples) | Minimum delay (ms) | Owned payload (bytes) |
| --- | --- | ---: | ---: | ---: |
| 80–400 | SWIPEPrime | 8192 | 85.333333 | 1,847,552 |
| 80–400 | YINFFT | 1201 | 12.510417 | 171,368 |
| 25–2000 | SWIPEPrime | 16384 | 170.666667 | 4,313,360 |
| 25–2000 | YINFFT | 3841 | 40.010417 | 633,704 |

YIN is the FFT backend with tracking disabled and its existing conservative
scalar recomputation/fallback behavior. These timings include that behavior;
this receipt does not isolate its cost. The earlier YIN investigation and
optimization follow-up remain in
[#119](https://github.com/plx/hdxl-voice-processing/issues/119). Relative cost
changes with range and input; this table does not establish an estimator ranking.

The separate maximum-geometry allocation shard covers both algorithms and both
source precisions, including SWIPE-prime's 131,072-sample support. All four
prepared Run operations have zero observed maximum malloc count, malloc bytes,
and object allocations. Each has ten measured samples. The positive control
records two mallocs, 4,120 bytes, one object, two frees, two retains and three
releases. ARC traffic is retained separately; it is not claimed to be zero.
Allocator linkage and the unchanged source/dependency hashes are verified.

Explicit diagnostic export is a separate allocating operation. On the same
9,633-sample 48 kHz narrow-range input, SWIPE-prime emits four complete frames
and YIN emits eighteen, plus one unavailable tail each. SWIPE-prime copies its
intermediates and encodes them as JSON; YIN copies all of its intermediate stages
and encodes its scalar measurement results. These are different export payloads,
not equivalent serialization tasks. The table reports per-batch observed maxima
with allocation instrumentation enabled; its wall time is not the timing lane.
JSON bytes are from the preflight epoch and can change as epoch digits grow.

| Estimator | Input | Exported scalar slots | Preflight JSON bytes | Malloc count | Malloc bytes | Object allocations | Instrumented wall (ms) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| SWIPEPrime | Float | 55,452 | 1,078,084 | 55,435 | 10,947,228 | 55,431 | 18.539 |
| YINFFT | Float | 21,672 | 12,595 | 1,512 | 647,401 | 1,494 | 2.784 |
| SWIPEPrime | Double | 55,452 | 1,078,365 | 55,447 | 10,948,277 | 55,443 | 21.994 |
| YINFFT | Double | 21,672 | 12,594 | 1,512 | 647,400 | 1,494 | 2.758 |

Each export Run has ten measured samples; the same positive allocation/ARC
control passes. Source and dependency hashes remain unchanged in all three
captures. Retained raw-distribution SHA-256 values:

- 48 kHz Double timing: `1e23780f48036ec55bf8f6fe359e442d5ddef7829cb2733ecfd945abbea0ce3f`.
- Maximum allocation: `c5e3e1de880deeccc70230f445ce203506a966910e81188143d22e38309c6b44`.
- Owned export allocation: `ede11260a1b5ff43a0476b2bd5b4b45a0ee195c48b42ec4e9b301c29a7a10c24`.

## Reproducible gates and deferred evidence

`swipe-references.yml` regenerates the independent catalog and audits complete
native stage/streaming parity and corruption controls. `swipe-benchmarks.yml`
runs ten shards in timing and allocation modes: 44 paired inputs, 88 workload
rows, 176 Prepare/Run operations per mode, and ten allocation controls. The
matrix includes 16/44.1/48 kHz, Float/Double, narrow/wide grids, 5/10/20 ms hops,
maximum geometry, ten-second silence/noise, and explicit owned exports.

Each receipt retains actual profiles, exact PCM hashes, independent oracle
probes, supports/delays, payload sizes, sample distributions, controls, toolchain,
source/dependency hashes, and command outcomes. Non-export prepared Run heap
maxima must be zero. The implementing PR retains the complete final-head hosted
results and review record; the local subset above does not replace that gate.
See the [collection commands](../../Tools/SWIPE/README.md#timing-and-allocation-collection).

Physical-device, microphone, thermal and energy measurements remain deferred to
[#74](https://github.com/plx/hdxl-voice-processing/issues/74). Human pitch labels
remain in #102, the profile accuracy decision in #162, and the existing YIN
half-nanosecond clock-boundary follow-up in #164. None is presented as completed
physical evidence or calibrated clinical accuracy.
