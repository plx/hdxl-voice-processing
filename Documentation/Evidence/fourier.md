# A02 Fourier calibration and host evidence

Collected 2026-11-04 on Mac13,1 (arm64), macOS 27.0.1 build 26A434,
Xcode 27.0 build 27A266a, Swift 6.4 (`swiftlang-6.4.0.34.1`). This is a local
working-tree measurement of the #30 implementation based on main
`bbf7fb45788c23b64229ee5770c1e0eaf007897b`. Hosted checks and artifacts for the
reviewed PR head will be verified before merge and linked in its conversation.
No physical iPhone/iPad, thermal, capture-deadline, or clinical claim is made.

## Calibration and numerical accuracy

Raw installed Accelerate Double impulse probes at N=2,4,8,16,256,65536 produced:
real forward DC/Nyquist=2 (all interior real bins 2); inverse of canonical impulse
spectrum returned first sample N; complex forward bins 1 and complex round trip
first sample N. The wrapper's 1/2 real-forward and 1/N inverse factors follow these
observations and the independent mathematical tests, not the conflicting SDK
inverse pseudocode. The complete definitions are in [the guide](../FourierTransforms.md).

The original direct scalar fixture contains 168 cases. All 16 supported lengths
and both precisions pass their committed component-error budgets. The following
values are the largest observed error divided by the case's declared budget,
across full small-vector or selected-bin large-vector comparisons. A value of 1
would reach the acceptance limit. These are empirical maxima for the input matrix,
not universal accuracy guarantees. Round-trip/Parseval tests additionally exercise
all output bins at every length.

| N | Float maximum budget fraction | Double maximum budget fraction |
| ---: | ---: | ---: |
| 2 | 0.108444 | 0.017235 |
| 4 | 0.093750 | 0.018281 |
| 8 | 0.097442 | 0.016510 |
| 16 | 0.059893 | 0.013759 |
| 32 | 0.119236 | 0.021694 |
| 64 | 0.034836 | 0.012772 |
| 128 | 0.029776 | 0.005688 |
| 256 | 0.058046 | 0.010771 |
| 512 | 0.071693 | 0.008511 |
| 1024 | 0.045723 | 0.007675 |
| 2048 | 0.052375 | 0.004944 |
| 4096 | 0.054946 | 0.005622 |
| 8192 | 0.038713 | 0.004818 |
| 16384 | 0.046212 | 0.006845 |
| 32768 | 0.032203 | 0.005861 |
| 65536 | 0.049300 | 0.004780 |

Fixture SHA-256: `7822b5acc89b0c0c77318d95fe3ff345b2cb621dc73bd1b1c36d1d0b4fba71c5`.
Generator SHA-256: `79f39882c7f55ebc20ea956472a284eed094ad864377fddf945ce4031a6e6b17`.

The matrix tests precision-rounded input hashes, positive/negative complex tones,
real endpoints and Hermitian symmetry, off-bin tones, seeded noise, tiny signals,
arbitrary inverse spectra, padding and exact/overlapping in-place complex buffers.
Separate tests cover frequency axes, strict configuration decoding, failure
atomicity, window gains, one-sided power integrals, no hidden floor, and eight
concurrent independent workspaces. The diagnostic test checks frame metadata and
balanced kernel-only intervals.

Local debug, optimized release, Address Sanitizer, and Thread Sanitizer runs each
passed 68 xUnit cases with zero failures/errors. The full debug wrapper also passed
78 Python tests, formatting, provenance for 83 fixtures, independent-consumer
link/dependency checks, and network-denied consumer execution.

## Host timing

The dedicated matrix passed **268 timing rows / 536 metric distributions**,
with thirty measured samples each after three warmups. No allocator interposer
was linked. These are p99 wall-clock **outer batch** observations, in microseconds.
Setup rows create/destroy one plan; prepared rows contain ten operations. Divide
by ten only to obtain a batch-average cost, not a measured per-call p99.

| N | Precision | Setup (1) | Real forward (10) | Spectrum (10) | Inverse-cepstrum workload (10) |
| ---: | --- | ---: | ---: | ---: | ---: |
| 256 | float32 | 57.542 | 171.625 | 301.917 | 372.125 |
| 256 | float64 | 58.208 | 129.041 | 372.458 | 301.834 |
| 1024 | float32 | 92.792 | 558.250 | 1317.334 | 1279.750 |
| 1024 | float64 | 57.875 | 615.333 | 1256.125 | 1242.000 |
| 8192 | float32 | 854.375 | 3953.125 | 9574.208 | 8846.750 |
| 8192 | float64 | 296.292 | 3995.875 | 9548.542 | 9086.542 |
| 65536 | float32 | 6268.500 | 30190.458 | 73021.000 | 68666.167 |
| 65536 | float64 | 1490.041 | 32055.750 | 75398.708 | 72455.208 |

Spectrum includes the real forward and one-sided energy-normalized power conversion.
The inverse-cepstrum workload includes a caller-selected log-power floor of 1e-30,
then the real inverse. It is a primitive workload, not a CPPS implementation.

| N | Precision | Sequential four-worker spectrum (40 operations), µs | Concurrent four-worker spectrum (40 operations), µs |
| ---: | --- | ---: | ---: |
| 256 | float32 | 1280.833 | 467.083 |
| 256 | float64 | 1226.042 | 418.875 |
| 1024 | float32 | 5048.000 | 1486.584 |
| 1024 | float64 | 4868.625 | 1329.542 |
| 8192 | float32 | 37071.208 | 10034.375 |
| 8192 | float64 | 37265.083 | 9791.958 |
| 65536 | float32 | 291696.875 | 75973.792 |
| 65536 | float64 | 302702.750 | 77999.000 |

Both four-worker rows include actor/task scheduling and forty operations. Every
actor owns its own prepared plan and conversion workspace. They are timing-only
measurements. They do not establish a transform allocation claim or predict
scaling on other hardware.

Bounded N=128 direct complex DFT comparison (ten transforms, binary64 scalar
accumulation):

| Input precision | vDSP complex forward, µs | Scalar direct DFT, µs |
| --- | ---: | ---: |
| float32 | 91.667 | 10543.334 |
| float64 | 96.375 | 10865.250 |

## Allocations and reproducibility

The separate allocation run passed **181 rows / 1,267 distributions**, all with
thirty samples. All six prepared native operations (real/complex forward/inverse,
spectrum, cepstrum), across 22 size/precision configurations, had maximum zero
malloc count, malloc bytes, and object allocation count: **396 zero-heap
histograms**, not merely zero medians. Setup and scalar comparison rows are
recorded separately; task scheduling is excluded from allocation mode.

The positive control's maxima were two mallocs, 4,120 allocated bytes, one object,
two retains, three releases, and two frees. Binary linkage inspection verified
the allocation backend was enabled only in that mode. Package.resolved was
unchanged. ARC counts for every row remain in the raw capture; zero heap does
not imply zero reference-counting work. Instrumented timings are not substituted
for the uninstrumented timing run.

Run `python3 Tools/Fourier/benchmark.py timing` and `allocation` to reproduce.
The wrapper validates all histogram sample counts, workload/metric identities,
unit/scaling conventions, finite p99 exports, allocation controls, toolchain,
and dependency pins. Raw histograms, p99 exports, configurations, environment,
commands, and binary checks are retained under `Benchmarks/.build/artifacts/`.

Local raw capture SHA-256 identities:

- Timing: `45c6a3e32db36a1ac3f04f4817c201112266a9a8503a2ec2cfd274a6163b597d`
- Allocation: `6ef4d5eca174881a8876e7f65e2f480463e530a544959f84f671b86d78fd3a87`

Owner convention review is tracked in #93; physical measurements remain #74.
