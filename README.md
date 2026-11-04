# HDXLVoiceProcessing

A Swift package under development for reproducible acoustic voice measurements
on macOS 27 and iOS 27. It will provide PCM analysis, native audio adapters, and
optional visualizations. Algorithms and microphone capture are not implemented
in this initial foundation. Measurements will retain units, validity, timing,
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

Dependency and fixture provenance is documented in [the policy](Documentation/ProvenancePolicy.md)
and [third-party notices](THIRD_PARTY_NOTICES.md). The project license is pending
[owner decision #78](https://github.com/plx/hdxl-voice-processing/issues/78); no
redistribution license is granted by the public development repository alone.
