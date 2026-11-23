# Inspect a calculation

A pitch value of 95 Hz can have a competing candidate near 192 Hz in the same window. The inspector shows the normalized difference at each lag, each candidate’s frequency and threshold result, and the estimator’s chosen candidate. Select a bin to read its original value and units. Open the profile to see the recipe and its fingerprint. The phone preview uses a synthesized two-harmonic signal so you can reproduce the competing candidates. [YIN paper](https://doi.org/10.1121/1.1458024)

## Capture a frame

Create one history per algorithm and committed configuration epoch on the analysis worker. Choose the origin explicitly. The example selects frame 12 from a recording. Pass the estimator’s frame index when delivering its synchronous callback. The helper accepts a throwing inspection closure, so a host using a nonthrowing DSP callback can collect the error and report it after the processor returns.

```swift
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization

let context = InspectionContext(origin: .recording, configurationEpoch: 4)
let processor = try PreparedYIN<Double>(settings)
var history = try InspectionHistory(
    sampling: .selected(frame: 12), context: context,
    source: VisualizationSource(recording), profile: processor.identity)

var captureError: (any Error)?
try processor.analyze(samples, timing: timing, frameIndex: frameIndex) { output in
    do {
        try history.capture(frame: output.result.frameIndex) { limits in
            try AlgorithmInspection.pitch(output, recipe: settings, context: context, limits: limits)
        }
    } catch { captureError = error }
}
if let captureError { throw captureError }
```

The default policy is disabled. Selected and sampled policies check the frame index before invoking the projection. A sampled history such as `.sampled(every: 4, maximumFrames: 8)` also bounds the total curves’ scalar count, retained records and metadata bytes across all snapshots. A single over-budget snapshot fails atomically. Older complete snapshots are evicted first. Keep the capture on a worker and deliver immutable snapshots to the UI through a bounded host queue. A consumer retaining old copies has its own memory budget.

On a live profile change, finish or discard the old partial window, reconfigure the production processor, and call `history.nextConfiguration(source:profile:)` with the reconfigured processor’s source clock to begin an empty history with the next configuration epoch. Source discontinuities use a new source epoch. Views can still display the previous immutable snapshots with their original timing and recipe.

## Follow the stages

| Inspector | What to inspect |
| --- | --- |
| CPP | Pass the upstream cepstral view alongside the borrowed CPP output inside the same callback. Inspect the conditioned window, spectrum and log spectrum, power cepstrum, dB curve, search bounds, peak, fitted background and residual. CPP is the level difference at the selected quefrency. [Praat power cepstrum](https://praat.org/manual/Spectrum__To_PowerCepstrum.html) · [Peak prominence](https://praat.org/manual/PowerCepstrum__Get_peak_prominence___.html) |
| CPPS | Compare raw CPP with the smoothed estimate at the same center. Advance through the prepared, time-smoothed and quefrency-smoothed power curves. The normalization flag in the recipe determines whether prepared power has physical units or is dimensionless. Time support includes the contributing neighboring frames. [Praat CPPS](https://praat.org/manual/PowerCepstrogram__Get_CPPS___.html) |
| YIN and HNR | YIN displays peak-normalized difference minima. The tracked projection preserves both choices and the history supporting the tracker. HNR displays the actual autocorrelation or forward cross-correlation, validity gaps, accepted and discarded candidates, and the selected harmonicity. An exactly periodic result can lack a finite dB value. [YIN](https://doi.org/10.1121/1.1458024) · [Praat harmonicity](https://praat.org/manual/Sound__To_Harmonicity__ac____.html) |
| Pulses, jitter and shimmer | Inspect tracking attempts, landmarks, adjacent periods and pairs, cycle amplitudes, and named rejection reasons. Jitter and shimmer retain the selected query, source provenance, eligible neighborhood counts and each requested variant’s outcome. Very few eligible cycles can leave every variant unavailable. [Pulse matching](https://praat.org/manual/Sound___Pitch__To_PointProcess__cc_.html) · [Jitter](https://praat.org/manual/Voice_2__Jitter.html) · [Shimmer](https://praat.org/manual/Voice_3__Shimmer.html) |
| Spectrum and shape | Inspect the actual linear bin powers and grid, component band energies, the fitted band, and eligible versus floored regression bins. The individual descriptor outcomes carry their own units. [Spectrum](https://praat.org/manual/Sound__To_Spectrum___.html) · [Center of gravity](https://praat.org/manual/Spectrum__Get_centre_of_gravity___.html) |
| Formants and H1–H2 | Inspect the Burg coefficients, frequencies, bandwidths and rejection reasons for candidate poles. Compare the two fitted harmonic levels with the formant gains and the corrected estimate. An unusable pole or missing pitch keeps its failure reason. [Burg formants](https://praat.org/manual/Sound__To_Formant__burg____.html) · [Harmonic correction](https://www.ee.ucla.edu/~spapl/paper/Iseli_JASA_07.pdf) |

Use `AlgorithmInspectorView` for one snapshot. `AcousticPlotInspectorView` binds the same source selection as the waveform, spectrum, metric or cepstrogram. A point inside overlapping windows can have several matching calculations. Choose the one you want to inspect. A gap has an explicit empty state. Source intervals are half-open sample ranges and maintain exact integer clock identities. A fractional batch perturbation query keeps its original closed bounds in seconds relative to its dependency. To add a method, construct an `AlgorithmInspection` with its window, dependency, recipe, reference, actual measurement outcomes, explanatory fields, and optional uniformly spaced curves.

## Compare frozen settings

```swift
let input = try FrozenInspectionInput(samples: monoPCM, source: recordingSelection, context: context)
let experiment = try FrozenInspectionExperiment(input: input, recipe: .pitch(originalSettings))
let alternative = InspectionAlternative("Higher dip threshold", recipe: .pitch(changedSettings))
let workbench = try FrozenInspectionExperimentView(experiment, alternatives: [alternative])
```

The workbench evaluates an alternative after the user requests it. The typed recipe selects a fresh production YIN, CPP or CPPS processor. Both results refer to the same frozen samples and local observation window. For CPP and CPPS, supply the recording from the conditioning origin and choose a frame index. Replay uses the original Float32 or Float64 input precision and the recipe’s finite-FIR preview or whole-interval processor. The processor stops after the requested fit and its required lookahead. An absent frame or changed observation support produces a selection error. The comparison shows each changed setting with its original and new values. Repeated comparisons always use the original baseline.

The public consumer benchmarks 240 consecutive synthetic YIN frames in four modes. The evidence records individual frame durations, projection time on captured frames, retained curve and metadata bytes, and process peak resident memory growth. Physical capture and thermal measurements are tracked separately. [Evidence guide](../Tools/Visualization/README.md) · [Physical measurements](https://github.com/plx/hdxl-voice-processing/issues/74)
