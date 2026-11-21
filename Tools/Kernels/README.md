# DSP kernel benchmarks

Run the paired release matrix from the repository root. The default command checks the pinned CI toolchain. To record a development run using the selected Xcode installation, pass `--development-toolchain`. Both commands record the actual SDKs, compiler, commit, working-tree state, hardware model and sampled power and thermal conditions.

```sh
python3 Tools/Kernels/benchmark.py
python3 Tools/Kernels/profile.py --output .build/kernel-attribution
```

The benchmark writes a fresh directory under `Benchmarks/.build/artifacts/kernels/` and prints its path. Start with `kernels.csv` and `result.json`. The development evidence includes stack counts for five measured stages. [DSP kernel evidence](../../Documentation/Evidence/dsp-kernels.md)

The profiling command requires a fresh output directory. It runs separately and samples synthetic data with Instruments Time Profiler.

## What the matrix exercises

The nested SwiftPM package enables `KernelBenchmarkAccess` when its `KernelBenchmarks` trait is selected. This gives the development harness access to the production implementation of private stages. Both the normal consumer and the opt-in configuration run the numerical test suite. The root package has three library products and zero external dependencies. [Access decision](https://github.com/plx/hdxl-voice-processing/issues/174)

| Operation group | Work and geometry |
| --- | --- |
| Framing and windowing | Full ring writes and suffix reads at contiguous and wrapped positions, append one hop and read an overlapping window, Gaussian multiplication into separate or in-place storage, and an explicitly owned copy. The matrix takes the Gaussian window/hop grid from `FramingCase.matrix()`, including its 131,072-sample boundary, and adds the 5/10/20 kHz cepstral grids. The framing family also covers the other supported windows, reset, and partitioned input. |
| PCM layout and levels | The scheduler selects a channel or computes its compensated stereo mean from interleaved or planar input in 17, 64, 256 and 1,024 frame chunks. Its output is mono scratch. The level reduction and two-section K-weighting filter run on ordinary and low-level PCM in both input precisions. K-weighting works in binary64. Coefficient/state preparation has its own measurement. |
| Conditioning | Prepare the whole-interval workspace, resample 1,024 input samples from 16/44.1/48 kHz to 10 kHz, and apply pre-emphasis to fresh output. Source and target counts differ with the rational sample-rate ratio. The conditioning family additionally measures the complete interval and streaming-preview implementations across targets, durations and ingress sizes. |
| Fourier | Prepare plans, pack even and odd samples, run forward and inverse real transforms, and convert complex bins to magnitude or window-normalized power. The 320 and 1,000 sample inputs exercise padding to 512 and 1,024. Together with the regular and large Fourier families, the measured radix-2 lengths span every power of two from 2 through 4,194,304. |
| Cepstrum and CPP | Run compensated mean removal, the natural-log power stage including its Nyquist exception, and the inverse transform with sample-rate scaling. These profile stages use binary64. The CPP trials exercise discrete and parabolic peak selection and all four background estimators. Records include the actual search range, number of fit points and number of pairwise slopes where applicable. |

The broader profile and allocation evidence is available in the [framing](../Framing/README.md), [conditioning](../Conditioning/README.md), [Fourier](../Fourier/README.md), [cepstrum](../Cepstrum/README.md), [levels](../Levels/README.md) and [CPP](../CPP/README.md) workload catalogs. The capture callback has its own accepted-offer, overflow and gap-recovery workloads and heap checks. Worker ring/window timings cover a different execution boundary. [Callback transport](../Transport/README.md)

## Measurement and correctness

Each stable case name identifies its operation, precision, sample rate, source and output counts, applicable FFT and hop, and signal variant. The versioned `kernel-analytic-v1` generator uses repeating dyadic PCM, shifted impulses of known magnitude and phase, synthetic power spectra, lines with a known slope and intercept, and parabolic peaks with a known sub-bin position. Filter checks use an independent direct-form-I recurrence. The isolated resampler is compared to its public whole-interval output with pre-emphasis disabled. The Swift checker evaluates numerical results before measurement and verifies repeated batches after restoring input.

The checker performs two pilot warmups and takes the median of nine individual measurements on the clean binary. It chooses a power-of-two batch of 1–128 operations targeting 50 µs of work. Both executables use that calibration file. The driver checks the same commit, working source contents, dependency lock and toolchain identity at calibration, in each mode, and before it combines the results. The raw framework tags carry the actual batch count for every measured case. Each width also has an empty-loop control. The table reports the observed cost of the control directly.

The timer surrounds the calibrated loop, scalar checksum and result consumption. Fixture preparation, scalar reference evaluation, input restoration and checksum validation occur outside it. In-place window multiplication, pre-emphasis, ring writes, split-real packing and causal filtering use separately restored state for each operation in a batch. Ring-write inputs replace a sentinel before output checks on both sides of the split. The packing check verifies every even and odd slot, including zero padding, after the timer stops. Reusable prepared operations keep the same workspace. Allocation mode uses a distinct binary and checks positive controls for malloc, bytes, free, object allocations, retains and releases. Prepared buffer operations require zero maximum malloc count, bytes and object allocations. Setup and owned-output cases expose their observed costs. Each owned copy must allocate in every observation. The FFT, filter and resampler setup cases consume their complete prepared values through the benchmark framework’s optimization barrier.

`batchP50ns`, `batchP95ns` and `batchP99ns` describe complete outer iterations. The CSV divides p50 by the recorded operation and work-unit counts to give the mean cost within that batch. It also reports operations and work units per second when p50 is positive. Only an unbatched window operation measures individual-window latency. Each mode retains the raw histogram, maximum, observation count and a compressed archive of the original 101-point framework exports. The mode result binds the archive, raw baseline and normalized workload manifest by content hash. `fitSlopeEvaluations` records work that can grow quadratically even when the number of supplied bins grows linearly. Timing differences from short host runs require controlled repetition before a budget change. [Measurement contract](../../Documentation/BenchmarkProtocol.md)

The profiling command runs one synthetic stage per process, validates its checksums, resolves stack references in the exported trace and counts target-process samples containing a recognized production symbol. It exports stage counts, symbols and binary identity. Controlled-hardware acquisition and budget adjustments are tracked in the physical-evidence follow-up. [Collection protocol](https://github.com/plx/hdxl-voice-processing/issues/74#issuecomment-7062138635)
