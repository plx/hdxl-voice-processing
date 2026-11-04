# Synthetic instrumentation evidence

Collected 2026-11-04 on an arm64 Mac Studio, macOS 27.0.1 (26A434), Xcode 27.0
(27A266a), Swift 6.4, Python 3.14.8. Commands and semantics are in
[Instrumentation](../Instrumentation.md). These are working-tree bring-up
measurements; the PR's clean CI build supplies the committed-code cross-check.
No production DSP, live capture, device energy, or sustained performance claim is
made.

The system and compile-time-disabled release probes each completed 32 trials
(eight per mode) of 10,000 synthetic frames. Every result matched independently
computed checksum `ede5395b22cea917`. Both modes passed the callback assembly
audit: 16 arm64 instructions, no calls, allocation, locks, or backward branches.
Swift tests cover callback counters and saturation. This is evidence about the
provided counter primitive, not a claim about a future full capture callback.

An actual Logging-template Instruments recording of the synthetic two-worker
probe was exported and checked:

- 64 AnalysisFrame intervals and 64 FFT-labeled intervals, all paired.
- Two overlapping session identities, each with 32 frames, and epochs 0 and 1.
- Two each of initialization, error, cancellation, reset, overrun, route-change,
  and configuration-change events; 64 worker-side handoff observations.
- No unmatched interval, unapproved metadata field, or lost failure frame/reason.
- Local XML export SHA256:
  `f54a259045824805aaebef8529712c524150dbbeff1846b7e8571c47c17410f9`.

A separate Instruments recording measured the same overhead workload:

| Mode | Median ns/frame | Min–max ns/frame | Median paired overhead vs bare (ns) |
| --- | ---: | ---: | ---: |
| Bare workload | 23.35 | 22.52–24.01 | 0.00 |
| Disabled facade | 25.86 | 24.93–28.23 | 2.42 |
| Sampled, every 16th frame | 412.07 | 397.05–448.94 | 388.83 |
| Detailed | 5,564.78 | 5,414.92–5,625.45 | 5,541.64 |

Disabled cost is measured and nonzero. The tiny integer workload makes diagnostic
cost prominent; these values are not predictions for CPPS or a production audio
pipeline. Raw trial distributions, summaries and environment records are retained
locally under `.build/instrumentation-artifacts/`; raw Instruments files stay in
private subdirectories because they contain machine metadata. CI retains the
repeatable system/fallback probes without a noisy timing gate. Production traces
and integrated overhead will be revisited under #56/#62.

The local debug lane passed 27 Swift tests across the two test bundles and 31
Python evidence/provenance tests. Consumer graph, network-denied execution,
formatting, and pinned actionlint checks passed. Trace-parser regression tests
include localized large-integer displays: validation uses typed raw arguments
instead of presentation strings. Follow-up #84 records owner review of the
sampling, budget, and profile-token policy after production integration.
