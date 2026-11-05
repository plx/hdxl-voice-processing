# Cepstral peak prominence

`PreparedCPP` consumes linear power cepstra from the PCM pipeline described in
[Cepstrum](Cepstrum.md). It selects a peak in the original dB cepstrum, fits a
straight background versus quefrency, and subtracts the background value at the
selected peak. It does not smooth cepstra, subtract a trend before selecting the
peak, aggregate frames, or require a successful F0 estimate. CPPS and interval
selection are subsequent consumers. A higher CPP is not a universal quality score.

## Profiles and numerical definition

`CPPProfile` binds a `CPPConfiguration` to either one conditioned-frame recipe or a
complete `CepstrogramConfiguration`. All requested settings, conditioning choices,
source precision and analysis geometry participate in its fingerprint. The prepared
consumer checks the upstream profile identity and frame configuration on every call.
Whole-interval, finite-FIR preview and isolated-frame results cannot silently exchange
identities. Configuration decoding rejects unknown, missing and contradictory fields.

Power is converted to `10*log10(power + 1e-30)`. The additive term is in the input
power units (inverse seconds squared); it is not a maximum/clamp operation.
Thus zero power is -300 dB, and finite positive power below the additive term remains
distinguishable. The peak/background magnitudes are dB relative to one inverse-second-
squared; their difference is a dimensionless dB ratio. Slope is dB per second of
quefrency, and intercept is dB at q=0.

| Fit method | Exact slope definition | Intercept | Identity family |
| --- | --- | --- | --- |
| `leastSquares` | Centered least-squares line | Mean residual intercept | Pinned Praat 7 CPP |
| `praat7002Robust` | Median of the first n−1 pointwise slope medians; each pointwise median uses all other points | Median over all n intercepts | Pinned Praat 7 CPP |
| `siegelRepeatedMedian` | Median of all n pointwise slope medians | Median over all n intercepts | Complete mathematical Siegel |
| `completeTheilSen` | Median of all n(n−1)/2 distinct pairwise slopes | Median over all n intercepts | Complete mathematical Theil–Sen |

All native methods are deterministic. There is no random seed, random subsampling,
or incomplete Theil approximation. Even-sized medians average the two central values.
The two mathematical robust estimators intentionally have different identifiers from
pinned Praat compatibility. [Decision #107](https://github.com/plx/hdxl-voice-processing/issues/107)
records the observed reference defects and exact distinctions.

`CPPConfiguration()` selects complete mathematical Theil–Sen, parabolic peaks,
60–333.3 Hz search and a requested 1–50 ms fit. It is not a claim to emulate Praat's
defective randomized selector. `murtonRecipePraat7()` selects the published 60–330 Hz,
parabolic, `Robust`, 0.001–0-second command settings with the pinned modern behavior.
These are unsmoothed per-frame settings, not a complete CPPS implementation. The
publication used Praat 6.0.40; historical parity remains separate under
[#86](https://github.com/plx/hdxl-voice-processing/issues/86).

## Requested and effective ranges

Peak search is `[1/pitchCeiling, min(1/pitchFloor, qMaximum)]`. It is a numerical
period range, not independent tracking confidence. A range completely outside support
produces `.unsupportedRange`. Within support, nearest-bin or parabolic interpolation
is explicit. When no bin center lies in the range, compare the values at the two
range endpoints, using nearest or linear value interpolation respectively; equal
endpoint values select the interval midpoint.

The pinned peak search visits both endpoints and local maxima from both directions.
Its local comparisons use a relative `1e-12` tolerance (absolute when either operand
is zero). Parabolic interpolation uses adjacent dB samples. An interpolated position
is clipped to the search interval without recomputing its peak height. If the two
searches choose distinct truncated one-based indices and right minus left is at most
five, the pinned rule uses their index midpoint and the left index's bin magnitude.
`usedBidirectionalTieRule` exposes that decision. It can affect broad plateaus and
close competing peaks. `peakIsAtSearchBoundary` describes the final position.

A positive fit end is intersected with the available quefrency domain. A zero fit
end requests Praat's **whole-domain autowindow**, including replacement of the requested
start. Then q=0 is excluded, and only bin centers inside the effective domain enter
the fit. For the default 513-bin/10 kHz grid, `0.001–0` therefore fits bins 1...512,
whereas an explicit `0.001–0.0512` fits bins 10...512. `CPPLayout` exposes requested-
range resolution, actual first/last fit bins and point count. Fewer than three fit
points produces `.insufficientData`; no supported fit domain produces `.unsupportedRange`.

## Prepared processing and availability

Prepare off the capture callback and serialize calls on one worker. The consumer
reuses dB, background, residual, fit-coordinate and median-selection storage. It
does not retain a growing history or matrix. Complete Theil uses all pairwise slopes;
selection uses deterministic three-way partitioning with a finite partition budget
and in-place heapsort fallback. This bounds worst-case selection by O(p log p),
where p is the number of slopes. Siegel performs bounded selection for each point.
Prepared scalar workspace is reported separately from object overhead/process RSS.

Robust fits permit at most 2,048 fit points. Preparation rejects larger robust work
with `.capacityExceeded`; it does not silently sample fewer points. Least squares
supports the full bounded upstream cepstral grid. `slopeEvaluationCount` exposes the
exact per-frame pair evaluations, excluding median/residual work. These limits do
not assert that every accepted configuration meets a physical-device deadline.
The [host evidence](Evidence/cpp.md) separates isolated fit/search from complete
PCM-to-CPP batches. In the initial measurements, the pinned 513-bin robust fit
could exceed a 2 ms hop before upstream work. Choose fit and hop explicitly and
measure the complete recipe on the intended device.

Invalid buffer size, negative/nonfinite power, inconsistent context and mismatched
upstream recipes throw before mutating scratch or calling the consumer. A complete
frame requires the corresponding observed support. Upstream silence, insufficient
support and other unavailability propagate without fabricating scalar zero. An
explicitly supplied all-zero **power cepstrum** is a finite flat -300 dB observation
with zero prominence; a silent **PCM frame** remains unavailable under its upstream
cepstrum definition. Flat/noisy low-prominence observations need no F0 gate.

Borrowed output is valid only during the synchronous callback, and recursive calls
are rejected before mutation. Each frame is independent; no CPP history needs to be
joined across a gap. The upstream whole/preview worker owns continuity, reset,
cancellation and finalization. Its complete `CepstralFrameContext` is retained in
every CPP result, including source origin, support, boundary extension and delivery
delay. Cancelling the upstream worker during the CPP callback preserves both active
borrows until the callback ends.

## Consumption and diagnostics

Create the PCM worker and CPP consumer from the same cepstrogram configuration:

```swift
let profile = CPPProfile(
    cepstrogram: configuration,
    settings: try CPPConfiguration.murtonRecipePraat7())
let cpp = try PreparedCPP(profile)
// Append PCM chunks to PreparedIntervalCepstrogram as documented in Cepstrum.md.
var consumerError: (any Error)?
try cepstrogram.finish { frame in
    guard consumerError == nil else { return }
    do {
        try cpp.analyze(frame) { output in
            // output.result is an owned scalar value with profile and source timing.
            // output.values(.residualDB) is borrowed only for this callback.
        }
    } catch { consumerError = error }
}
if let consumerError { throw consumerError }
```

The preview worker uses the same consumer inside its `process` and `finish` callbacks.
`analyzePowerCepstrum` is the isolated-bin entrypoint and requires a conditioned-frame
profile; it cannot label caller-supplied arrays with a complete PCM-pipeline identity.
The caller supplies the documented grid, units and observed context explicitly.

`CPPObservation` exposes peak position/magnitude, background at the peak, slope,
intercept, residual mean/RMS/median/maximum absolute value, and peak-selection flags.
Residual diagnostics use only fitted bins. Borrowed dB/background/residual arrays
cover the full grid and never modify the input. Unavailable results expose empty
arrays rather than stale scratch from a prior frame.

Owned array export is opt-in and checked against a combined scalar budget. Copies
and serialization are outside the prepared processing allocation contract. The
scalar result converts explicitly to the shared Codable `MeasurementResult`, in
`decibelsRatio`, preserving source timing and availability; boundary extension adds
a partial-coverage warning. Preserve the full `CPPProfile` with exported diagnostics.
Sampled `analysisFrame`/`cpp` diagnostic spans end before consumer callbacks and
contain only numeric metadata, never PCM or per-sample events.

Primary definitions: [Praat CPP](https://www.fon.hum.uva.nl/praat/manual/PowerCepstrum__Get_peak_prominence___.html),
[peak interpolation](https://www.fon.hum.uva.nl/praat/manual/vector_peak_interpolation.html),
[Theil regression](https://www.fon.hum.uva.nl/praat/manual/theil_regression.html),
[Murton et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC7893528/).
The [pressed/breathy phonation study](https://pubmed.ncbi.nlm.nih.gov/40021420/) also
illustrates why higher CPP cannot be mapped automatically to a better voice.
Pinned source behavior takes precedence over ambiguous manual labels; see the
[reference tools](../Tools/CPP/README.md). Physical measurements remain [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
