# HDXLVoiceProcessing

A Swift package under development for reproducible acoustic voice measurements
on macOS 27 and iOS 27. It will provide PCM analysis, native audio adapters, and
optional visualizations. Deterministic PCM framing, windows, Fourier transforms, spectrum conversions, profile-specific conditioning, digital levels with K-weighted energy, and power-cepstral pipelines are implemented;
voice-measurement algorithms and microphone capture are still in development.
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

The independent consumer demonstrates the current `PCMFormat` value. Importing
core does not link capture/UI frameworks or require reference/benchmark tooling.

The Audio product now includes [bounded PCM transfer](Documentation/PCMTransfer.md)
between a capture adapter and a serial worker, with explicit loss intervals and fixed
storage. Native microphone adapters remain separate roadmap work.
This library has no app bundle and does not start microphones. Host applications
own permissions, audio sessions, sandbox entitlements, and lifecycle.

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
The [masking guide](Documentation/Masks.md) defines independent annotation, energy,
and spectral-flatness sources, original-timeline coverage, separate-region routing,
and inspectable exclusions without an implicit periodicity gate.
The [licensed voice corpus](Documentation/VoiceCorpus.md) supplies pinned PVQD originals,
sample-exact speech/vowel excerpts, simulated defects, explicit negative cases, and
offline load/decode checks without adding resources to runtime products.

Dependency and fixture provenance is documented in [the policy](Documentation/ProvenancePolicy.md)
and [third-party notices](THIRD_PARTY_NOTICES.md). The project license is pending
[owner decision #78](https://github.com/plx/hdxl-voice-processing/issues/78); no
redistribution license is granted by the public development repository alone.
