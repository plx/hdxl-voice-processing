# PCM delivery and precision equivalence

For a fixed acquisition and profile, splitting an input region into different callbacks must reproduce every measurement on its original sample clock. The executable compares the whole region, 7-sample callbacks, prime-sized 173-sample callbacks and a repeating sequence of 97 chunk sizes from 1 through 509 (seed 61). Each run finishes the final partial window. A declared gap ends the current region. Each new region receives a distinct continuity epoch.

## What each profile compares

| Profile or stage | Required agreement and declared differences |
| --- | --- |
| PCM, conditioning, framing and transforms | Verify source hash, encoding, channel, sample rate, filter delay, window position and dependency extent. The reference suite checks the causal filter and finite-interval conditioning against their own definitions. The FFT suite also compares native Float and Double transforms with independent scalar references. |
| Levels, energy and masks | Compare peak, RMS, mean square, digital level, crest, clipping and K-weighted energy on the original grid. Preserve filter warm-up, silence, unavailable tails and missing support. Selected-region scheduling starts fresh workers on disjoint regions. LTSF decisions retain their original source coordinates. |
| Cepstrum, CPP, CPPS and rolling CPPS | Compare the raw and smoothed measurements, their individual windows, smoothing support, lookahead and edge policy. Whole-interval centered analysis and streaming preview have distinct profile identities and grids. Voice-only and all-eligible aggregates have different denominators. An empty selection or a stale rolling window retains its reason. [CPPS method](../CPPS.md) · [Symmetric smoothing definition](https://praat.org/manual/PowerCepstrogram__Get_CPPS___.html) · [Voice-only aggregation study](https://www.isca-archive.org/interspeech_2023/murton23_interspeech.html) |
| YIN, tracked YIN and SWIPE-prime | Compare raw and tracked frequencies, public status and selected candidate at each frame. The worker inspects the actual borrowed YIN candidate count. SWIPE-prime has its own estimator, pitch strength and selected candidate. Their individual reference tests cover ties and unsupported geometry. |
| HNR | AC and forward-CC, whole-interval and causal-window profiles each preserve their own frame outcomes under repartitioning. A 250 Hz quiet prefix followed by a louder segment has no selected HNR observation in the quiet prefix under the whole-interval amplitude threshold. The causal profile selects an observation before the loud segment arrives. The measured window and its normalization dependency are recorded separately. [HNR guide](../HNR.md) · [Praat threshold definition](https://www.fon.hum.uva.nl/praat/manual/Sound__To_Harmonicity__ac____.html) |
| Pulses, jitter and shimmer | Compare the eligible landmarks, time within acquisition, interval/run membership, accepted periods, amplitudes, pairs and neighborhoods. Sustained and exploratory measures use the applicability profile in the recipe. The gap cases remove one sample at a pitch-period boundary or 1,024 samples, which exceeds the fixture's pitch window. |
| Spectrogram, LTAS and spectral shape | Compare every power bin, its source row and validity, then the frame and aggregate centroid, spread, flatness, roll-off, slope and band ratio. The independent-transform control must reproduce the entire full-profile result while executing twice the number of spectral rows. |
| Burg formants and H1–H2 | Compare each ranked frequency and bandwidth, raw harmonic difference and formant-corrected difference. A missing pitch or failed correction retains its dependency outcome. A short region cannot provide its missing cycles, formants or harmonics from an earlier epoch. |

The full composition runs against every eligible PCM entry in the governed speech and synthetic catalogs. Three controls also exercise the CPPS-only, core and independent-transform compositions. Each shared lane, support sequence and candidate count must match when other stages are enabled. Debug correctness evidence links named, executed Swift tests to each family, including finite-interval references, region weighting, stale histories and unsupported parameters. The single-sample fixture, 120 ms excerpt, dropout, pulse-boundary gap and 60-second repeated excerpt retain their individual identities. Decoder rejections, empty PCM and missing acquisition remain separate entries in the input manifest. [Input construction](../../Tools/Equivalence/inputs.py) · [Native regression index](../../Tools/Equivalence/regressions.py)

## Precision

The Float32/Float64 arithmetic comparison uses identical sample values. The controller independently widens each little-endian Float32 sample and verifies the resulting Float64 PCM digest. A second comparison runs the original Float64 source if encoding it as Float32 changes any sample. It reports the observed difference by metric and validity, including shifted selections and unmatched observations. A development run on the synthetic off-bin tone changed one raw CPP result by 7.33 dB after input rounding. Running Float64 on the exact rounded samples reproduced the Float32 CPP result. [Precision decision and evidence](https://github.com/plx/hdxl-voice-processing/issues/289)

| Comparison on identical PCM | Acceptance rule |
| --- | --- |
| Partitions within one target and precision, or matching precision on the two qualified targets | Exact public observations, source coordinates, coverage, statuses/reasons, candidate inspection counts and selections, units, profile and aggregate outputs. |
| Float32 versus widened Float64 | Exact discrete and timing evidence. Scalar measurements computed in Double use zero absolute tolerance. |
| Native spectral power | Every bin is checked within its own row. Absolute budget is `16 × 2⁻²³ × ceil(log₂(FFT length)) × row peak + FFT length × 2⁻¹⁴⁹`. The terms cover accumulated Float butterfly roundoff and underflow. The scalar first-bin export additionally has an absolute ceiling of 1e−8 in normalized power. |
| Spectral shape | Centroid and spread allow 1e−6 of Nyquist in hertz. Flatness allows 1e−5, slope 0.001 dB/octave and the band ratio 0.05 dB. These bounds cover propagation of native spectral roundoff through normalized moments, log fits and ratios of low-power bands. The roll-off frequency and all status transitions must match exactly. |

Each per-case artifact contains both recipes, input hashes, partition sizes, measurement counts, maxima and the corresponding source sample for each nonzero maximum. Spectral summaries record rows, bin count and maximum bin error. Replay of a named case can export its individual observations and every bin. Source files and PCM stay out of the uploaded artifacts. [Comparison implementation](../../Tools/Equivalence/compare.py)

## Reproduce the evidence

Use Xcode and Python from `Configuration/build.json` and an available iOS 27.0 simulator runtime. Each command takes a fresh output directory. Add `--install-runtime` to request a missing runtime. For a development host, use `--host-only --development-toolchain` to record the actual environment.

```sh
python3 Tools/Equivalence/run.py .build/equivalence-results --group edges
python3 Tools/Equivalence/inputs.py .build/equivalence-inputs
swift run --package-path Benchmarks/Portable -c release AlgorithmConformance \
  .build/equivalence-inputs short-120ms.float64 full .build/short-120ms.json
```

The four CI shards execute the native worker on arm64 macOS and inside an arm64 iOS 27 Simulator. Each archive includes the commit, SDK/compiler, host hardware, simulator device type/runtime build, binary hashes, input manifest and per-case results. The Watch lane qualifies the supported foreground recorded-segment digital-level operation with 16,000 known source frames and ten disjoint 100 ms windows. Physical device comparisons and adjustments are assigned separately. [Matrix workflow](../../.github/workflows/algorithm-equivalence.yml) · [Watch procedure](../WatchFeasibility.md) · [Physical evidence handoff](https://github.com/plx/hdxl-voice-processing/issues/74#issuecomment-7178587240)

## Memory, timing and instrumentation

A separate continuous PCM worker consumes 60 seconds at 16 kHz in 256-sample callbacks. It retains a fixed source block and counters. Every callback checks prepared storage. Six live allocator snapshots, one per ten source seconds, must span at most 256 KiB. This threshold detects retained growth during this trial. The worker then rejects NaN, infinity, an unannounced gap and an unannounced route without advancing. After each declared gap, its silence results and finish record must equal those of a newly prepared worker. A new 44.1 kHz route starts on a new epoch and profile.

The scheduler benchmark measures 7-, 173- and 16,000-sample delivery on the same one-second input and profile. The light and full scheduler bundles publish their own recipes and prepared bytes. Setup and steady processing have separate distributions. `partition-overhead.json` records sample counts, p50/p95/p99 and maxima, throughput and median wall time relative to whole-buffer delivery. Clean wall/CPU timing and allocation/ARC runs have separate binaries and artifacts. The suite trace runs the same production stages with Instruments and compares traced outputs against an uninstrumented replay. Scoped signposts include cepstrum, CPP, smoothing, fitting, rolling aggregation and enabled downstream stages. They contain no PCM. [Scheduler workload](../../Tools/Scheduling/benchmark.py) · [Instrumented profiles](../../Tools/AlgorithmSuite/README.md#external-replay-and-trace)
