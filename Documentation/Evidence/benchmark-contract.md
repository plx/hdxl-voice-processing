# Benchmark contract verification

The macOS host processed each input as a whole buffer and the iOS 27.0 Simulator
processed blocks of at most 17 samples. Both read portable manifest
`58d5efd2e84b3fd432ae7d8ec368a7ea13c609d22b2122874a64f94f0f0218e3`.
All 12 workload IDs, PCM hashes, profile hashes and status counts matched. The
two reports each contain 114 frames, 93 with available F0 and 21 without. The
gap case emits five frames over two independently finished regions. The
[portable verifier](../../Tools/Performance/verify_portable.py) reproduces the
comparison with public fixtures and checks the independent expected counts.

## Two reported denominators

The audited artifacts come from the tested merge tree of [PR #167](https://github.com/plx/hdxl-voice-processing/pull/167/checks),
commit `702d4cce35aafbfe209c1b727fbcec6779684a86`. The 72 timing and 72 allocation
case matrices link 3,350 timing operations and 3,334 allocation operations (including
controls) to their data. Timing-only concurrent comparisons account for part of the
difference. The two examples below show why a benchmark name and a percentile alone
are insufficient to compare latency.

- `Smoke.GainEnergy` reported 1,416 µs at p99 for 1,000 calls on a prepared
  1,024-sample buffer. That is 1,416 ns **on average within that batch**. The
  run has no distribution of individual-frame latencies.
- `Schedule.Run.light.float32.16000Hz.c1.interleaved.preview` processed one
  second of mono input and reported a wall-clock p99 of 31,942,250 ns and a
  process CPU p99 of 31,945,957 ns. At the wall p99 the throughput is
  31.306 input audio seconds per wall second and the real-time factor is
  0.03194225. Its levels lane returned 98 available out of 99 frames and the
  pitch lane 96 out of 97. CPPS was disabled. This synthetic unpaced run has
  no capture-to-result timestamp.

Run `python3 Tools/Performance/denominators.py SMOKE_TIMING_DIR SCHEDULER_TIMING_DIR`
to check the units and denominators on retained artifacts. Use `--case` for a
different scheduler composition.

## Compiler and client configuration

A Mac13,1 (arm64, macOS 27.0.1, Xcode 27.2, Swift 6.4.2) ran eight fresh processes
per binary after one warmup. Execution order rotated each trial. The separate
client used the public package API in every build. Each process loaded the same
manifest, replayed all inputs in 17-sample blocks, checked identities and counts,
and wrote its report. The interval includes process launch, file reads, decoding,
analyzer construction and output. This is a client invocation cost. Prepared
DSP and single-window timing have their own boundaries.

| Library and client build | Median wall time for the invocation |
| --- | ---: |
| Unoptimized, per-file compilation | 3,458.947 ms |
| Optimized, per-file compilation | 53.262 ms |
| Optimized, whole-module compilation | 52.328 ms |
| Optimized, whole-module compilation with library evolution | 52.301 ms |

The unoptimized result illustrates why the build mode matters. The optimized
distributions overlap. Eight samples on this host leave the small differences
between optimized variants unresolved. All four return identical work and
eligibility counts. These values carry no physical-device threshold.
`python3 Tools/Performance/compare_builds.py NEW_OUTPUT_DIR` retains the exact
build commands, per-trial values, settings and report identity.
