# HDXLVoiceProcessing

A Swift package under development for reproducible acoustic voice measurements
on macOS 27 and iOS 27. It will provide PCM analysis, native audio adapters, and
optional visualizations. Deterministic PCM framing, windows, Fourier transforms, spectrum conversions, profile-specific conditioning, digital levels with K-weighted energy, and power-cepstral pipelines are implemented;
voice-measurement algorithms and native capture adapters are being brought up
through the roadmap; physical capture validation remains pending.
Measurements will retain units, validity, timing,
and numerical-profile identity; they are not universal voice-quality or health scores.

Requires Xcode 27.0 / Swift 6.4, using Swift 6 language mode.

| Product | Purpose |
| --- | --- |
| `HDXLVoiceProcessing` | PCM contracts and deterministic algorithms |
| `HDXLVoiceProcessingAudio` | Optional Apple audio integration |
| `HDXLVoiceProcessingVisualization` | Optional SwiftUI components |

```sh
swift build
swift test
swift run --package-path Examples/CoreConsumer CoreConsumer
```

The independent consumer demonstrates contracts, masks and selected-region scheduling. Importing
core does not link capture/UI frameworks or require reference/benchmark tooling.

The optional [visualization product](Documentation/Visualization.md) provides immutable
result/frame adapters, source selection, a SwiftUI metric inspector, explicit status
views and capture-free previews. Dense plotting and synchronized comparison follow
in their roadmap issues; independent Core and Audio clients remain free of UI dependencies.

The Audio product now includes [bounded PCM transfer](Documentation/PCMTransfer.md)
between a capture adapter and a serial worker, with explicit loss intervals and fixed
storage. Native [macOS](Documentation/MacOSCapture.md) and
[iOS](Documentation/IOSCapture.md) adapters provide explicit foreground capture
and effective acquisition metadata, with physical evidence pending #74.
This library has no app bundle and does not start microphones. Host applications
own permissions, audio sessions, sandbox entitlements, and lifecycle.
The [host integration contract](Documentation/HostCaptureIntegration.md) defines
platform/evidence limits, read-only capture preflight, explicit session delegation,
and requested versus observed acquisition metadata.
The [capture lifecycle coordinator](Documentation/CaptureLifecycle.md) owns native
capture and a serial analysis worker, with explicit reconfiguration, cancellation
and host-controlled recovery.
Its [bounded result subscriptions](Documentation/ResultDelivery.md) preserve current
metric and fault state through display coalescing, with explicit overflow and runtime diagnostics.

[Shared scheduling](Documentation/SharedScheduling.md) now feeds Levels, YIN and CPP/CPPS
from memory, files, isolated file batches and worker-side PCM transfer. Matching profiles
share numerical execution, with explicit gaps, masks, coverage and timing requirements.

[Personal calibration records](Documentation/Calibration.md) separate production
instructions from listening labels, preserve acquisition conditions and raw metrics,
and freeze whole-recording/session holdouts. The Audio product verifies file hashes
before analysis or cache reuse. A [synthetic workflow example](Examples/CalibrationWorkflow/README.md)
demonstrates collection, labeling, comparisons and evaluation without private recordings.

See [contribution instructions](CONTRIBUTING.md),
[architecture](Documentation/Architecture/0001-package-boundaries.md), and the
[roadmap](https://github.com/plx/hdxl-voice-processing/issues/1).
watchOS is pending a separate capability decision. Physical-device validation
is deferred to [follow-up #74](https://github.com/plx/hdxl-voice-processing/issues/74).

Pinned developer-only Praat runners, original synthetic goldens, and offline Swift
fixture checks are described in [reference tooling](Tools/Reference/README.md).
[Assigned reference routes](Tools/Reference/ROUTES.md) cover the planned algorithms.
The [framing guide](Documentation/Framing.md) specifies sample grids, windows,
discontinuities, partial support, and borrowed-buffer ownership.
The [Fourier guide](Documentation/FourierTransforms.md) defines transform scaling,
real/complex storage, window-normalized spectra, and independent accuracy bounds.
The [conditioning guide](Documentation/Conditioning.md) defines raw pre-emphasis, whole-interval
Praat compatibility, streaming preview, bandwidth checks, boundary support, and recorded delay.
The [digital-level guide](Documentation/DigitalLevels.md) defines peak/RMS/dBFS, clipping
diagnostics, continuous K-weighting, warm-up, numeric limits, and source timing.
The [cepstral guide](Documentation/Cepstrum.md) defines the pinned power/log/transform recipe,
Double arithmetic for both PCM precisions, whole-interval/preview profiles, finite-stage
availability, borrowed data and bounded exports. The [CPP guide](Documentation/CPP.md)
defines peak search, inspectable background fits, explicit reference versus mathematical
robust estimators, and prepared PCM-pipeline consumption. The [CPPS guide](Documentation/CPPS.md)
defines the pinned smoothing recipe, whole-interval and preview PCM paths, selected-region
statistics, bounded rolling windows, and explicit freshness/coverage.
The [YIN guide](Documentation/YIN.md) defines PCM pitch estimation, raw candidates,
periodicity, actual observed support, optional causal tracking and separate history timing.
The [SWIPE-prime guide](Documentation/SWIPEPrime.md) defines the optional multi-window
pitch estimator, signed strength, bounded intermediate exports and independent parity evidence.
The [pulse guide](Documentation/Pulses.md) defines injected-F0 waveform matching,
explicit period/pair eligibility, cycle amplitudes, and bounded chunked delivery.
The [jitter guide](Documentation/Jitter.md) defines local, absolute, RAP, PPQ5 and
DDP statistics, coverage-aware PCM analysis and incremental exploratory windows
with explicit denominator context and source timing.
The [shimmer guide](Documentation/Shimmer.md) defines local, dB, APQ3/5/11 and
DDA statistics, shared cycle RMS extraction, explicit amplitude eligibility and
bounded exploratory histories with coverage.
The [masking guide](Documentation/Masks.md) defines independent annotation, energy,
and spectral-flatness sources, original-timeline coverage, separate-region routing,
and inspectable exclusions without an implicit periodicity gate.
The [personal-target guide](Documentation/PersonalTargets.md) defines training-only
CPPS intervals, exact-profile validation, held-out recording/session evaluation,
confound checks, abstention and the limits of personal-label associations.
The [feedback policy](Documentation/PersonalTargetFeedback.md) adds source-time
persistence, hysteresis, explicit uncertainty and bounded observers without changing
the accepted target's measurement semantics.
The [session interchange guide](Documentation/SessionInterchange.md) describes
bounded result/calibration archives, audio-free export, explicit original-media
inclusion, private atomic file storage, verified PCM replay and inspection separate
from target activation.
The [licensed voice corpus](Documentation/VoiceCorpus.md) supplies pinned PVQD originals,
sample-exact speech/vowel excerpts, simulated defects, explicit negative cases, and
offline load/decode checks without adding resources to runtime products.

Dependency and fixture provenance is documented in [the policy](Documentation/ProvenancePolicy.md)
and [third-party notices](THIRD_PARTY_NOTICES.md). The project license is pending
[owner decision #78](https://github.com/plx/hdxl-voice-processing/issues/78); no
redistribution license is granted by the public development repository alone.

The [macOS capture adapter guide](Documentation/MacOSCapture.md) describes native input, explicit start/stop, worker channel selection, timing, and the signed development host.
