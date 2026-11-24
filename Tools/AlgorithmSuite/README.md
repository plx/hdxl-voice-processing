# Voice algorithm suite

Run from the repository root. Each command validates all public output lanes on the selected fixture before collecting performance data. The pinned build uses Xcode 27.0 and the SwiftPM resolution in `Benchmarks/Package.resolved`. Pass `--development-toolchain` after the fixture to report a different local compiler and SDK. Timing and allocation comparisons require a clean source checkout in both modes. The comparison verifies the SHA-256 of both workload manifests, their component files and the locked dependency resolution. Each invocation writes a fresh artifact directory and prints its path. [Benchmark protocol](../../Documentation/BenchmarkProtocol.md)

```sh
python3 Tools/AlgorithmSuite/benchmark.py timing filtered-harmonics
python3 Tools/AlgorithmSuite/benchmark.py allocation filtered-harmonics
python3 Tools/AlgorithmSuite/compare.py TIMING_DIRECTORY ALLOCATION_DIRECTORY comparison.json
```

The catalog lists each public family's specialized performance and reference workloads. The combined fixture matrix runs at native sample rates of 16, 44.1 and 48 kHz with Float32 or Float64 PCM. Preparation checks the encoded source hashes and writes typed little-endian PCM with its own hash. It preserves all selections as integer source regions. The 60-second corpus case starts a new epoch at each two-second join. The 30-second continuous case extends the exactly periodic, 256-sample harmonic source and retains state throughout. The other cases cover natural vowel and connected speech, silence, noise, low and high F0, resonances, inharmonic components and missing intervals. [Case inventory](../../Documentation/Evidence/voice-algorithm-catalog.json) · [Governed input preparation](prepare.py)

| Composition | Work inside the timer |
| --- | --- |
| CPPS only | Prepare and process preview CPP/CPPS, query the 3 s rolling statistic and consume the public results. |
| Core | Add waveform and K-weighted levels, raw YIN and tracked pitch on the same selected PCM timeline. |
| Full | Add SWIPE-prime frequency and strength, causal AC HNR, LTSF, spectrogram, LTAS, six frame and LTAS descriptors, pulse-based jitter and shimmer, all five configured Burg formant frequencies and bandwidths, and raw/corrected H1–H2. |
| Full with separate spectra | Supply independently computed spectra to shape and LTAS. Untimed verification fingerprints every ordered bin and frame status from both workers and the final LTAS, including frequencies above the descriptor analysis band. The receipt counts emitted spectral rows for both workers, including partial rows. |
| Independent full pair | Run two private sets of worker state on the same immutable PCM. The completion interval includes dispatch, both analyses and their join. The collector checks both results and verifies that the two worker execution intervals overlap. |

The full profile reuses each complete 50 ms YIN window for formants and harmonics and reuses the sequence of voiced F0 estimates for pulse extraction. Burg conditions each 50 ms source interval separately. Each pulse pipeline consumes the same regular contour and performs its own matching pass. Connected speech, aperiodic input and boundary workloads select the exploratory one-second perturbation query. Result availability and denominators stay visible. The benchmark reports the actual method and precision in each recipe. [Scheduling and pulse reuse decision](https://github.com/plx/hdxl-voice-processing/issues/247)

Each measured whole-utterance trial constructs fresh workers, consumes every region, finishes the workers and accumulates value/status/source fingerprints per metric. Source preparation, I/O and numerical cross-checks occur outside the timer. The checker compares a full-buffer native run with 173-sample delivery. It compares all lanes shared by reduced and full profiles, independently integrates unweighted energy and RMS from PCM, checks the worst complete-frame pitch error and voiced fraction against the harmonic source and checks the fit and pulse search bounds. Each lane retains its scalar sum, public status and reason counts, and a fingerprint incorporating the source position, value and status of every observation. Jitter and shimmer also retain public coverage for each measured region, including the accepted period, amplitude, pair and neighborhood counts. The complete profile also reports the number of pitch-dependent regions skipped, actual tracking attempts and observed Burg root sweeps. The normative algorithm-specific reference suites continue to use the acceptance tolerances documented for each family.

The filtered-harmonics shard also measures six CPPS boundaries. Cold setup constructs and retains the preview worker. First output processes a prefix through the first actual emission from its prepared state. Warm PCM and power-cepstrogram trials process one 10 ms hop after filling the worker outside the timer. The precomputed-power trial supplies one genuine power-cepstrum row to the public smoother and fitter. The aggregation trial appends one real CPPS observation and queries the warmed rolling statistic. Replay checks numerical equality against complete native outputs and the rolling mean against its contributing values. [Stage definitions](../../Benchmarks/Sources/VoiceSuiteWorkload/CPPSPhaseTrial.swift)

The clean binary reports wall and CPU times. The separate instrumented binary reports mallocs, bytes, frees, object allocations, retains and releases, with a positive control in every shard. Each distribution retains its actual sample count. The two long fixtures request three measured observations per case and the other fixtures request ten. With these counts, the upper quantiles describe extremes of a short series. Wall time measures the stated operation or complete utterance. The comparison file reports differences between observed medians for the two profiles and identifies the worker count.

## External replay and trace

The external SwiftPM package depends only on the public core product. It reconstructs the pitch and cepstral profiles and emits individual public scalar values and source coordinates. The verifier compares its Float64 outputs on two synthetic fixtures using a single-sample partition, 251 samples and the entire fixture.

```sh
swift build --package-path Tools/AlgorithmSuite/Consumer --scratch-path .build/voice-suite-consumer -c release --product ReplayVoiceSuite
python3 Tools/AlgorithmSuite/replay.py .build/timing/release/VoiceSuiteWorkloadCheck .build/voice-suite-consumer/release/ReplayVoiceSuite replay.json
python3 Tools/AlgorithmSuite/trace.py .build/timing/release/VoiceSuiteWorkloadCheck signposts.json
```

Tracing uses the Instruments Logging template and actual native worker signposts on synthetic data. Each process is replayed without instrumentation. The report includes paired span counts, duration statistics, numerical outputs, binary identity and source/toolchain metadata. The collector isolates each launched process by PID. Its paired cepstrum, CPP, smoothing, fitting and aggregation counts must match the native fixture outputs. A partial recording is discarded and can be repeated up to twice, with the discarded attempts recorded. Each disabled-stage control must appear in the full trace and have zero occurrences in the CPPS-only trace. The collector discards private system recordings after export. Controlled-device measurements and budget revisions remain tracked in the physical evidence epic. [Physical qualification](https://github.com/plx/hdxl-voice-processing/issues/74)
