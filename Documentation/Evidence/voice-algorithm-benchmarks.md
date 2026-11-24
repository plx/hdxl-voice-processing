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
