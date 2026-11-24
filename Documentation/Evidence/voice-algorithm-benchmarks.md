# Voice algorithm benchmarks

## First CPPS checkpoint

On the arm64 macOS 27.0.1 hosted runner with Xcode 27.0, the 87 six-second CPPS cases passed in both timing and allocation modes. The benchmark used the source tree merged in `154fa073cbcff8a7cc11c83d500801e4ad01a95c`. The 13 shards produced 174 timing distributions and 187 allocation distributions, including an allocation and ARC control in each shard. Each mode used the same prepared PCM and case definitions. Each case checked replay at both 256- and 63-sample chunk sizes. [CPPS run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068566) · [Protocol and numerical references](../../Tools/CPPS/README.md)

| Float64 input at 16 kHz | Hop / time smoothing / quefrency smoothing | Prepare p99 | Six-second run p99 | Available / unavailable frames | Maximum mallocs per prepared run |
| --- | --- | ---: | ---: | ---: | ---: |
| Streaming preview | 10 / 20 / 1 ms | 1.079 ms | 2.869 s | 591 / 1 | 0 |
| Whole interval | 2 / 10 / 1 ms | 5.770 ms | 15.872 s | 2,951 / 0 | 0 |
| Preview with owned stage exports | 10 / 10 / 1 ms | 0.970 ms | 3.249 s | 591 / 1 | 13,008 |

Each row used the 3 s all-eligible rolling statistic, the robust Praat 7.0.02 fit, parabolic interpolation, disabled pretrend and smoothing normalized by available support at the edges. The owned-export case copied 2,122,281 scalars. The final partial preview window remained visible as unavailable. Setup and processing times come from the clean timing executable. Allocation counts come from a separate instrumented executable. Each run has ten measured observations, so its p99 is near the observed maximum. It describes processing the whole six seconds. Frame deadlines require individual frame timings. [Preview artifact](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068566/artifacts/14875971794) · [Interval and export artifact](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068566/artifacts/14874746392)

The input SHA-256 for all three rows is `0436923454bc86af92326075a12d4553b117e11d3ec780d38eecec5f28f55e68`. The profile and rolling statistic identities identify the exact recipes.

| Case | Measurement profile SHA-256 | Statistic profile SHA-256 |
| --- | --- | --- |
| Streaming preview | `1c6a80569235863abdcdbf745de928df61a39d877347015f91ca480d5dbe1165` | `e6e72c73d5ea065af5e2637ea0af2f0cf586689f30f66a7c61b6f916da56932e` |
| Whole interval | `e8a9a59d19891e194cb5de957d19810fabf11eea0d23453c96b178dafca2b742` | `f2dad3e277b2379a1228e8942ed9ceaf84ece0b50e7c17e21bf17770c21e6298` |
| Owned stage exports | `bf0d38c51b5c66787fdcedc5daeb91fa3ee12480dde89816d80ddce0a0515546` | `44ce8543ec62e71fae27ee013346d9865b6bdedba7a77d0779b7293fcbe0fc65` |

The same tree also passed all 77 unsmoothed CPP cases and 38 cepstrum cases. The former include four background fit methods, peak searches and PCM-to-CPP processing. The latter include individual windows, power-cepstrogram construction, streaming and matrix export. Their results provide separate measurements for upstream work. [CPP run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068572) · [Cepstrum run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068823)

## Public algorithm catalog

The 16 family runs below contain 3,798 distinct measured operations across 2,026 named cases. Each operation appears in both a clean timing distribution and a separate allocation/ARC distribution. The count includes 1,028 individual DSP kernel cases. The catalog preserves the exact combinations that ran. For each group, join an operation prefix and case name with a period to get the framework's measurement ID. Each artifact and per-mode workload manifest has a SHA-256 digest. [Machine-readable catalog](voice-algorithm-catalog.json)

| Family | Named cases | Measured operations | Boundaries and variants |
| --- | ---: | ---: | --- |
| Cepstrum | 38 | 76 | Window transform, power-cepstrogram, preview, interval, bounded owned export. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068823) |
| CPP | 77 | 154 | Peak interpolation, search bounds, background fitting and complete processing. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068572) |
| CPPS | 87 | 174 | Smoothing along time and quefrency, edge support, optional pretrend, preview and whole-interval processing, rolling query and owned diagnostics. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068566) |
| Segmentation | 26 | 52 | LTSF speech activity, energy eligibility, region routing, mask resolution, reset and export. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231069103) |
| Levels | 100 | 200 | Peak, RMS, energy, intensity and K-weighted levels, accumulation choices and exceptional inputs. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068858) |
| YIN | 82 | 164 | Raw and tracked F0, direct and Fourier differences, dynamic range, failure paths and candidate export. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068830) |
| SWIPE-prime | 44 | 176 | Multi-resolution pitch and strength, candidate geometry, comparison with baseline YIN. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068805) |
| HNR | 210 | 420 | Autocorrelation and forward cross-correlation, causal and complete-interval normalization, low floor, silence and diagnostics. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068416) |
| Pulses | 88 | 176 | Contour handling, waveform matching, landmark interpolation, period/amplitude sequences, failures and ownership. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068676) |
| Jitter | 68 | 240 | Local, absolute, RAP, PPQ5 and DDP. Supplied periods, rolling and PCM paths. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068904) |
| Shimmer | 68 | 240 | Local, dB, APQ3, APQ5, APQ11 and DDA. Supplied amplitudes, rolling and PCM paths. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068730) |
| Spectral products | 18 | 162 | Spectrogram, LTAS, bounded retention and owned spectral or cepstral export. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068799) |
| Spectral shape | 8 | 56 | Centroid, spread, flatness, roll-off, band energy ratio and slope from frame or LTAS, shared or separate evaluation. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068864) |
| Formants | 72 | 432 | Complete Burg analysis, resampling, LPC, root solving, close roots and bounded failure. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068711) |
| H1–H2 | 12 | 48 | Raw harmonic fit, supplied formant correction, YIN and Burg dependencies, complete path, near-resonance cases. [Run](https://github.com/plx/hdxl-voice-processing/actions/runs/45231068628) |
| DSP kernels | 1,028 | 1,028 | Includes mean removal, Fourier transforms, log power, cepstral inversion, background fitting and the peak interpolators. [Kernel evidence](dsp-kernels.md) |

## Combined profiles

The full vowel trial at 44.1 kHz used 88,200 source samples. It produced 191 valid CPPS frames and one unavailable tail. The full 600 Hz trial at 48 kHz retained 46 raw H1–H2 estimates and all 47 unavailable corrected slots. On the three-region gap fixture, each region ended before a complete YIN window and the two perturbation pipelines made zero tracking attempts. On the 80 Hz Gaussian-pulse fixture the Burg solver exercised its second starting point and reached the 128-sweep limit. The machine-readable workload receipts retain these denominators for every timing comparison.

Instruments recorded the following spans in the CPPS-only worker on the 16 kHz harmonic-low fixture, at commit `1f569586d7e587dea35fb96171c46bba152ee215` using Xcode 27.2 on arm64 macOS 27.0.1. Durations include signpost overhead and some spans nest inside other spans. The schedule SHA-256 was `5a986f6604e2fa1875337387ced406b873e2d9113994640128b0f771eef4f544`, and the exported signpost table had SHA-256 `1866362b522bd85634e90b2258bfdae8a62b01dee455dd2a47e26cbc6751d9c3`.

| Native span | Completed spans | Median per span (µs) | Total (ms) |
| --- | ---: | ---: | ---: |
| Cepstrum | 17 | 16.542 | 0.283 |
| CPP | 16 | 2,726.416 | 44.079 |
| CPPS smoothing | 16 | 16.709 | 0.275 |
| CPPS fitting | 16 | 1,478.417 | 23.767 |
| Rolling CPPS aggregation | 17 | 1.083 | 0.028 |

Both profiles entered smoothing and fitting 16 times and aggregation 17 times. In the full profile, Instruments also recorded 25 spectrogram intervals, 26 shape intervals, 22 YIN intervals, two SWIPE-prime intervals, 28 pulse-matching intervals, 21 harmonic corrections, one jitter interval and one shimmer interval. The CPPS-only recording contained zero intervals for all 16 disabled-stage controls. Running each process with diagnostics disabled reproduced its traced public result fingerprints. The timing executable measures clean end-to-end latency separately. [Trace collector and positive controls](../../Tools/AlgorithmSuite/trace.py)

On the half-second filtered-harmonics fixture, a prepared CPPS worker emitted its first valid result after 1,785 source samples (111.56 ms of 16 kHz input). The independent consumer observed the same boundary with single-sample delivery. With 251-sample delivery, the callback arrived after the eighth batch, at 2,008 samples. A subsequent 160-sample hop and the corresponding precomputed power-cepstrum row both produced 17.6032251175 dB. The upstream cepstrogram held 104,664 scalar workspace bytes and the downstream smoother held 82,032. A separate query appended the fifth available frame to its rolling history of 21,744 record bytes. All phases use the same 10 ms hop, 20 ms time smoothing, 1 ms quefrency smoothing and 3 s aggregation profile. Full profile, fixture, toolchain, timing and allocation receipts are published by the voice-suite workflow. [Reproduction protocol](../../Tools/AlgorithmSuite/README.md) · [Workflow](../../.github/workflows/voice-suite-benchmarks.yml)
