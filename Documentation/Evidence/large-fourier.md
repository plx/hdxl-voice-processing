# Whole-interval Fourier capacity evidence

This #95 extension enables #31's whole-interval reference conditioning. At 48 kHz,
60 seconds plus two 1,000-sample reference padding margins requires 2,882,000
samples and the next power of two, 4,194,304. Every power of two from 2 to that
maximum is supported in Float and Double. The independent analysis-window limit
remains 65,536; this is a bounded worker-side capacity, not a device performance
budget or a causal streaming filter.

Collected 2026-11-04 on Mac13,1 (arm64), macOS 27.0.1 build 26A434, Xcode 27.0
build 27A266a, Swift 6.4 (`swiftlang-6.4.0.34.1`), Python 3.14.8. Local results are
working-tree measurements based on main `f61b2aec4d3aef63ebb2751e9a364a5f7b076c8d`.
Hosted checks for the reviewed commit are recorded in the PR conversation. Physical
device, thermal, and audio-callback evidence remains deferred under #74.

## Calibration and independent expectations

Raw installed vDSP Double impulse probes at each added length (131072 through
4194304) reproduce the original conventions: real forward packed values 2,
complex forward values 1, and unnormalized inverse first sample N for canonical
impulse spectra. No transform kernel, packing, precision, or normalization changed.

The independently generated direct-definition DFT fixture now has 192 cases and
22 lengths. All original 168 case objects, including inputs, expectations, and
budgets, are unchanged. The added 24 cases cover real/complex forward transforms
at all six new lengths and both precisions, using selected bins including DC,
interior frequencies, Nyquist, and a negative-frequency bin. Full transforms in
the scalar generator remain bounded to N<=128; larger vectors request at most
16 bins. Native code and Accelerate are not used to generate expectations.

| N | Float maximum budget fraction | Double maximum budget fraction |
| ---: | ---: | ---: |
| 131072 | 0.054031 | 0.003937 |
| 262144 | 0.037126 | 0.003256 |
| 524288 | 0.028204 | 0.008548 |
| 1048576 | 0.033648 | 0.005414 |
| 2097152 | 0.041815 | 0.010313 |
| 4194304 | 0.040918 | 0.011309 |

These are observed component-error/budget ratios for the committed input family;
1 would reach the declared limit. The original `C*u*log2(N)*||input||2` budgets
remain unchanged. All-bin real/complex round-trip and Parseval tests cover every
added length in both precisions, including same-buffer complex inverse. Energy
references now use compensated Double summation: naive accumulation of millions
of terms produced false failures against the original Double tolerance. The
transform tolerance was not relaxed.

Fixture SHA-256: `89f89706746fb81400350f6f132083eb46df796f5b7cd8b453047fad8f61fe88`.
Generator SHA-256: `6245ab672b1428b13fb003858ebb21278fef2a0914404dd82f996d3c29b66997`.

The large Swift cases run sequentially inside one test to avoid simultaneous
maximum-size plans. Input hashing uses bounded 64 KiB blocks and selected oracle
comparisons retain only requested results. Every reconstructed sample is still
checked, with a maximum-error reduction instead of millions of individual test
macro invocations. Larger or non-power-of-two lengths fail, and explicit padding
boundary tests cover 60 seconds at 16/44.1/48 kHz without truncation.

## Memory and measurement boundaries

The plan's two N-element scalar buffers at maximum size are 32 MiB for Float or
64 MiB for Double. Separate complex input and output add 64 MiB or 128 MiB.
Opaque vDSP setup tables, object overhead, allocator retention, and surrounding
application state are additional. These counts do not estimate total process RSS.

The new twelve-configuration matrix retains only the chosen operation's buffers.
Each iteration performs one preparation/destruction or one prepared real/complex
forward/inverse transform. Three warmups precede up to thirty measured iterations,
with a 60-second per-case limit and a minimum of ten samples. Preparation includes
setup and workspace allocation; fixture generation and verification are outside
warm measurement. All timings below are p99 **milliseconds per single operation**,
not the original matrix's ten-operation averages. No large parallel-plan workload
is asserted here.

`peakMemoryResident` is a whole-process observation from the pinned backend's
approximately 10 ms jittered sampling of macOS `proc_pidinfo`. It includes harness,
setup, caller buffers, and retained allocator pages. It can miss short-lived
peaks, is not exclusive per-operation memory, and is not a device memory budget.
The explicit backend count unit represents one byte. Timing has no malloc
interposer; allocation diagnostics use a separate binary and positive controls.

## Local optimized measurements

All 60 timing rows (180 metrics) and 61 allocation rows including the positive
control (488 metrics) recorded thirty measured samples per metric. The complete
144 prepared heap histograms (12 configurations × 4 operations × 3 heap metrics)
had maximum zero. All six allocation/ARC controls were positive. This proves the
observed prepared paths under this host/backend, not setup, task, or callback
allocation behavior.

| N | Precision | Prepare ms | Real forward ms | Real inverse ms | Complex forward ms | Complex inverse ms | Largest sampled process RSS MiB across these rows |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 131072 | float32 | 8.949 | 6.373 | 2.486 | 8.939 | 9.123 | 32.9 |
| 262144 | float32 | 14.357 | 12.520 | 5.171 | 17.252 | 18.737 | 115.3 |
| 524288 | float32 | 25.406 | 24.894 | 10.228 | 35.262 | 37.750 | 134.7 |
| 1048576 | float32 | 47.462 | 50.446 | 20.440 | 69.907 | 75.746 | 168.7 |
| 2097152 | float32 | 97.050 | 101.050 | 40.917 | 143.002 | 152.041 | 367.0 |
| 4194304 | float32 | 223.910 | 202.065 | 83.880 | 289.256 | 303.055 | 851.5 |
| 131072 | float64 | 2.414 | 6.740 | 3.107 | 9.726 | 10.302 | 25.9 |
| 262144 | float64 | 5.196 | 13.364 | 5.981 | 19.484 | 20.555 | 43.0 |
| 524288 | float64 | 9.156 | 27.045 | 12.159 | 39.120 | 41.602 | 57.7 |
| 1048576 | float64 | 18.879 | 53.867 | 24.252 | 77.556 | 82.524 | 105.7 |
| 2097152 | float64 | 36.146 | 105.134 | 48.785 | 155.591 | 168.492 | 201.7 |
| 4194304 | float64 | 71.794 | 212.072 | 98.541 | 316.794 | 330.025 | 393.8 |

The largest sampled process observations were 892,846,080 bytes in timing and
895,959,040 bytes in allocation mode. The highest row was Float, despite its
smaller explicit scalar buffers; do not infer total memory from element width.
These observations motivate collecting actual device peaks and adjusting
conditioning limits under #74. No explanation of opaque backend memory use or
cross-device memory guarantee is inferred from these measurements.

Raw timing distribution SHA-256:
`629c202b93aa5d1a8ee578872bd7a8119298487e1c10122ca99036c531e9cfae`.
Raw allocation distribution SHA-256:
`a451be6a5f38b70dd56db03421d93b859fc335976c1fae8afae2b5cf4a1b1db3`.

Reproduce with `python3 Tools/Fourier/large_benchmark.py timing`, then `allocation`.
Each wrapper retains environment, workload identities, dependency pins, binary
linkage checks, command logs, raw histograms, sample counts/maxima, and p99 exports.
The locked dependency resolution remained unchanged. Full native numeric checks
run in correctness CI; the dedicated large Fourier job collects both host
measurement modes. The original ordinary-frame matrix keeps its existing scope.
