# DSP kernel measurement evidence

## Paired release measurements

On a Mac13,1 running macOS 27.0.1 with Xcode 27.2 (27B52), the suite measured 1,028 workloads in a development tree based on `8e530517627e55dfc5fe72f1d26bc46cc4cce1f2`. Each row below shows wall time for a complete batch in the clean timing run and the maximum malloc count for the same batch width in the diagnostic run. The host reported AC power and nominal thermal state at both preflight samples. [Reproduction instructions and operation boundaries](../../Tools/Kernels/README.md)

| Workload | Operations per batch | Batch p50 (ns) | Batch p95 (ns) | Batch p99 (ns) | Maximum mallocs per batch |
| --- | ---: | ---: | ---: | ---: | ---: |
| Empty control | 128 | 583 | 625 | 625 | 0 |
| Window into separate storage | 4 | 100,479 | 103,167 | 108,415 | 0 |
| Window in place | 4 | 100,351 | 107,647 | 110,399 | 0 |
| Contiguous ring read | 128 | 8,543 | 9,087 | 9,335 | 0 |
| Wrapped ring read | 128 | 9,087 | 9,295 | 9,375 | 0 |
| Owned window copy | 128 | 14,879 | 14,959 | 15,047 | 128 |
| Prepare resampler | 1 | 250,879 | 269,823 | 300,287 | 387 |
| Run prepared resampler | 1 | 422,399 | 429,055 | 430,591 | 0 |
| Inverse cepstrum | 32 | 80,959 | 84,031 | 86,335 | 0 |
| Praat robust background fit | 1 | 144,255 | 147,071 | 153,471 | 0 |

The window and ring rows use 1,000 binary32 samples at 10 kHz with a 20-sample hop. The owned copy allocates for each operation. Both ring reads and both window multiplications used prepared storage. The resampler converts 1,024 binary32 samples from 48 kHz to 10 kHz. The inverse cepstrum and robust fit use the binary64 10 kHz analysis profile. Divide a batch time by its recorded width for the mean time per operation in that batch. The complete CSV has SHA-256 `d02a841b2a924131d726beadf7a6dbf90989dd797b70cbee7f7f6e0c69c2ad3a`.

## Synthetic Instruments attribution

Instruments Time Profiler sampled five separate release processes on the same Mac. Each exercised the 10 kHz audio configuration and checked its numerical result on every batch for three seconds. The total includes launch, preparation, verification and shutdown samples from the target process. A stack contributes once to the attributed count when it contains a recognized production function. The collection report records the workload, batch count, matched functions, environment and executable SHA-256. [Sanitized Instruments collection report](dsp-kernel-attribution.json)

| Workload | Target-process stacks | Attributed stacks | Production function observed |
| --- | ---: | ---: | --- |
| Compensated mean removal | 3,010 | 2,974 | `removeMean` |
| Log power | 3,011 | 2,980 | `writeLogPower` |
| Inverse real cepstrum | 3,014 | 2,984 | `writeSignedCepstrum` |
| Parabolic peak search | 3,013 | 2,973 | `PreparedCPP.peakFromSide` |
| Praat robust background fit | 3,009 | 2,986 | `PreparedCPP.fit` |

Controlled hardware collection, sustained thermal monitoring and any resulting budget adjustments are tracked in the follow-up epic. [Physical collection and adjustment protocol](https://github.com/plx/hdxl-voice-processing/issues/74#issuecomment-7062138635)
