# Assigned independent numerical routes

No algorithm leaf may close by generating expected outputs with its own Swift
implementation. These routes are assigned now; each listed leaf implements its
bounded oracle/fixtures before validating its native implementation. They feed #66.
Original scalar oracles must use a different formulation or execution path from
optimized code and have closed-form anchors. Algorithm-specific profiles, source
hashes, conditioning limits and justified tolerances must accompany new goldens.

| Issues | Algorithm | Independent route / pinned source |
| --- | --- | --- |
| #22, #24 | PCM framing, windows, channels, gaps | Hand-enumerated sample-index/window vectors and closed-form sine/Hann/Hamming definitions; integer-rational source generation; analytical interval algebra |
| #30 | DFT/FFT, real packing/scaling | Initial `primitives.json` has closed-form N=8 impulse/DC/Nyquist/cosine/sine/silence. Add bounded direct complex DFT and inverse equations in developer tooling, independent of vDSP |
| #31 | Pre-emphasis, bandlimited resampling | Pinned Praat 7.0.02 external operations plus analytic impulse, DC, delay/phase/rate invariants; document any native resampler that intentionally uses a different filter |
| #32 | RMS, peak, dBFS, clipping, K-weighted energy | Closed-form energy/peak/log checks; ITU-R BS.1770-5 two-stage coefficients independently reconstructed natively, compared to pinned De Man coefficient equations and original 80-digit Decimal filtering. 240 vectors at ten rates and both input precisions, plus independent complex response/phase-difference delay. See [level tooling](../Levels/README.md). |
| #33 | Power cepstrum and cepstrogram | Pinned Praat 7.0.02 full Sound route plus decomposed public commands, 41 cases / 197 selected frames with all seven stages and every bin; eight licensed speech cases, synthetic/gain/rate/floor/grid variants and frozen conditioning-aware budgets. Independent small cosine-sum DFT anchor. See [cepstral tooling](../Cepstrum/README.md). |
| #35 | CPP peak/background fit | 216 inputs, 1,414 isolated comparisons and 40 full-PCM speech frames. External peak/LS/pinned-Robust queries, independent complete Theil–Sen median oracle, analytic full-Siegel anchors and explicit pinned-reference exceptions #107. See [CPP tooling](../CPP/README.md). |
| #37 | CPPS smoothing/fit/aggregation | Implemented pinned Praat 7.0.02 reference recipe and full raw/smoothed matrices/components. Add smoothing/aggregation adversarial fixtures as the leaf lands; historical 6.0.40 parity is a separate identity/decision #86 |
| #34 | Speech/voicing masks and coverage | Hand-labeled original synthetic intervals, exact set union/intersection and non-stitching sums; later licensed human annotations #27/#63. Preserve rejected-frame denominators |
| #38 | YIN F0 and optional tracker | Independent bounded scalar Python difference/CMND/minimum/interpolation oracle from de Cheveigné & Kawahara 2002, DOI 10.1121/1.1458024; 54 cases / 484 retained frames, closed-form periodic anchors and every intermediate cell. Separately enumerated tracker paths and explicit boundary decision #117. See [YIN tooling](../YIN/README.md). |
| #39 | AC and CC HNR | Distinct pinned Praat 7.0.02 accurate AC and forward CC recipes: 180 cases with retained PCM/raw output, exact fused timestamp grid, noise/filter/gain/precision/rate/period/floor/hop variants and licensed speech. Independent compensated direct-sum equations, 16 full intermediate anchors and executable flat-impulse disagreement proof; native peak-resolution policy separately identified (#149). See [HNR tooling](../HNR/README.md). |
| #41 | Spectrogram, cepstrogram, LTAS | Independent direct DFT, analytic spectral-line energies and weighted sums with hand-enumerated coverage; Praat 7.0.02 cepstrogram route where conventions match |
| #42 | Acoustic pulse tracking | Implemented raw-CC Pitch + Sound to PointProcess CC route in Praat 7.0.02; known original pulse times and noise/ambiguity cases, no Pitch-only phase-free shortcut |
| #44 | SWIPE-prime | Bounded independent multi-window/candidate-kernel oracle from Camacho & Harris 2008, DOI 10.1121/1.2951592 (prime-harmonic variant). Pin exact original oracle source hash and intermediate fixtures in #44; no unreviewed MATLAB/research-code copying |
| #45 | Spectral moments, flatness, slope, band ratios | Closed-form two-/three-line spectra plus independently evaluated sum/moment/log regression equations; exact energy/amplitude weighting and DC/Nyquist rules in each profile |
| #46 | Burg LPC formants/bandwidths | Implemented Praat 7.0.02 Burg recipe plus analytically known all-pole resonances; native LPC coefficients, roots and credibility fixtures added in #46 |
| #50, #51 | Jitter and shimmer families | Implemented Praat 7.0.02 numeric queries (fractions/seconds/dB explicit), plus hand-worked accepted period/amplitude sequences and exclusions |
| #52 | H1-H2 and corrected H1*-H2* | Exact harmonic mixtures and independent complex sinusoid fitting; bounded transfer-function oracle from Iseli & Alwan 2004 and Iseli/Shue/Alwan 2007, with the VoiceSauce correction definition cited in #52. Pin included formants, bandwidths and formula before generating correction goldens |
| #40, #43, #54, #58 | Scheduler/lifecycle/result records | Exact event transcripts, frame support and state-transition tables; compare native outputs to independent numerical routes above, not just native batch to native streaming |
| #47, #53, #57 | Personal calibration and feedback | Hand-worked quantile/range/persistence cases and independently computed held-out metrics; no fabricated human labels or aesthetic truth. Physical collection follows #74 |

Method sources: [ITU-R BS.1770-5](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en),
[YIN](https://doi.org/10.1121/1.1458024),
[SWIPE](https://doi.org/10.1121/1.2951592),
[Iseli correction derivation](https://www.seas.ucla.edu/spapl/paper/iseli04.pdf),
[VoiceSauce correction definitions](https://www.phonetics.ucla.edu/voicesauce/documentation/parameters.html).
Paper editions/DOIs identify mathematical sources, not a license to copy their code
or text. Developer equations/oracle source hashes are committed when those leaves
land. The exact current Praat source, binary and artifact hashes are in `toolchain.json`.

Performance registration for #25: `smoke` (120 ms CPPS frame components),
`intermediates` (120 ms CPPS, two 513×11 matrices), and `catalog-*` (500 ms original
saw across every implemented route plus silent HNR). Add the licensed corpus from
#27 without silently redefining these IDs; retain input/profile/reference hashes.
