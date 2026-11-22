# Harmonic references and performance measurements

Run `python3 Tools/Reference/setup.py`, then `python3 Tools/Harmonics/reference.py --executable .build/reference-tool/7.0.02/Praat.app/Contents/MacOS/Praat`. The command checks the executable digest, regenerates the eight synthetic mixtures and compares the observations with the tracked fixture. Add `--write` to intentionally regenerate the fixture and its provenance entry.

The generator drives two independently specified causal second-order sections to steady state with a DC term and two phased sinusoids. It writes the resulting samples as mono PCM16. Each cut contains an integer number of periods. Pinned Praat transforms the cut without zero-padding. The amplitude of an interior positive-frequency bin is twice the complex magnitude divided by the duration. An explicit direct DFT provides a second normalization check. The complex filter polynomial supplies the individual reference gains. The native Hann-weighted regression and the rectangular Fourier observation can differ slightly after quantization. The Swift tests report disagreement above four millionths of full scale. [Praat spectrum normalization](https://praat.org/manual/Sound__To_Spectrum___.html)

Run `python3 Tools/Harmonics/benchmark.py timing` and `python3 Tools/Harmonics/benchmark.py allocation` separately on the pinned host. Use `--development-toolchain` to label a local run with its actual toolchain. The harness covers 16, 44.1 and 48 kHz, three- and five-period fits, and ordinary and near-resonance cases. Each uses a 50 ms Float64 frame, a 137.3 Hz excitation off its 20 Hz Fourier grid, actual YIN observations, and order-10 Burg with a 5 kHz ceiling. The workload receipt includes the observed frequency, exact fit length, measured poles, bandwidths and both gains for each profile.

| Operation | One measured invocation |
|---|---|
| RawFit | Fit and export raw H1, H2 and their difference with a supplied F0. |
| SuppliedCorrection | Correct the precomputed raw fit with the supplied pitch-qualified Burg frame. |
| YINAndBurg | Estimate YIN pitch from PCM and fit the Burg frame conditioned on that observation. |
| Complete | Execute all dependency, fit and correction work from PCM through the corrected result. |

The harness prepares workers and signals before measuring, clears outputs before each invocation and verifies the full output after the clock stops. Timing and allocation runs retain separate distributions with at least 101 observations per operation. The allocation run also includes a positive malloc/ARC control. Throughput is complete invocations per second. Device, thermal and end-to-end capture behavior are tracked in #74.

Each mode emits `comparisons.json` with the complete and dependency-only medians for each profile. Their signed difference estimates incremental per-frame latency and CPU time or allocated blocks and bytes across independently sampled trials.
