# Raw and formant-corrected H1–H2

H1 and H2 are the fitted peak amplitudes at the supplied F0 and twice F0. A raw difference of 6.02 dB means the first harmonic has about twice the second harmonic’s amplitude. It includes the effect of the vocal tract filter. H1*–H2* estimates the difference after removing two measured resonances. This is an exploratory spectral measurement. Interpretation depends on the phonation task, the pitch observation and the quality of the formant fit.

Use `PreparedHarmonicFit` when only raw amplitudes are needed. It accepts a `HarmonicFitProfile`, a mono Float32 or Float64 buffer, its original sample interval and an independent F0 `MeasurementResult`. The profile includes the full pitch recipe, its verified digest and the selected scalar algorithm. Use `.yin(configuration)`, `.swipePrime(configuration)`, `.schedule(configuration)` or `.frameLocal(profile)` for an external frame-local estimator. A narrowband recording can supply raw amplitudes whenever the second harmonic falls inside its declared bandwidth.

```swift
import HDXLVoiceProcessing

func measureHarmonics(
    pcm: [Float], source: SourceInterval, pitch: MeasurementResult,
    expectedPitch: HarmonicPitchRecipe, formantSettings: BurgFormantProfile,
    formants: BurgFormantFrame?
) throws -> CorrectedHarmonicFrame {
    let fit = try HarmonicFitProfile(
        sourceSampleRate: formantSettings.sourceSampleRate, inputPrecision: .float32,
        declaredBandwidthHz: formantSettings.declaredBandwidthHz,
        periods: 3, pitch: expectedPitch)
    let configuration = try HarmonicCorrectionProfile(fit: fit, formants: formantSettings)
    let analyzer = try PreparedHarmonicDifference<Float>(configuration)
    return try pcm.withUnsafeBufferPointer {
        try analyzer.analyze($0, source: source, pitch: pitch, formants: formants)
    }
}
```

Prepare the worker once when processing successive frames. Feed the same qualified F0, profile and original window to `PreparedBurgFormants.analyze` through its pitch callback. The corrected worker can also apply `correct(_:formants:)` to a saved in-memory raw fit produced with its raw profile. A missing formant frame yields an explicit correction failure and preserves the raw result. [Burg formant profiles](BurgFormants.md)

## Raw amplitude profile

The supported source rate is 8–192 kHz. Each call covers at most 250 ms. F0 must lie in 50–5,000 Hz, and 2F0 must be strictly below the declared bandwidth and Nyquist. A qualified pitch observation covers the supplied PCM frame exactly, with complete coverage and no warnings. For a schedule that publishes both YIN and SWIPE′, specify the raw estimator’s algorithm identifier. YIN tracking attaches historical support to its scalar. Supply the raw frame’s pitch when using a tracker. The fitter rejects the tracked algorithm even when the PCM buffer exactly matches its history.

For three periods by default, or five when configured, set `N = round(periods × Fs / F0)` to the nearest sample, ties upward. Require at least 12 samples and the complete window. Center it within the pitch support, placing the extra sample on the right when the unused count is odd. Each measurement returns this exact subwindow, the full pitch dependency, source-clock projection and effective acquisition delay. The worker widens Float32 exactly and fits in binary64. Require at least Fs/N between H2 and Nyquist so both quadratures can be resolved over this window. Closer placements return `insufficientNyquistSeparation`.

The fit minimizes weighted squared error with the symmetric Hann weights over N samples. Its five columns are a constant and both quadratures of F0 and 2F0. Frequencies are fixed by the supplied observation. Joint fitting handles off-grid harmonics and a DC offset. The peak of each fitted sinusoid is the hypotenuse of its two coefficients. `peakFS` uses one unit of normalized PCM as its reference. `peakDBFS` is 20 log₁₀ of the peak amplitude relative to that reference. Both difference series use dB ratios. A measured zero-dB difference means the two amplitudes are equal.

The v1 detectability rule scales the fit by the largest absolute sample. Let E be the weighted residual RMS and M the effective sample count, (Σw)²/Σw². Estimate the nonrepeating RMS P by comparing samples one F0 period apart with linear interpolation. For interpolation fraction a, divide the mean squared difference by 1 + (1−a)² + a² before taking its square root. Require each scaled amplitude to exceed the largest of 10⁻⁷, 0.02 E and 3 min(E,P) √(2/M). The residual term limits leakage from unmodeled periodic content. The period comparison keeps strong higher harmonics from being counted entirely as noise. The frame exports E and the actual threshold. These are versioned heuristics for this estimator.

Unavailable pitch, partial coverage, lack of support, silence, a poorly conditioned fit and an individually unresolved harmonic have separate diagnostics. A resolved H1 can be inspected even when H2 is unavailable. A peak anywhere in the supplied frame at or above unit full scale sets a clipping warning on a valid raw fit and excludes correction.

## Measured-pole correction

The correction uses the sampled, DC-normalized pole-pair transfer function from Iseli and Alwan, equation 5. The included ranks are F1 and F2 with their measured bandwidths, consistent with the VoiceSauce manual’s H1* and H2* convention. The raw estimator uses a joint regression and the package’s named fit profile. Results are unsmoothed. [Iseli and Alwan, 2004](https://www.seas.ucla.edu/spapl/paper/iseli04.pdf) · [VoiceSauce parameters](https://www.phonetics.ucla.edu/voicesauce/documentation/parameters.html) · [Iseli, Shue and Alwan, 2007](https://www.seas.ucla.edu/spapl/paper/Iseli_JASA_07.pdf)

For each measured pair (F,B), use the original PCM rate Fs, radius r = exp(−πB/Fs), and D(x) = (1−r)² + 4r sin²(πx/Fs). The signed filter gain at h is 10 log₁₀[D(F)² / (D(F+h)D(F−h))]. Subtract the two gains at F0 from H1 in peak dBFS. Apply the same operation at 2F0 to H2. The difference of these corrected levels gives H1*–H2*. Every contribution records F, B, rank and both gains.

Correction requires the configured Burg recipe, its pitch-bound identity, both credible ranks, a matching observation value and profile on the original source window, and enclosing conditioning support. The v1 policy excludes F0 at or above 300 Hz and individual modeled gains exceeding 60 dB in magnitude. A harmonic within half a measured bandwidth of a pole, or a ceiling-sensitive Burg fit, carries low confidence. A qualifying pitch missing from a standalone archived formant scalar cannot establish this dependency. Pass the full Burg frame for correction. A failed Burg fit preserves its original scalar unavailability reason. Conditioning support contributes to the corrected delay once the pitch, window and formant recipe have qualified that dependency. [Applicability decision](https://github.com/plx/hdxl-voice-processing/issues/205) · [Archived F0 follow-up](https://github.com/plx/hdxl-voice-processing/issues/202)

## Export and evidence

The full frame’s JSON includes the original pitch observation, raw amplitudes and profile, Burg settings, observed pitch and support, both pole contributions, the first unusable ranked pole and its Burg rejection reasons when present, corrected amplitudes and the reason for any failure. The compact session scalar uses separate `harmonicFit` and `harmonicCorrection` recipes, distinct series identifiers and mandatory dependency intervals. Use `SessionArchiveMeasurement(timestamp:rawHarmonics:)` or `SessionArchiveMeasurement(timestamp:correctedHarmonics:)` with the corresponding profile. The full JSON is the export for reconstructing the individual model contributions.

Eight independently generated steady-state mixtures are filtered through two causal pole pairs and quantized to mono PCM16. Pinned Praat Fourier bins check the observed raw amplitudes over whole periods. A separate complex frequency-response calculation checks the signed corrections. The tests also cover nonintegral periods, arbitrary phase and DC, weak H2, extra harmonics and noise, missing evidence, source-clock offsets, alternative bandwidths and formant/F0 errors. The high-pitch fixture retains its raw result. [Reference and benchmark procedure](../Tools/Harmonics/README.md)
