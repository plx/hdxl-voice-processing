# Burg formants from mono PCM

`PreparedBurgFormants` estimates resonances and their bandwidths from a finite interval of mono PCM. The core product accepts a sample buffer and source clock. Each output owns its candidates, prediction diagnostics and eligibility decisions. Formant numbers describe ascending frequency within one frame. Adjacent frames can exchange ranks as a resonance appears or disappears.

```swift
import Foundation
import HDXLVoiceProcessing

func analyzeFormants(_ pcm: [Float], epoch: StreamEpoch, startSample: Int64) throws
    -> [BurgFormantFrame]
{
    let source = try SourceInterval(
        epoch: epoch, startSample: startSample, sampleCount: Int64(pcm.count), sampleRate: 48_000)
    let profile = try BurgFormantProfile(
        sourceSampleRate: 48_000, inputPrecision: .float32, ceilingHz: 5500,
        order: 10, hopMilliseconds: 5, preEmphasisFromHz: 50)
    let analyzer = try PreparedBurgFormants<Float>(configuration: profile, source: source)
    var frames: [BurgFormantFrame] = []
    try pcm.withUnsafeBufferPointer { samples in
        try analyzer.analyze(samples, source: source) { frames.append($0) }
    }
    return frames
}
```

Read `frame.f1`, `f2`, `f3` or `formant(n)` for a credible rank. A missing F1 leaves F2 at rank 2. To export one scalar, call `try frame.measurement(number: 1, kind: .formantBandwidth)` or use `.formantFrequency`. The result carries hertz, a numbered algorithm identifier, timing, profile digest and an available or typed unavailable outcome. Register `frame.archiveProfile` with `SessionArchiveWriter` to persist either scalar with its base or pitch-bound numerical identity. Keep the frame for its full input, model and rejection evidence.

## Settings, support and latency

| Parameter | Contract |
| --- | --- |
| Input | Finite mono Float32 or Float64 at an integer 8,000–192,000 Hz. Declare the matching precision. Float32 widens exactly to Double before processing. |
| Ceiling | 4,000–8,000 Hz in 100 Hz increments, at most the declared input bandwidth. The default bandwidth is the input Nyquist frequency. Declare a lower bandwidth for filtered or upsampled material. |
| Prediction order | Even 4–16. Order 10 permits up to five conjugate pole pairs. |
| Conditioning | The whole-interval Praat 7 profile resamples to twice the ceiling with interpolation depth 50. Pre-emphasis follows resampling. The default is 50 Hz, the supported range is 0–1,000 Hz, zero takes a first difference and `nil` disables it. |
| Window and hop | Physical width 50 ms, effective Gaussian width 25 ms, hop 5 or 10 ms. The window has 400–800 samples at the analysis rate. |
| Capacity | Prepare for one fixed input length. The conditioner admits at most 2,880,000 input and 4,194,304 output or transform samples. It rejects intervals that round to zero output samples. |

The frame grid is centered on the conditioned sample centers. One complete window is admitted as soon as the conditioned buffer contains the required number of samples. Longer intervals use the pinned binary64 grid and the 50 ms physical duration. The taper uses `u=(2n+1−N)/(N+1)` and `w=(exp(−12u²)−exp(−12))/(1−exp(−12))`. The profile applies no de-meaning. Praat documents its resampling frequency, pre-emphasis and effective window convention. The separately identified window is checked against pinned command-line observations. [Praat Burg manual](https://www.fon.hum.uva.nl/praat/manual/Sound__To_Formant__burg____.html) · [Window definitions](Framing.md) · [Conditioning](Conditioning.md)

`centerSecondsFromOrigin` is relative to the start of the supplied interval. `timing.source` encloses the original sample cells covered by the conditioned window. `conditioningSupport` records the complete input dependency. Integer rate-ratio arithmetic maps both analysis cell edges to original samples, including exact boundary ties and short windows late in a long recording. `timing.effectiveDelaySeconds` gives the remaining acquisition time from frame center to interval end. A prepared interval too short for a window emits one `.shortWindow` result with its observed support. Acquisition, computation and display each contribute separately to end-to-end latency.

Use this profile on an analysis worker once a complete interval is available. The same worker accepts another contiguous interval of equal sample count and rate, including one from a new epoch. Each call starts fresh. Frame callbacks can retain their arguments, and a throwing callback stops further delivery. A new plan fixes a different duration or configuration. Splitting one recording changes the conditioning boundaries and can change the frame grid. This matters when comparing live excerpts with a whole-recording reference.

## Predictor, poles and credibility

Burg fitting peak-normalizes the window input, applies the Gaussian, and updates forward and backward prediction errors at each order. The monic polynomial is `zᵖ + a₁zᵖ⁻¹ + … + aₚ`. Each reflection coefficient is `−2Σfb / Σ(f²+b²)`. The product of `1−k²` gives the prediction error ratio, and `−10 log₁₀(ratio)` gives gain in dB. Each frame records coefficients, error ratio, gain and maximum reflection magnitude. Each frame also checks its original PCM support for silence or constant input. This prevents resampler ringing at the edge of a voiced segment from generating a measured resonance inside a digital pause. Silence, constant input, singular energy and unit-magnitude reflections have separate diagnostics. [Burg, Maximum Entropy Spectral Analysis](https://sep.sites.stanford.edu/publications/theses/maximum-entropy-spectral-analysis-sep-6-1975)

The simultaneous polynomial solver tries two deterministic starts with at most 64 Ehrlich–Aberth sweeps each. Acceptance requires a scaled point residual at most 1e−10 and reconstruction of the entire monic polynomial within 1e−7 of its largest coefficient. A failed solve reports its sweep count and yields no inferred roots. Exact factors of zero retain their multiplicity. Burg scratch grows with window length and order. Root and candidate buffers are bounded by order 16. Processing emits one frame at a time, and the caller controls retention.

For a stable pole with argument θ in the upper half-plane and radius r, `frequencyHz = θ fs / (2π)` and `bandwidthHz = −fs ln(r) / π`, using the **analysis** sample rate. Each conjugate pair appears once. Raw candidates include real poles, zero radii and unstable poles with explicit reasons. Zero and unstable radii have no reported bandwidth. Ranking excludes poles with |imaginary component| ≤ 1e−8 and frequencies within 50 Hz of DC or the ceiling (the endpoints at 50 Hz and ceiling−50 Hz are included).

The rule `exploratory-burg-credibility-v1` keeps the rank assigned before these additional checks.

| Evidence | Frame or candidate outcome |
| --- | --- |
| Prediction gain below 3 dB | Weak prediction on the frame and rejection of every ranked candidate. |
| Bandwidth above the lesser of 1,000 Hz and the center frequency | Reject that rank as broad. |
| Support-matched F0 present | Reject candidates below 2 × F0. Flag the frame for high pitch at F0 ≥ 300 Hz. |
| F0 missing or from other support | Report `pitchUnassessed` or `pitchSupportMismatch`. An unmatched F0 cannot exclude a pole. |
| Fewer than the first three possible ranks, or a ranked pole above 90% of ceiling | Flag the nonempty root solution as ceiling-sensitive. |

A caller with F0 evidence can supply a `pitch` closure to `analyze`. Its argument is the requested window. Return a `FormantPitchEvidence` containing the pitch detector's own source interval and profile identifier. The frame retains the observation, and its profile binds the formant settings, pitch profile and support-match outcome. `burg-formants-untracked/v1` identifies the base settings including precision, ceiling, order, hop, declared input bandwidth and pre-emphasis.

The rule describes a model fit, and noise can also produce a narrow pole. On the white-noise control, 14 candidates passed. A consumer applying harmonic correction should check the expected profile and rule, original epoch and support, appropriate pitch and analysis task, frame cautions, and a credible frequency **and measured bandwidth** for every needed rank. Preserve an unavailable outcome when required evidence is absent. Harmonic correction is a separate operation with its own assumptions and output identity. [VoiceSauce parameters](https://www.phonetics.ucla.edu/voicesauce/documentation/parameters.html) · [Iseli, Shue and Alwan, 2007](https://www.ee.ucla.edu/~spapl/paper/Iseli_JASA_07.pdf)

## Reference evidence

Seven synthetic signals exercise known pole pairs, F0 at 105 and 385 Hz, closely spaced resonances, spectral tilt, added noise and a white-noise control. Three licensed speech excerpts add two vowels and a consonant-rich interval. Paired Praat 7.0.02 commands analyze the exact same quantized PCM with the same ceiling, order, window, pre-emphasis and hop. In 198 frames the native grid and pole counts agreed. The largest absolute difference was 1.86e−7 Hz in frequency and 3.77e−6 Hz in bandwidth across 1,165 raw candidates. Among the 1,113 edge-filtered poles the corresponding maxima were 1.86e−7 Hz and 8.85e−7 Hz. The additional credibility rule retained 921. Reconstructing each full predictor from the reference poles checks 2,476 coefficients. The largest absolute coefficient difference was 1.15e−9. Swift tests print per-case errors and retention counts.

Independent tests use an exact rational predictor, analytically constructed conjugate pole pairs, and a synthetic vowel with five imposed resonances. Recovery on finite synthetic audio uses median errors below 100 Hz in frequency and 200 Hz in bandwidth for each resonance. Those tolerances describe model recovery on that stimulus. Licensed speech provides a comparison between algorithms without assumed anatomical ground truth. [Fixture reproduction and performance workloads](../Tools/Formants/README.md)
