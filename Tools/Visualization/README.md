# Visualization adapter evidence

Run from the root with the pinned toolchain:

```sh
python3 Tools/Visualization/benchmark.py --output .build/visualization-evidence
```

The output directory must be new. The runner builds the independent
`Examples/VisualizationConsumer` in release mode, verifies the configured
Xcode/Swift/SDK/host/Python versions and records source SHA-256 values before/after
measurement. Five fresh processes each run eight workloads. Input construction,
profile preparation and three warmups per workload are excluded from timings.

| Phase | Workload | Timed operations per process |
| --- | --- | --- |
| Metric construction | 128 and 4,096 prebuilt scalar results; one unavailable per 257; large absolute source positions | 100 complete snapshot validations, including ordering/series and metadata bounds |
| Publication with observer | Alternating two prebuilt overlapping histories of the same sizes | 1,000 main-actor replacements, one rearmed Observation subscriber, retained exact inspection and result consumption |
| Owned waveform construction | 4,096 and 262,144 synthetic `Double` samples | 100 frame constructions, including finite-array validation and typed axes; Swift COW sharing is allowed |
| Validated frame adaptation | The same sizes, already validated as Core intermediates | 100 wrappers retaining the original owned buffer, support, profile and axes |

Publication consumes genuinely changed snapshots; publishing the same snapshot
would let Observation suppress notifications and would not measure delivery. Each
update must notify its one subscriber. The observer runs synchronously and does not
render a SwiftUI view. Construction consumes every returned count and checks exact
source/array endpoints. This is a synthetic adapter baseline, not a DSP, plot-frame,
audio-callback, allocator, device-energy or end-to-end latency benchmark.

The native report records DispatchTime uptime durations, minimum/upper median/
nearest-rank p95/maximum, counts, warmups and observed notifications. Python checks
the complete process/workload population, integer finite/nonzero ordered timing,
expected result consumption and exact observer counts. Eleven negative controls
verify rejection of missing/duplicate work, corrupt timing/counts, wrong scope,
profile drift and extra fields. `result.json` includes raw process reports and the
median/minimum/maximum of the five process medians. No shared-runner wall-time
threshold is imposed; timings provide evidence for the later plotting budget.

The `Visualization evidence` workflow also runs the adapter/Observation tests and
retains 36 synthetic macOS SwiftUI PNGs: nine states, two widths and two requested
Dynamic Type settings. These renders are not iOS or physical-device evidence.
Full correctness and sanitizer lanes run the same tests with the complete suite;
generic iOS device/simulator builds check all three products and both independent
Core/Audio consumers. Artifact output contains synthetic fixtures and tool/source
metadata only, with account paths redacted in captured logs.
