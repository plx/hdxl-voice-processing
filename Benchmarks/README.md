# Host benchmark workspace

This separate SwiftPM package depends on the root library by local path. Runtime
consumers do not resolve Benchmark, build its plugins, or link its allocators.
The initial original gain/energy loop verifies the harness; it is not a production
voice metric or a performance claim about algorithms not yet implemented.

## One-command modes

From the repository root with Xcode 27.0 (27A266a), Swift 6.4 and Python 3.14.8:

```sh
python3 Tools/benchmark.py timing
python3 Tools/benchmark.py allocation
```

Both commands build optimized executables, verify environment, locked resolution,
selected manifest and binary linkage, exercise plugin discovery/filtering, run
the workload, and validate fresh JSON results. First use needs network access to
fetch pinned packages. No system jemalloc, signing identity, or microphone is needed.

| Mode | Trait | Backend | Metrics |
| --- | --- | --- | --- |
| timing | None | Malloc interposition disabled; ARC hooks not requested | Wall-clock and total CPU time |
| allocation | `AllocationDiagnostics` | malloc-interposer 1.6.1 and native Swift 6.4 ARC hooks | Wall-clock, malloc/free counts, bytes, object allocations, retains/releases |

The nested manifest conditionally enables only Benchmark's `MallocInterposer`
trait; it never inherits upstream defaults. Modes have separate `.build/timing`
and `.build/allocation` scratch directories. The wrapper rejects allocator,
local-checkout, and preload environment overrides. Instrumented diagnostic timing
must not be compared as uninstrumented performance.

`Capability.AllocationARC` deliberately allocates/frees a buffer and retains/releases
a Swift object. Every diagnostic counter must be present, finite, and positive
in this control. Zero allocations in the preallocated DSP workload are accepted
only with that positive control. Legacy `allocatedResidentMemory` and `memoryLeaked`
metrics are unavailable, not zero. These checks do not prove leak freedom or
device real-time safety.

## Outputs and boundaries

Each invocation replaces `Benchmarks/.build/artifacts/<mode>/<operation>/`:

- `Current_run.json`: framework `jsonSmallerIsBetter` export. `value` is p99 in its
  explicit unit, per **outer iteration**: 1,000 smoke frames of 1,024 samples, or
  one capability operation. The framework scaling factor is explicitly one;
  batching is in our loop, so export units do not depend on implicit normalization.
  Future scaled-export adoption is tracked in [#82](https://github.com/plx/hdxl-voice-processing/issues/82).
- `workload.json`: optimized output checksum, energy, source format, compiled mode,
  and proof the initially zero output buffer changed.
- `environment.json`, `resolution.json`, `result.json`, `commands.log`: actual
  host/toolchain/SDK identities, exact pins, outcomes/durations, selected manifest,
  binary linkage, and observed capabilities.

The input is `((i * 37) % 257 - 128) / 128` for `i = 0..<1024`. Each kernel call
applies gain 0.5 into a preallocated output buffer and sums its squares. Setup precedes
measurement; explicit start/stop calls bracket 1,000 non-inlined kernel calls with
`blackHole` consumption. Checksum traversal and teardown are untimed. Three warmups
precede at most 100 measured iterations or one second. This is a short smoke
configuration; controlled protocols and regression baselines belong to #20.

Independent Python IEEE-754/FNV computation gives checksum `b60cf45de1595748` and
energy `86.15017700195312`. The vector uses exact dyadic arithmetic. Both optimized
modes check these values; each measured batch validates its output afterward.
Do not regenerate expectations to accommodate an unexplained mismatch.

Upstream export can return zero after a write failure. The wrapper therefore
rejects missing/empty exports, missing/duplicate/unexpected metrics, invalid
numbers, and absent capabilities. Plugin write permission covers the nested
package. The smoke CI job uploads only generated JSON/logs, not binaries, raw
baseline storage, recordings, or private fixtures.

## Discovery, filtering, and baselines

```sh
python3 Tools/benchmark.py timing list
python3 Tools/benchmark.py allocation list
python3 Tools/benchmark.py timing baseline-update --baseline seed
python3 Tools/benchmark.py timing baseline-read --baseline seed
python3 Tools/benchmark.py timing baseline-compare --baseline seed
```

The same operations work with `allocation`. Names are prefixed by mode, such as
`timing-seed`, in ignored `Benchmarks/.benchmarkBaselines/`. Comparison measures
the current build and reports differences without enforcing timing thresholds.
Update/compare first write a uniquely named fresh baseline and validate its export.
Update atomically replaces the requested baseline only after validation; failed
writes cannot reuse old samples. Comparison reads that same stored capture and
the selected baseline, so the retained JSON and reported deltas share one run.
`captured-baseline.json` retains the current distributions with hostname redacted;
`capturedResultSHA256` identifies their canonical results. Temporary captures are
removed afterward. Raw baseline artifacts are excluded from default CI uploads.
On `baseline-read`, environment metadata describes the reader, not the original
measurement. Cross-machine/configuration comparability and threshold policies
are #20 work; these smoke baselines are not release evidence.

Discovery requires `Benchmarks/Benchmarks/VoiceDSPBenchmarks/`: the executable's
immediate parent directory must be named `Benchmarks`. `WorkloadCheck` is under
`Sources/` and is excluded. Runs exercise the filter
`^(Smoke\.GainEnergy|Capability\.AllocationARC)$`; timing exposes only the first.
Exact native invocations are recorded in `result.json`. For example:

```sh
swift package --package-path Benchmarks --scratch-path .build/timing \
  --force-resolved-versions -c release --allow-writing-to-package-directory \
  benchmark run --filter '^Smoke\.GainEnergy$' --format jsonSmallerIsBetter \
  --path "$PWD/Benchmarks/.build/manual-export"
```

## Reviewed dependency and platform matrix

The requested [1.38.0 release](https://github.com/ordo-one/benchmark/tree/1.38.0)
is accepted unchanged at `def9afdba446b03efbbbcecb3b892e97e8294214`.
`Package.resolved` pins all eight remote packages, including the optional allocator.
Both modes require locked resolution and fail on lock changes. The root has no
remote dependencies; consumer link checks also reject benchmark/interposer libraries.

| Item | Selection |
| --- | --- |
| Harness tools/language | Swift tools 6.4, language mode 6 |
| Minimum host | macOS 27, per owner MVP scope |
| Selected upstream manifest | `Package.swift`, tools 6.3; verified by `dump-package` and SHA-256 |
| Alternate manifests | 5.9/6.2 exist but are not selected; their jemalloc setup is unused |
| Upstream platforms | macOS 13 / iOS 16 declarations do not broaden this harness's support |
| Malloc backend | Optional malloc-interposer 1.6.1 package; no system installation |
| ARC backend | Native Swift 6.4 hooks; no Linux 6.3 runtime interposer |
| Device support | No iOS, watchOS, or physical-device benchmark claim |

`Configuration/benchmark.json` records the selection. Full revisions, license-file
hashes, and the allocator's SwiftNIO-derived notice are in the provenance manifest
and `THIRD_PARTY_NOTICES.md`. Dependencies are fetched for development, not vendored
or shipped in runtime products.

Primary release documentation:
[getting started](https://github.com/ordo-one/benchmark/blob/1.38.0/Sources/Benchmark/Documentation.docc/GettingStarted.md),
[writing benchmarks](https://github.com/ordo-one/benchmark/blob/1.38.0/Sources/Benchmark/Documentation.docc/WritingBenchmarks.md),
[manifest](https://github.com/ordo-one/benchmark/blob/1.38.0/Package.swift).
