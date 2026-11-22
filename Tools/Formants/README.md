# Burg formant reference and performance workloads

Run from the repository root on the supported macOS development toolchain.

```sh
python3 Tools/Reference/setup.py
python3 Tools/Formants/reference.py --executable .build/reference-tool/7.0.02/Praat.app/Contents/MacOS/Praat
swift test --filter BurgFormantTests
python3 -m unittest discover -s Tools/Tests -p 'test_formants.py'
python3 Tools/verify-provenance.py
```

The generator checks the reference executable's SHA-256, synthesizes seven deterministic PCM16 signals and verifies the source hashes for three 200 ms PVQD excerpts beginning at 500 ms. Corpus rights and attribution are registered with the original recordings. The JSON contains synthetic PCM integers and numerical measurements. Its two reference passes record the complete candidate list and Praat's frequency-ranked, edge-filtered list. Frame centers, settings, script and generator identities travel with the measurements. To intentionally regenerate the fixture and its inventory record, add `--write`.

```sh
python3 Tools/Formants/benchmark.py timing
python3 Tools/Formants/benchmark.py allocation
```

On an alternative installed toolchain, add `--development-toolchain` to identify development evidence. The 72 geometries cross source rates of 16, 44.1 and 48 kHz with 5, 5.5 and 6 kHz ceilings, orders 8, 10, 12 and 16, and hops of 5 and 10 ms. Every trial uses binary64. Preparation constructs plans, buffers, fixed-seed PCM and polynomials, then preloads the dedicated resampler. Each operation validates that it consumed the declared work.

| Operation | Work inside each measurement | Throughput unit |
| --- | --- | --- |
| Resample | Resample one preloaded 100 ms interval with the production conditioner. | Source samples/s |
| Burg | Normalize, window and fit a single 50 ms frame. | Frames/s |
| Roots | Solve a known stable polynomial at the configured order. | Polynomials/s |
| CloseRoots | Solve a narrow-band polynomial with two resonances 12 Hz apart. | Polynomials/s |
| BoundedExit | Exercise both starts on that difficult polynomial with one sweep allowed per start. Verify explicit nonconvergence. | Polynomials/s |
| Analyze | Analyze 100 ms of PCM through the public prepare-once API, including complete conditioning, all frame estimates, owned results and consuming the prediction gain. | Emitted frames/s |

The root-only rows consume coefficients and have zero input-audio duration. The bounded-exit workload measures retry and refusal overhead at the reduced limit. Production allows up to 128 sweeps. This profile assigns each frame independently and incurs no continuity-tracking stage.

Each mode records 101 trials per operation. Timing records wall and CPU distributions. A separate allocator-instrumented binary records allocations, frees and ARC counts with a positive capability control. The artifacts include machine and toolchain identity, workload manifest, raw histograms, p50/p95/p99/maxima, per-operation units and achieved throughput. Inspect `Benchmarks/.build/artifacts/burg-formants-{timing,allocation}/`. Hosted results quantify worker computation. Device acquisition latency, thermal behavior and sustained missed deadlines are tracked in the physical evidence issue. [Analyzer guide](../../Documentation/BurgFormants.md) · [Benchmark protocol](../../Documentation/BenchmarkProtocol.md) · [Physical evidence](https://github.com/plx/hdxl-voice-processing/issues/74)
