# A03 conditioning developer tools

These tools are outside the shipped package. They use original mathematical PCM; no human
recordings or runtime reference-tool dependencies are added.

- `python3 Tools/Conditioning/reference.py` verifies all 184 fresh outputs against the committed
  fixture, with the binary pinned by `Tools/Reference/toolchain.json` already installed using
  `python3 Tools/Reference/setup.py`. `--tool` selects its path, not a different permitted hash.
- `--write` is an explicit candidate-generation operation. Review numerical changes, generator
  hashes, and provenance before committing. It is never used by correctness or regeneration CI.
- `reference.praat` exports axis metadata, output samples, and their predecessors using numeric
  queries. It avoids the unrelated WAVEFORMATEX reader limitation tracked in #88.
- Raw pre-emphasis uses an original scalar implementation of the published equation. A separate
  calibration records Praat menu peak normalization; menu output is not the raw pipeline oracle.

`python3 Tools/Conditioning/benchmark.py timing` and `allocation` produce separate evidence under
`Benchmarks/.build/artifacts/conditioning-{mode}`. Both use the exact nested dependency lock and
validate toolchain, backend linkage, fresh baseline identity, workload coverage, and checksums.
The wrapper preserves raw distributions and p99 exports with framework scaling factor one.

The 120-case matrix is:

- 2 profiles × 2 precisions × 3 source rates (16/44.1/48 kHz) × 3 targets (10/11/16 kHz)
  × 3 input chunks (64/256/1024) at one second: 108 cases.
- 2 profiles × 2 precisions × 3 sources to 10 kHz at 60 seconds/chunk1024: 12 cases.

Each case measures three operations, with 3 warmups and up to 30 measured iterations (30-second
cap per operation). Evidence requires at least 10 samples. `Prepare` includes construction and
destruction of one conditioner; input synthesis and downstream FFT/framer setup are excluded.
`Condition` includes resetting prepared history, consuming the complete interval, finalizing,
and an observable sum-of-squares checksum. `ConditionFFT` adds rectangular 1024-sample frames,
hop256, a 1024-point real FFT, and one-sided Parseval energy. Its target-domain framing epoch is
explicitly distinct from original source coordinates. Partial frames are discarded. These are
worker-throughput cases, not capture-callback or single-chunk deadline measurements.

A separate setup check verifies output counts, frame counts, direct time-domain versus Fourier
energy, and identical checksums across chunk partitions. `workloads.json` records source/target
rates, precision, profile identity/settings, durations, chunk/frame/hop sizes, filter delay,
scalar working memory, prepared-input memory, and checksums. Scalar bytes exclude opaque
Accelerate setup, objects, and allocator bookkeeping. `ConditionFFT` workspace adds the FFT,
output bins, and the framer's two raw buffers plus prepared window coefficients.

Allocation mode requires positive malloc/free/object/retain/release control observations, and
zero maximum malloc count/bytes/object-allocation counters for **both prepared operations** at
every configuration. ARC retain/release counts are reported, not claimed to be zero. Setup is
measured separately and may allocate. Timing mode verifies allocator instrumentation is absent.
No physical memory, latency, energy, or thermal acceptance threshold is inferred from this host
matrix; those measurements remain in #74.

See [API semantics](../../Documentation/Conditioning.md),
[evidence](../../Documentation/Evidence/conditioning.md), and
[attention #98](https://github.com/plx/hdxl-voice-processing/issues/98).
