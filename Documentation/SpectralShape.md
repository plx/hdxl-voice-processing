# Spectral shape from PCM, a frame, or an LTAS

Use these six measurements to describe how energy is distributed across frequency. A sharper resonance in the vocal tract, a change in the excitation, the microphone response, and the analysis window can all move a centroid or a fitted slope. In the test fixture, the same 32 Hz pulse train passes through filters centered at 96 and 288 Hz. Both the centroid and the named low/high ratio change. Interpretation of a recording therefore requires its source, filter, task and acquisition context. Vowel and vocal intensity effects have also been studied for cepstral measures. [Awan et al.](https://pubmed.ncbi.nlm.nih.gov/22480754/)

## Measure a frame

The example below takes mono PCM from the caller. At 16 kHz it uses a 20 ms periodic Hann window, a 10 ms hop and a 512-point FFT. Each call to the descriptor worker consumes the spectrogram column synchronously. Keep the same workers across contiguous chunks. Route chunk intervals and stream completion as described in the [spectral product guide](SpectralProducts.md).

```swift
import HDXLVoiceProcessing

let layout = try SpectrogramLayout(
    framing: FramingConfiguration(
        window: WindowSpecification(definition: .hannPeriodic, sampleCount: 320, sampleRate: 16000),
        hopLength: 160),
    transformLength: 512, channels: PCMChannelSelection(channelIndex: 0))
let band = try SpectralFrequencyBand(lowerHz: 80, upperHz: 4000)
let ratio = try SpectralBandRatioDefinition(
    name: VersionedIdentifier(name: "80-1000-over-1000-4000", version: 1),
    numerator: SpectralFrequencyBand(lowerHz: 80, upperHz: 1000),
    denominator: SpectralFrequencyBand(lowerHz: 1000, upperHz: 4000))
let profile = try SpectralShapeProfile(
    source: .frame, weighting: .power, analysisBand: band, includeDC: false,
    relativeLogFloorDB: -90, rollOffFraction: 0.85, bandRatio: ratio,
    fitBand: band, fitCoordinate: .octavesFromOneHertz, regressionWeighting: .uniform)
let fft = try PreparedSpectrogram<Double>(layout: layout, epoch: interval.epoch)
let shape = try PreparedSpectralShape(layout: layout, configuration: profile)
var last: Result<SpectralShapeResult, Error>?
let consume: (BorrowedSpectrogramFrame<Double>) -> Void = { column in
    last = Result { try shape.evaluate(column) }
}
_ = try pcm.withUnsafeBufferPointer { try fft.process($0, interval: interval, emit: consume) }
_ = try fft.finish(emit: consume)
let lastFrame = try last?.get()
let centroid = try lastFrame?.measurement(.centroid)
```

The same evaluator accepts a decoded `SpectrogramFrame`. Request just one descriptor with `evaluate(frame, only: .spread)`. A requested scalar carries a typed measurement outcome. Unrequested fields are absent. The full result retains the source layout, complete settings, numerical profile identity, timing, selection information and frame or aggregate origin. Use `measurement(_:)` to export one estimate and its coverage warnings to shared measurement consumers.

## Equations and units

Let P[k] be the one-sided bin power in FS², f[k] the center frequency in Hz, and Δf the FFT spacing. Full scale is the PCM amplitude reference. The configured analysis interval includes both endpoint **centers**. Excluding DC removes bin zero everywhere. Choose w[k] = P[k] for power weighting or w[k] = √P[k] for bin RMS magnitude. Let W be the sum of weights over the included centers.

| Descriptor | Definition and unit | Analytic fixture |
| --- | --- | --- |
| Centroid | μ = Σw[k] f[k] / W in Hz | Powers 4 and 1 at 64 and 192 Hz give 89.6 Hz. Magnitude weights give 106⅔ Hz. |
| Spread | √(Σw[k] (f[k] − μ)² / W) in Hz, the population standard deviation | The same power pair gives 51.2 Hz. A single ideal line gives zero. |
| Flatness | Geometric mean of weights divided by their arithmetic mean, dimensionless | Equal positive weights give one. An exact zero and a positive weight give zero with the log floor disabled. |
| Roll-off | Lowest center whose cumulative weight reaches the configured fraction of W, in Hz | With powers 4 and 1, the 80% threshold is 64 Hz and the 85% threshold is 192 Hz. At 100% the last positive bin sets the result. |
| Named band-energy ratio | 10 log₁₀(E numerator / E denominator) in dB. Both absolute components are also returned in FS². | A 4 FS² bin centered at a shared band boundary contributes 2 FS² to each band. A 4-to-1 component ratio gives about 6.0206 dB. |
| Fitted slope | Weighted least-squares coefficient β = Σv(x−x̄)(y−ȳ) / Σv(x−x̄)². Levels y are 10 log₁₀(P / 1 FS²) in dB. | P ∝ f⁻² yields −20 log₁₀(2) dB/octave. A synthetic line y = −3 − 0.002f yields −0.002 dB/Hz. |

The ratio always integrates **linear power**, and reports the caller's versioned definition of the numerator and denominator. Within a band, each available bin contributes its power times the fraction of its natural cell that overlaps the band. A cell extends halfway to each adjacent center and stops at 0 or Nyquist. DC and Nyquist therefore have half-width cells on the real, one-sided transform. Adjacent bands partition a boundary bin without double counting. A band inside one cell can use a fraction of that bin even if its center lies outside. A requested upper edge above the declared bandwidth or beyond the last available power cell yields `unsupportedRange` for that component. Independently supported components remain available.

For flatness and fit levels only, an optional nonpositive floor in dB replaces powers below Ppeak × 10^(floor/10). Each calculation uses the peak in its own center band. The flatness floor applies to both means before the selected power or magnitude weighting. With the floor disabled, zero bins force flatness to zero and are skipped in the logarithmic fit. The fit uses either x = f in Hz or x = log₂(f / 1 Hz) in octaves, which excludes DC even when the overall profile includes it. The weights v are one or the **unfloored** selected shape weights. Zero-weight bins cannot contribute to the weighted fit. The configured minimum fit count is at least two and defaults to three.

Fit diagnostics give the number of eligible center coordinates before level/weight checks, the number used, the number of used levels lifted by the floor, first and last used frequencies, weighted coordinate and level means, weighted RMS residual in dB, and R². R² is absent when the used levels have zero variance. Positive gain multiplies the absolute component powers by the squared gain, shifts the fitted level, and preserves the six shape descriptors while powers remain representable.

## Time aggregation and unavailable results

For an LTAS, append the prepared spectrogram's eligible columns to a `LongTermSpectrumAccumulator`, snapshot it with the observed source interval, and pass the result to a second worker configured with `.longTermSpectrum`. It evaluates the descriptors on the weighted **mean of the linear bin powers**. Consider two equal-duration frames, at 64 and 192 Hz, with relative powers 16 and 1. Averaging their centroids yields 128 Hz. The centroid of their mean spectrum is about 71.53 Hz. Frame and LTAS identifiers encode this distinction, and the LTAS result retains its aggregate timing, selection and partial-coverage warning. Its aggregate support includes the eligible-frame count and counts of rejected rows by reason, even when the overall spectrum is measured.

The result fingerprint includes the source spectral-product identity, upstream selection fingerprint when present, frame or LTAS selection, shape weighting, all band limits, ratio name/version, DC policy, floor, roll-off fraction, slope coordinates, regression weighting and minimum eligible bin count. The algorithm identifier also names the source and weighting. Scalar export preserves the selection-bound result fingerprint. Praat documents the influence of its spectrogram analysis settings and the choice of spectral weighting for a center-of-gravity calculation. [Praat spectrogram manual](https://www.fon.hum.uva.nl/praat/manual/Sound__To_Spectrogram___.html) · [Praat center-of-gravity manual](https://www.fon.hum.uva.nl/praat/manual/Spectrum__Get_centre_of_gravity___.html)

Upstream exclusion, missing acquisition, partial-frame status and numerical failures propagate. A supported but empty center or energy-cell selection gives `insufficientData`. A supported all-zero spectrum gives measured zero absolute energies and `silence` for undefined normalized or logarithmic measurements. Either zero component makes the logarithmic ratio unavailable. Inspect both energies to identify the zero. Sparse fits report their actual support and `insufficientData`; out-of-band requests report `unsupportedRange`. See the [analytic and streaming fixtures](../Tests/HDXLVoiceProcessingTests/SpectralShapeTests.swift) and [benchmark protocol](../Tools/SpectralShape/README.md).
