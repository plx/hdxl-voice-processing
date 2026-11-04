# Fourier development tools

These tools are original developer-only numerical/performance utilities. They are
not runtime package dependencies and do not use a network service.

- `python3 Tools/Fourier/oracle.py` regenerates the direct-definition DFT expectations
  in memory and checks the committed artifact. `--write` explicitly replaces that
  original artifact and updates its provenance record. Changes to the generator
  require regeneration; the recorded SHA-256 identifies the source.
- `python3 Tools/Fourier/benchmark.py timing` runs optimized measurements without
  allocator interposition. `allocation` runs a separate binary with the pinned
  allocation/ARC backend and positive controls. Both preserve Package.resolved.

The matrix includes Float and Double at N=32,128,256,512,1024,2048,4096,8192,16384,
32768,65536, all at 48 kHz. N=32/128 supply bounded direct scalar DFT comparisons;
256...8192 cover ordinary transforms and the remaining sizes exercise maximum
supported workspaces. Each configuration records its transform/spectrum identities,
input duration, rectangular window, precision, and operations per iteration. These
primitives have no hop or stream buffering; input duration is N/fs.

Inputs are original seeded LCG samples, generated and validated before measurement.
Each prepared iteration performs ten operations; setup rows create and destroy one
plan or conversion object. Spectrum rows perform a real forward transform and
one-sided window-normalized power conversion. Cepstrum rows perform a real forward,
`log(max(rawPower,1e-30))`, and real inverse. **That floor is an explicit benchmark
consumer setting**, not an FFT default or a claimed Praat CPPS implementation.
Scalar comparisons accumulate the direct complex sum in Double for both input
precisions and are limited to N<=128.

Timing also compares four independently prepared actors, each doing ten spectrum
or cepstrum operations, sequentially and through a task group. Both measurements
include actor/task scheduling. Their values represent forty operations and must
not be compared directly with a ten-operation row. Actor creation and warmup occur
outside measurement. The concurrency comparison is timing-only; its task allocation
costs are not included in the transform allocation-free claim.

There are three warmup iterations and up to thirty measured iterations, with a
10-second per-case limit. Verification requires at least ten actual samples per
metric. `raw-baseline.json.gz` preserves histograms with the hostname redacted;
`distributions.json` records sample counts/maxima; `p99.json` reports unscaled outer
iteration p99. Explicit nanosecond/count units prevent automatic K/M conversion.
Artifacts live in `Benchmarks/.build/artifacts/fourier-{timing,allocation}` and
include toolchain/SDK/hardware, revision, configuration, commands, dependency pins,
and binary-link inspection. Only the six prepared native operations must have
zero heap allocation maxima; setup and scalar comparison allocations are recorded
separately. Every allocation/ARC hook must pass its positive control.

The dedicated workflow runs this same matrix on relevant PRs, weekly, or manually.
Correctness CI's Python tests independently regenerate the scalar fixture offline.
Host measurements are engineering evidence, with no physical-device or thermal
claim; that collection remains follow-up #74.
