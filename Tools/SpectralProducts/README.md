# Spectral product measurements

Run each command from the repository root. The pinned host job uses the Xcode version in the correctness configuration. Pass `--development-toolchain` for a separately identified local series.

```sh
python3 Tools/SpectralProducts/benchmark.py timing
python3 Tools/SpectralProducts/benchmark.py allocation
```

The matrix uses 1, 10 and 60 seconds of deterministic binary64 mono PCM at 16, 44.1 and 48 kHz. The spectral window is a periodic Hann of 20 or 64 ms, rounded to the nearest sample, and the hop is half its integer length rounded down. The FFT pads to the next power of two. The canonical cepstrogram uses finite-FIR preview conditioning to 4 kHz, a 20 or 64 ms physical Gaussian window, and 10 or 32 ms hops. Its unavailable tail is counted in the export and retention trials. The stored case rows include both complete configurations, expected work and the source interval.

Each operation has two warmups and up to 15 measured whole-interval trials. The runner requires at least 10 real observations in each distribution. Prepared input, canonical reference rows, worker initialization, ring allocation and output verification are outside the timed scope. The offline fixture in the harness intentionally retains the input rows to measure consumers independently. Each measurement has an observable scalar or checked final state.

| Operation | Timed work |
| --- | --- |
| Generate, CepGenerate | PCM to borrowed canonical columns, one probe per row, and finish |
| LTAS | Linear accumulation of every precomputed eligible spectrum through its borrowed view, including weight/order/identity checks |
| Retain8, Retain64 | Copy borrowed spectra into the bounded ring and evict at capacity |
| CepRetain8, CepRetain64 | Retain already-owned canonical cepstral rows in each ring capacity |
| Export, CepExport | Copy borrowed columns through each public owned exporter, including the canonical cepstral validation and normalization |

Each run writes a new directory under `Benchmarks/.build/artifacts/spectral-products-{timing,allocation}`. The shared [workload manifest](../../Documentation/BenchmarkProtocol.md) binds the case definitions, environment, distributions and p99 export. Raw histograms and p50, p95, p99 and maxima describe the unscaled whole-interval trial. The CSV reports throughput at p50 and p99 whole-interval latency. For a fixed frame count, the latter is a lower-tail frame rate. Separate instrumented runs report heap allocations, allocated bytes, frees, object allocations, retain and release counts with a positive capability control. The spectral copy and retention operations permit at most two heap allocations per row in a measured interval. This detects per-bin allocation regressions. Hardware and toolchain are in the environment record.

The timing runner additionally streams ten minutes of 48 kHz PCM through the public spectrogram, LTAS and 64-column ring. It reuses one second of input and takes ten observations of live malloc-zone bytes, eviction counts and measured frame counts. The ring count must plateau at 64 and the complete history must match the known grid. The 16 MiB live-heap spread allowance detects unbounded retention at this geometry. This test measures a synthetic host workload. Physical-device energy, thermal behavior and headroom are tracked in [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
