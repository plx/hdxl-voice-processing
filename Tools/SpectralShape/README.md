# Spectral shape measurements

Run these from the repository root with the configured Xcode. Pass `--development-toolchain` to record a separate development-host series.

```sh
python3 Tools/SpectralShape/benchmark.py timing
python3 Tools/SpectralShape/benchmark.py allocation
```

The eight cases cross 256- and 2048-point FFTs, upper analysis bounds of 2 and 8 kHz, and one- and eight-second rolling windows. The 16 kHz Float64 PCM fixture uses two deterministic sawtooths. Its periodic Hann windows contain 250 or 1000 samples with half-window overlap. The profile excludes DC, uses power weighting, a relative −100 dB log floor, 85% roll-off and a uniformly weighted dB/octave fit from 125 Hz to half the upper analysis bound. The native checker verifies every operation and exports the exact profiles and fingerprints, layout, fit counts, source intervals and frame counts.

| Operation | Work per measured trial |
| --- | --- |
| FFT / FFTAndShape | One identical PCM interval through framing, windowing, FFT, power and a bin probe. FFTAndShape also computes and consumes all six values per borrowed row. |
| SharedFrame / SeparateFrame | One descriptor call or six individual calls per precomputed frame of the first interval. Both paths consume all six numerical outputs. |
| SharedLTAS / SeparateLTAS | One descriptor call or six individual calls per precomputed LTAS. Each trial analyzes two successive windows separated by one hop. |
| RollingLTAS | Rebuild the two sliding means from their own precomputed member frames, snapshot and analyze. The windows include the exact contributing PCM support and use independent accumulators. |

Generation of PCM, preparation of workers and reference results, and result verification occur outside measurement. The runner records separate uninstrumented latency/CPU and instrumented heap/ARC distributions, with two warmups and 10–15 measured observations per operation. The allocation run includes a positive backend control. The shared evidence reader verifies all exported percentiles against raw histograms. The workload manifest binds operations to the corresponding cases and environment. Hardware, platform, toolchain and precision are recorded alongside the timings.

`throughput.csv` reports frames or aggregate snapshots per second at median and p99 trial latency. `comparisons.json` reports the difference of two operation medians divided by the number of spectra, in nanoseconds, malloc calls or bytes per spectrum. Each difference uses matched inputs and trial geometry. Sampling noise can give a negative difference. Raw independent distributions remain available for interpreting variability. Physical-device energy, sustained thermal behavior and callback headroom will be measured in [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
