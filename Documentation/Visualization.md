# Optional visualization contracts

Roadmap: [#21](https://github.com/plx/hdxl-voice-processing/issues/21).
`HDXLVoiceProcessingVisualization` is an optional SwiftUI library for macOS 27.0
and iOS 27.0, using Xcode 27.0 / Swift 6.4 in Swift 6 mode. It depends only on
Core. Import Core and Visualization in a host that needs both scientific values
and presentation. Core and Audio do not import or link SwiftUI/Charts when consumed
independently. `Examples/CoreConsumer`, `Examples/AudioConsumer` and
`Tools/verify-package-graph.py` check that boundary.

The current rendered components are a metric inspection panel, a measurement
readout, explicit status views and synthetic preview hosts. Array, segmentation,
profile and diagnostics contracts are ready for later renderers. Dense plots,
downsampling and their frame-rate gates belong to #48; synchronized algorithm
inspection and comparison belong to #49. No Charts API is needed for this first
contract. SwiftUI Observation, `ImageRenderer`, `ViewThatFits` and named `#Preview`
are available at the declared minimums; there is no older-system fallback.

## Adapt scientific values without changing them

| Input / adapter | Preserved meaning |
| --- | --- |
| `MeasurementResult` → `VisualizationMeasurement` | Full descriptor, algorithm/profile identity, outcome, confidence, warnings, exact source timing, optional clocks/delay, included samples and intermediates |
| `ScheduledFrame` plus metric, or `ScheduledMeasurementExport` → measurement | The full export, including schedule origin, dependency support/coverage, mask provenance and worker batching metadata |
| Ordered measurements → `VisualizationMetricSnapshot` | One descriptor/profile/source/scheduled origin, explicit discontinuities, bounded original records; no sorting, interpolation or silent dropping |
| `IntermediateSnapshot` → `VisualizationFrameSnapshot` | Original stage, physical axes, finite values and source interval; domain validates the x unit |
| Measurement plus intermediate index → frame | Original parent outcome/timing as well as the selected intermediate; parent and frame support remain distinct |
| `PowerCepstrumFrame` → frame | Recipe, expected bins, finite prefix, unavailability and boundary-extension context |
| Owned mono `[Double]` plus source/profile/stage → waveform | One normalized-amplitude value per source sample, relative seconds axis; channel selection/conditioning belongs in the profile |
| `MaskTimeline` → `VisualizationSegmentationSnapshot` | Original plan, annotations, resolved exclusions, missing acquisition and whole-timeline coverage |
| Analysis/schedule profile → `VisualizationProfileSnapshot` | Full typed recipe, identity and canonical JSON prepared outside view evaluation |
| Host diagnostics → `VisualizationDiagnosticsSnapshot` | Typed counters, latency summaries, delivery statistics and optional source/profile context; unavailable/saturated summaries stay explicit |

Profile identity alone can also be inspected, with `.identityOnly` and no canonical
recipe. It does not imply reproducibility, execution or activation of that profile.
The scheduled profile's JSON uses the same sorted-key, unescaped-slash encoding as
Core's identity; the adapter tests verify that its SHA-256 matches the identity.

An absent estimate never becomes zero. A finite zero remains an available estimate.
A finite intermediate may exist even when its parent metric is unavailable; inspect
the parent outcome separately. A partial power cepstrum retains both its finite
prefix and missing-result reason. A missing discontinuity extent remains unknown.
Adapters cannot infer a gap from a large hop alone, so the host must supply known
`SourceDiscontinuity` records rather than replacing lost audio with silence.

`VisualizationValueFormat` supports native units, seconds → milliseconds and
fraction → percent. Already-percent values remain unchanged under percentage
formatting. Unsupported conversions and nonfinite converted values throw. Labels
distinguish ratio dB, dBFS and calibrated SPL, normalized amplitudes and powers,
time, frequency, and dimensionless values. The original outcome/unit always remain
available beside the display value. Display precision and locale do not alter
scientific data. Confidence is estimator-defined, not a probability of voice health.

## Ownership, limits and publication

Snapshots are immutable `Sendable` values. Arrays are Swift-owned copy-on-write
storage; they retain no processor scratch pointers or audio callback buffers.
Adapting an already-owned array can share its immutable allocation. Mutating a
producer's separate array value triggers a copy and cannot change the snapshot.
That does not permit two tasks to concurrently mutate the same variable: the host
must still serialize its worker and copy borrowed processor output before export.

Construct and validate snapshots on a worker, after copying any borrowed data and
outside the audio callback. Publish complete values through the main-actor store.
The default per-snapshot budgets are 4,096 metric records, 262,144 retained frame
scalars, 8,192 segments/boundaries, and 1 MiB of metadata UTF-8 payload. Counts include
nested intermediate arrays and conservative repeated metadata charges. These are
retention limits, not process RSS or allocation guarantees. Inputs have already
been created by the producer; rejecting an oversized input cannot recover that
construction cost. Hosts must bound input production and queues as well.

Choose explicit larger `VisualizationLimits` only when required. Adapters throw
`capacityExceeded` instead of silently truncating source data. The host can retain
a bounded rolling history before constructing the snapshot, preserving relevant
gaps and exact identities. A frame adapted with its parent retains all the parent's
intermediates and charges their combined scalar count. Profile recipe bytes have
their own check against the metadata limit. No work is scheduled automatically.

`VisualizationMetricStore` is host-owned `@MainActor @Observable` state for one
series. It owns no task, subscription, capture engine, permission query or session.
Keep one store per independently updating metric. `snapshot`, stable `series`,
`state`, `presentation` and selection are separate observable properties. The
panel's history, heading and profile identity are separate observer views; a history
update need not invalidate a sibling metric or stable profile text. Equal snapshots
can be suppressed by Observation. The host controls update cadence/coalescing and
cancellation, using the [bounded result-delivery contract](ResultDelivery.md).

For example, a host can adapt an already-exported worker result before publication:

```swift
import HDXLVoiceProcessing
import HDXLVoiceProcessingVisualization

func snapshot(for export: ScheduledMeasurementExport) throws -> VisualizationMetricSnapshot {
    let row = VisualizationMeasurement(export)
    return try VisualizationMetricSnapshot(series: row.id.series, measurements: [row])
}

@MainActor
func publish(_ next: VisualizationMetricSnapshot, into store: VisualizationMetricStore) {
    store.replace(next, state: .running)
}
```

Use `VisualizationMetricPanel(store:)` in the host's SwiftUI hierarchy, retaining the
store at the appropriate root with `@State`. A `VisualizationFixtureView` demonstrates
that ownership without a subscription or microphone. The independent
[visualization consumer](../Examples/VisualizationConsumer/README.md) exercises real
construction and publication through public APIs.

## Source time and selection

`VisualizationSource` includes stream UUID, epoch sequence and sample rate.
`VisualizationSeriesKey` also includes measurement/algorithm, profile identity and,
for scheduled results, the complete schedule origin. Changed epochs, profiles,
source clocks or continuity origins create distinct series. Never join their
curves without an explicit comparison transform supplied by the host.

`VisualizationTimeAxis` takes a zero-length source interval as its display origin.
It subtracts integer sample positions before converting to seconds, preserving
nearby sample distinctions even above 2⁵³. Choose an origin near the visible region.
Placement retains the exact original interval as well as approximate lower, center
and upper display coordinates. Source clocks, host clocks and wall time remain
different metadata; drawing coordinates never replace them.

`VisualizationSelection` is an original-source interval shared by metric, array
and segmentation adapters. Nonempty intervals use half-open overlap; a zero-length
interval is a cursor that matches support containing that sample. Mismatched
epochs/rates never match. Overlapping measurement windows may all be selected;
selection does not imply independent observations, concatenated audio, or a new
coverage-weighted aggregate. Segmentation selection returns original contributing
segments, not clipped/recomputed coverage.

Exact inspection uses `VisualizationMeasurementID`, which includes the series key
and full support interval, plus the scheduled frame center when available. Scheduled
histories order and search by that frame center: whole-interval CPP/CPPS can emit
many frames with identical dependency support, while preview edge frames can share
their starting sample. Bare `MeasurementResult` histories order by support start,
then end; equal complete supports are ambiguous and rejected. Use the scheduled
export adapter when frame placement is available, because the bare scalar contract
does not carry that placement. A store refuses an ID it no longer contains. Eviction
clears the exact inspected ID while preserving the selected source interval; the
panel can then show the newest remaining overlapping measurement. A series change
clears both selection and inspection, preventing stale-profile results. `select`
clears exact inspection, `inspect` selects the result's support, and `clearSelection`
returns to the newest measurement. `inspect(nil)` clears only exact inspection.
The Previous/Next controls inspect original records in the snapshot's source order,
with scheduled frame centers displayed separately from dependency intervals.

Presentation preferences (`VisualizationPresentation`) are separate from algorithm
configuration. Scale and maximum visible history are renderer preferences for
later plots; the current text inspector retains the full bounded history. Changing
them cannot change the profile, smooth a result or rewrite raw samples.

## States, fixtures and extensions

The host supplies loading, running, paused, interrupted (with reset reason),
insufficient-data, unsupported-metric and failure (with code) states. Status is
textual and does not depend on color. Available historical values can remain
inspectable during pause/interruption, with the current state still visible.
Unavailable numeric values show a reason, source coverage and units. No component
uses a higher-is-better aesthetic score or health interpretation.

`VisualizationPreviewFixture.make` supplies nine deterministic scenarios: valid,
no data, gap, unsupported metric, failure, long label, loading, paused and interrupted.
All use a visibly synthetic profile and contain no microphone initialization,
permissions, private recording, network access or algorithm execution. Named
`#Preview` declarations and fixture injection work independently of capture.
Tests render all scenarios at 350/800-point widths and two Dynamic Type environment
settings on macOS. These are macOS SwiftUI renders at narrow/wide widths; macOS does
not reproduce iOS text scaling or device behavior. Minimum iOS device/simulator
builds establish API availability, not physical performance or iOS accessibility QA.

`VisualizationComponentDescriptor.standardInventory()` lists the metric, waveform,
spectrum, cepstrum, segmentation, profile and diagnostics data families. A descriptor
declares accepted measurement/frame inputs; it does not say every algorithm is
implemented or install a renderer. Hosts can register their own versioned `.custom`
descriptor and SwiftUI view without adding UI types to Core. For example, harmonic
inspection can accept `.h1MinusH2`, `.correctedH1MinusH2` and spectrum/diagnostic frames
when those algorithms become available. No initializer enables optional metrics.

Tests cover scheduled provenance, units/conversions, missing values, large time
offsets, selection, mixed-profile refusal, copy-on-write task transfer, frame bounds,
segmentation, diagnostics, Observation scope and preview construction. The
[performance evidence guide](../Tools/Visualization/README.md) specifies dense-fixture
construction/publication measurements before plotting. Physical evidence remains
deferred under [#74](https://github.com/plx/hdxl-voice-processing/issues/74); #48/#49
retain their software performance/accessibility requirements.

Primary API references: Apple's [Observation guidance](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app),
[named previews](https://developer.apple.com/documentation/swiftui/preview(_:body:)),
and [Swift Charts](https://developer.apple.com/documentation/charts).
