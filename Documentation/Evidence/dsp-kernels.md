# DSP kernel measurement evidence

## Paired release measurements

On a Mac13,1 running macOS 27.0.1 with Xcode 27.2 (27B52), the suite measured 1,028 workloads in a clean checkout at `0e7801a044abfc4aeae7378aded4b9fa1ca73b97`. Each row below shows wall time for a complete batch in the clean timing run and the maximum malloc count for the same batch width in the diagnostic run. The host reported AC power and nominal thermal state at both preflight samples. [Reproduction instructions and operation boundaries](../../Tools/Kernels/README.md)

| Workload | Operations per batch | Batch p50 (ns) | Batch p95 (ns) | Batch p99 (ns) | Maximum mallocs per batch |
| --- | ---: | ---: | ---: | ---: | ---: |
| Empty control | 128 | 583 | 625 | 750 | 0 |
| Window into separate storage | 2 | 51,775 | 54,047 | 54,879 | 0 |
| Window in place | 2 | 50,303 | 50,655 | 53,084 | 0 |
| Contiguous ring read | 128 | 17,551 | 18,255 | 20,223 | 0 |
| Wrapped ring read | 128 | 18,047 | 18,751 | 20,847 | 0 |
| Owned window copy | 128 | 14,751 | 14,919 | 14,959 | 128 |
| Prepare resampler | 1 | 251,775 | 266,495 | 339,199 | 387 |
| Run prepared resampler | 1 | 422,143 | 434,687 | 445,439 | 0 |
| Inverse cepstrum | 32 | 78,463 | 81,791 | 89,919 | 0 |
| Praat robust background fit | 1 | 147,583 | 149,503 | 151,167 | 0 |

The window and ring rows use 1,000 binary32 samples at 10 kHz with a 20-sample hop. The owned copy allocates for each operation. Both ring reads and both window multiplications used prepared storage. The resampler converts 1,024 binary32 samples from 48 kHz to 10 kHz. The inverse cepstrum and robust fit use the binary64 10 kHz analysis profile. Divide a batch time by its recorded width for the mean time per operation in that batch. The CSV includes all 1,028 workloads, their unit denominators and their timing and allocation measures. The checked-in CSV uses LF line endings and has SHA-256 `071b97016c94f8fd0ddea5503995669b61ce7fb891dd164dc41ebe2bc764e3e7`. [Complete development measurements](dsp-kernel-development.csv)

The two runs collected 100 observations per workload. All 886 prepared DSP and buffer workloads and eight empty controls had zero maximum malloc count, malloc bytes and object allocations. Each of the 102 owned-copy cases allocated at least once per copy in every observation. The separate positive control observed two mallocs, 4,112 bytes, two frees, one object allocation, two retains and three releases at maximum. The 32 construction cases report their own costs.

## Synthetic Instruments attribution

Instruments Time Profiler sampled five separate release processes on the same Mac. Each exercised the 10 kHz audio configuration and checked its numerical result on every batch for three seconds. The total includes launch, preparation, verification and shutdown samples from the target process. A stack contributes once to the attributed count when it contains a recognized production function. The collection report records the workload, batch count, matched functions, environment and executable SHA-256. [Sanitized Instruments collection report](dsp-kernel-attribution.json)

| Workload | Target-process stacks | Attributed stacks | Production function observed |
| --- | ---: | ---: | --- |
| Compensated mean removal | 3,012 | 2,985 | `removeMean` |
| Log power | 3,010 | 2,978 | `writeLogPower` |
| Inverse real cepstrum | 3,009 | 2,984 | `writeSignedCepstrum` |
| Parabolic peak search | 3,010 | 2,966 | `PreparedCPP.peakFromSide` |
| Praat robust background fit | 3,010 | 2,988 | `PreparedCPP.fit` |

Controlled hardware collection, sustained thermal monitoring and any resulting budget adjustments are tracked in the follow-up epic. [Physical collection and adjustment protocol](https://github.com/plx/hdxl-voice-processing/issues/74#issuecomment-7062138635)
