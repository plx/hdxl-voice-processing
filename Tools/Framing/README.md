# Framing developer tools

These tools are not runtime dependencies or resources. They implement the reference
and host-performance evidence for [#24](https://github.com/plx/hdxl-voice-processing/issues/24).
The numerical and lifecycle contract is in [Documentation/Framing.md](../../Documentation/Framing.md).

## Gaussian reference

Acquire the exact Praat executable through the [reference setup](../Reference/README.md),
then verify the committed coefficient fixture:

```sh
python3 Tools/Framing/reference.py .build/reference-tool/7.0.02/Praat.app/Contents/MacOS/Praat
```

`--write` intentionally regenerates the fixture and its provenance entry. The
script verifies the executable SHA-256 before launching it with the pinned flags,
creates exactly N ones, applies `Gaussian2`, and exports coefficients for
N=1,2,3,4,5,17,1000. An original 70-digit Decimal calculation independently checks
every value within absolute error 5e-15. Regeneration compares numerical values
with that tolerance while requiring exact tool/configuration identities; harmless
last-place text formatting differences do not become false mismatches. The fixture retains raw text, tool/source
identity, wrapper hashes, and both numeric oracles. Inputs contain no human voice.
Only numerical results are redistributed; no GPL implementation is copied, linked,
or bundled. Python tests validate dimensions, indices, finite values, hashes, and
the archived output; Swift tests compare prepared coefficients against both oracles.

## Timing and allocation matrix

```sh
python3 Tools/Framing/benchmark.py timing
python3 Tools/Framing/benchmark.py allocation
```

Run these sequentially so measurement processes do not contend. Both use the
isolated `Benchmarks/` package and its locked dependency graph. Existing smoke
benchmarks explicitly select `VoiceDSPBenchmarks`; these select `FramingBenchmarks`.
The first run builds dependencies. Each workload has three warmups, up to 30
measured iterations and a ten-second limit; validation requires at least ten
measured samples per metric, including the maximum-size workloads. The workload checker verifies frame counts and
observable windowed checksums for all configurations/chunk sizes before measuring.
The independent Python matrix checks every configuration, identity, requested/actual
geometry, frame count, and prepared sample-buffer byte count, including six literal
131,072-sample cases. Native buffers must retain their byte count across both
chunking strategies; the maximum payloads are 1.5 MiB (Float) and 3 MiB (Double).

There are 88 configurations: two precisions × three rates × three Gaussian support
lengths × four requested hops (72), maximum supported N=131,072 at each rate and
precision (6), and the other five window shapes at 48 kHz/50 ms/5 ms for both
precisions (10). Each has five workloads: preparation/destruction, 100 cached window
writes, 100 resets, a whole-input chunk, and the same input in 17-sample chunks.
Inputs are at least one second and at least N+10H samples for maximum-size cases.
The source is an exact original ramp, prepared before measurement. Setup, buffers,
profile hashing, and input generation are excluded from steady-state measurements.
Whole-input and small-chunk workloads include validation, ring writes, assembly,
window application, observed-output checksum, and finish. Window reuse and reset
have 100 operations per measured iteration; all other workloads have one. Framework
scaling remains one, so exported values are raw batch costs, not per-operation costs.

Timing disables allocation instrumentation and records wall/CPU time. Allocation
mode enables the reviewed malloc interposer and Swift ARC hooks, with an explicit
positive control for all six diagnostics. Every steady-state histogram must show
zero maximum malloc count, malloc bytes, and object allocation count. ARC retains
and releases are reported and may be nonzero. Preparation is expected to allocate.
This gate covers prepared default-disabled instrumentation and nonallocating
consumers; it does not imply audio-callback suitability or device timing guarantees.

Evidence is written to `Benchmarks/.build/artifacts/framing-{timing,allocation}/`:

- `environment.json`, `resolution.json`, and `workloads.json`: toolchain/hardware,
  precision, profiles, rates, requested/actual windows/hops, duration and operation counts.
- `raw-baseline.json.gz`: fresh full histograms, with the hostname removed.
- `distributions.json`: sample count and maximum for each metric/workload.
- `p99.json`: verified unscaled nanoseconds/counts; throughput can be derived by
  dividing the corresponding input duration by the batch duration.
- `result.json`, `commands.log`: validation outcome and redacted command evidence.

Fresh unique temporary baselines prevent stale samples from satisfying a run. The
wrapper fails if metrics, capabilities, units, workload coverage, or lockfile state
do not match. Use raw distributions when inspecting variability; allocation-mode
timing includes diagnostic overhead and is not the ordinary timing baseline.
Host/simulator results do not replace the physical evidence deferred to #74.
