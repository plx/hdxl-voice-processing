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
256...8192 cover ordinary transforms and 16384...65536 exercise larger frame
workspaces. Each configuration records its transform/spectrum identities,
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

## Whole-interval capacity matrix

`python3 Tools/Fourier/large_benchmark.py timing` and `allocation` measure a
separate Float/Double matrix at N=131072,262144,524288,1048576,2097152,4194304,
all at 48 kHz. These sizes support the whole-interval reference conditioning
requirement in #31/#95. Those changes retained the then-current 65,536-sample
window bound; the shared framing capacity was later extended separately to
131,072 samples in #165. Fourier capacity remains 4,194,304.

Every iteration measures **one** plan preparation/destruction or **one** prepared
real/complex forward/inverse transform. Input seed 95, transform identity, precision,
rate, exact scalar workspace bytes, and per-operation caller-buffer bytes appear
in `workloads.json`. `transformBufferSeconds=N/fs` describes the synthetic buffer,
not certified utterance duration. Only the selected operation's buffers are retained;
there are no parallel large-plan rows. The checker independently verifies DC or
inverse sample zero against scalar sums before measurement. The full numerical
correctness suite separately validates selected bins, round trips, and energy.

There are three warmups and up to thirty measured iterations, with a 60-second
per-case limit and a minimum of ten actual samples. The raw histograms and p99
exports use framework scaling one and nanoseconds per operation. All four prepared
operations must have zero maximum malloc/object-allocation counts and gross malloc
bytes in allocation mode; setup is exempt. Each allocation/ARC hook has a positive
control. Timing uses no allocator interposition; diagnostic timing is not a clean
performance baseline.

Both modes also record `peakMemoryResident`. On macOS the pinned backend samples
`proc_pidinfo` resident bytes approximately every 10 ms with jitter, across the
benchmark process. The count unit `#` here is explicitly one byte. The observation
includes the harness, setup, caller buffers, allocator retention, and runtime; it
is neither exclusive workspace memory nor a precise per-operation high-water
mark. Short-lived peaks between samples may be missed. A missing/zero observation
fails validation, but a positive observation is not approval of a device budget.
At maximum size the owned Double scalar workspace is 64 MiB and separate complex
input/output total 128 MiB, before opaque vDSP setup and other process costs.

Artifacts live in `Benchmarks/.build/artifacts/fourier-large-{timing,allocation}`.
The dedicated large Fourier workflow collects both modes on relevant PRs, weekly,
or manually. [Extension evidence](../../Documentation/Evidence/large-fourier.md)
records host results. Physical feasibility and any resulting budget adjustments
remain follow-up #74.
