# Workload and measurement contract v1

A performance comparison needs the same inputs, work, and measurement boundary on both sides.
Use the public operation name as the stable identifier and retain the manifest **and the files
it references**. A change to input generation, profile, operation scope, validity policy or
batch size starts a new comparison series. A changed commit alone does not identify a workload.

## Inputs and expected work

The [portable manifest](../Configuration/portable-workloads-v1.json) can be consumed on macOS
and iOS. Each entry names its governed fixture, encoded source hash, transformed PCM hash,
channel layout, scalar encoding, sample rate, slice, duration, observed regions, estimator
configuration and hash, window, hop and FFT applicability. Scalar YIN uses no FFT. The clipped
case applies gain eight and clamps to ±1 before encoding. The gap case omits one hop from the
middle of the file and finishes each observed region independently. Its utterance duration
includes the omitted span. Each case carries counts of processed, available and unavailable
frames plus all four voicing states. An uncertain candidate has a frequency estimate. Keep
its count visible when reporting coverage.

Each case also publishes an ordered frame digest from the scalar reference. Each UTF-8
line contains the absolute start sample, observed sample count, status and eligibility
(0 or 1), separated by commas and terminated by LF. This catches a repeated or skipped
window even when the aggregate voicing counts match. Epoch UUIDs are local to a replay.

Prepare the bounded bundle once, outside measurement. Ten source fixtures cover low, middle
and high F0, a pitch transition, a sustained vowel, connected speech, noise, silence, both
PCM precisions, and 16/44.1/48 kHz. Two derived cases exercise clipping and a discontinuity.
The fixture hashes bind the descriptor to the actual PCM. The Python checker derives the
transformed counts with the independent scalar oracle.

```sh
python3 Tools/Performance/prepare.py .build/portable-inputs
swift run --package-path Tools/Performance/Portable -c release ReplayWorkloads .build/portable-inputs 17
python3 Tools/Performance/verify_portable.py --output .build/portable-parity.json
```

Preparation requires a fresh destination. On an iOS host, import the development package
`WorkloadReplay`, copy the prepared bundle to a readable directory, and call
`replayWorkloads(at:maximumChunkSamples:)`. The verification command runs whole-buffer input
on macOS and 17-sample blocks on a disposable iOS 27.0 Simulator. Both executions check every
PCM and profile identity and count against the same manifest. Machine setup, file reads,
hashing and report encoding occur during verification. The corpus license and attribution
apply when redistributing a bundle. See [VoiceCorpus](VoiceCorpus.md).

Each production algorithm benchmark continues to use its validated family matrix. The runner
writes `workload-manifest.json` next to `workloads.json`, `environment.json` and
`distributions.json`. Look up the complete operation name, then resolve its zero-based
`caseIndex` against the digest-identified case file. That row carries its native geometry,
input recipe or hash, profile, expected work and applicability. The environment describes the
generator, preparation and observation boundaries. Two algorithms operating on the same
SWIPE-prime comparison input resolve to distinct case rows. Allocation controls have their
own role and no voice frame count. The smoke harness has a single `workload.json` and stores
the batch size directly in the operation record. The manifest binds the validated percentile
export, workload and environment by SHA-256. The final run result includes the digest of
that manifest. The denominator audit verifies the result, timing mode and referenced files
before computing rates. Reports from before the contract are marked `legacy-unbound`.

| Workload family | Case metadata and interpretation |
| --- | --- |
| Gain/energy and allocation controls | [Bootstrap](../Benchmarks/README.md) |
| Isolated DSP kernels, buffer reuse and calibrated loop controls | [Kernel workload and reporting guide](../Tools/Kernels/README.md) |
| Windowing, ordinary and whole-interval Fourier, conditioning, levels | [Framing](../Tools/Framing/README.md), [Fourier](../Tools/Fourier/README.md), [conditioning](../Tools/Conditioning/README.md), [levels](../Tools/Levels/README.md) |
| Bounded spectrograms, canonical cepstrograms, and LTAS | [Spectral product workloads and export costs](../Tools/SpectralProducts/README.md) |
| Spectral shape on frames and sliding LTAS windows | [Descriptor workloads and incremental FFT cost](../Tools/SpectralShape/README.md) |
| Cepstrum, CPP and CPPS | [Cepstrum](../Tools/Cepstrum/README.md), [CPP](../Tools/CPP/README.md), [CPPS](../Tools/CPPS/README.md) |
| Selection, F0 and harmonicity | [Masks](../Tools/Masks/README.md), [YIN](../Tools/YIN/README.md), [SWIPE-prime](../Tools/SWIPE/README.md), [HNR](../Tools/HNR/README.md) |
| Pulses and perturbation statistics | [Pulses](../Tools/Pulses/README.md), [jitter](../Tools/Jitter/README.md), [shimmer](../Tools/Shimmer/README.md) |
| PCM transfer, capture and composed processing | [Transport](../Tools/Transport/README.md), [capture](MacOSCapture.md), [scheduler](../Tools/Scheduling/README.md) |

The same comparison rules apply to independent tool measurements. Synthetic rendering and
corpus decoding report generated or decoded samples and input durations. HNR and pulse stage
probes report the locked fixture, internal stage and repeated trial. Calibration and personal
target experiments report session/target counts. Archive reading and writing use records and
encoded bytes. Visualization uses points, view updates and render budgets. Each retains its
own input identity and unit of work. Frame eligibility, acoustic delay or FFT length is
inapplicable to operations such as allocating a capability-control object or encoding a
session record. See the [evidence index](Evidence/) and [instrumentation guide](Instrumentation.md).

## Measurement boundaries

| Operation | Start → stop | Work and denominator |
| --- | --- | --- |
| Cold initialization | Begin construction of a new analyzer → ready to accept PCM | One new configuration including setup tables and buffers. Report process launch and file loading separately. Repeated Prepare in a warm process measures repeated construction. |
| First valid result | Supply the first observed sample of a fresh epoch → receive the first eligible result | One epoch. Record source support, required lookahead, captured sample count and elapsed wall time. Report no-result epochs and their observed durations. |
| Prepared processing | After inputs and reusable state are ready → observable output of the declared operation | One unbatched window, callback, or explicitly sized batch. List reset, finish, output copies and diagnostics when included. Prepare fixture I/O, synthesis and oracle computation outside this interval. |
| Complete utterance | Begin analysis of the declared input → finish and consume all outputs | One utterance. Report available, rejected, partial and missing coverage by lane. Declare whether reset and teardown are included. |
| Unpaced throughput | Begin consuming prepared PCM without external pacing → drain and finish | Samples/s or input audio seconds/wall second. For masks report analyzed and source durations separately. Include any repeated work in the denominator. |

Use elapsed nanoseconds per outer iteration as the primary time. For a batch of B windows,
dividing by B gives average cost per window in that batch. Obtain single-window p50/p95/p99
from multiple **individually timed** windows with their sample count and warmup policy.
Compute real-time factor as wall seconds / source audio seconds. Compute sustained CPU as
process CPU seconds / source audio seconds. Concurrent threads can contribute more than one
CPU second per wall second.

A live report needs a source timestamp on the same clock as delivery. Record acoustic
support/lookahead, per-stage compute duration, queue wait, and timestamp/transport delay
with their own boundaries. Result age is delivery time minus the declared source reference
(e.g. frame center). Overlapping stage durations cannot simply be added. Preserve missing
timestamps, peak occupancy in sample frames, dropped-buffer counts, and reasons for gaps.

## Capabilities and acquisition context

| Metric | Unit, scope and limitation |
| --- | --- |
| Wall clock | Elapsed ns per measured operation, including preemption and waits. |
| Total CPU | Process user + system time. Includes other active threads. |
| Resident memory | Sampled process RSS in bytes. Sample rate limits peak visibility. Include prepared buffer payload separately. |
| Malloc/free and bytes | Process-wide interposed counts and allocated bytes per operation. Require a positive allocator control. Net outstanding bytes alone cannot identify a leak. |
| Object allocation, retain, release | Swift runtime diagnostic events per operation. Require a positive ARC control. |
| Queue occupancy, drops, age, validity | Application counters at a named enqueue/dequeue/output boundary. Record their units, reset epoch, observation count and coverage. |
| Signpost tracing | Record disabled, sampled or detailed mode, Instruments configuration and sampling period. Trace capture has its own overhead. |

The [environment schema](../Configuration/benchmark-environment-v1.schema.json) records
the timestamp, commit and dirty status, hardware model/architecture, OS build, Swift
and Xcode versions, target SDK, build flags, dependency pins, declared instrumentation mode
and allocator backend. The framework runners also sample power source, low-power mode and
thermal state before the measurement. A missing sensor value is `unavailable`. One preflight
reading leaves sustained thermal state unmeasured. External profiler state needs operator
observation. Binary inspection retains release settings emitted by SwiftPM for the core
library and its separate public-API consumer where available. Read project and target
overrides together. A release flag attached only to the client cannot establish how the
library was built.

Use **unsupported** when the backend does not provide the counter, **unmeasured** when the
run did not collect it, and **contaminated** for a run with known timing interference such as
an attached profiler, a thermal transition, or another workload using the machine. Keep the
raw observations and reason. Use repeated independent trials to diagnose unexplained
dispersion and mark those captures **noisy** pending investigation. Compare clean timing
only with a matching timing configuration. Compare diagnostic counts only with the same
interposer/runtime and matching positive controls.

## Budgets and baseline changes

The [current budget record](../Configuration/performance-budget-v1.json) defers device limits
to [#74](https://github.com/plx/hdxl-voice-processing/issues/74). Select thresholds from
sustained trials on the intended model, OS, profile and capture schedule. Retain warmup,
trial lengths and counts, power/thermal histories, clocks, background load, workload
manifest, raw distributions, independent validity checks and any excluded trials.

An approval records the exact scope (including a stable `acquisitionScheduleID`), source
commit, bundle-relative evidence filenames and SHA-256 digests,
review URL, approver, UTC date, and scheduling rationale. Supply a minimum throughput and
maxima for sustained CPU, unbatched p50/p95/p99 processing time, result age, peak RSS,
backlog and dropped buffers. Describe the permitted backlog/dropout behavior. A replacement
also supplies a bundle-relative `previousApprovalFile`, its `previousApprovalSHA256` and a
`changeReason`. The validator checks that each predecessor is an approved record for the
same scope and verifies its evidence chain. Validate an approval
and its adjacent evidence files with `python3 Tools/Performance/budgets.py RECORD.json`.
Local scratch baselines are observations. Publishing or replacing an approved baseline
requires review of that record and its underlying evidence.

The [validation results](Evidence/benchmark-contract.md) include two denominator audits
and a compiler comparison protocol. Framework units and histogram semantics follow the
[pinned metrics documentation](https://github.com/ordo-one/benchmark/blob/1.38.0/Sources/Benchmark/Documentation.docc/Metrics.md)
and [percentile guide](https://github.com/ordo-one/benchmark/blob/1.38.0/Sources/Benchmark/Documentation.docc/AboutPercentiles.md).
