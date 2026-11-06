# Calibration workflow evidence

Local development validation on 2026-11-06 used Mac13,1, arm64, macOS 27.0.1
(26A434), Xcode 27.0 (27A266a), Swift 6.4.0.34.1 and Python 3.14.8. The local
evidence was collected from the implementation working tree before its commit;
hosted PR artifacts identify the final tested commit/tree.

## Reproducible workflow

The [separate public-API example](../../Examples/CalibrationWorkflow/README.md) uses
16 original generated PCM16 recordings across two sessions. It preserves four task
categories, contradictory/other/uncertain labels, actual acquisition metadata,
source intervals, explicit exclusions and complete executable profile provenance.
Labels are scripted, not human listening-study observations. The example completes
the labeling transaction before analysis and produces no fitted target or score.

Independent Python checks confirmed seven fitting recordings, five within-session
evaluation recordings and four complete later-session evaluation recordings. The
validator independently recomputes the SHA-256 seeded assignments and integer-PCM
RMS/dBFS windows and quantiles. It verifies actual file/profile/cache identities,
raw pitch against the generated fundamental, unique source coverage, complete
recording denominators, the presenter projection and separate session comparisons.

The full fixture profile is `shared-pcm-analysis-schedule/v1`, SHA-256
`5bf396a88af81ad37a14cddb4451cb0def196f1d9384b22c720227d8e835a7df`.
The 32-session/512-take import stress encodes 1,895,560 bytes with dataset SHA-256
`3343897e8d01ef94083adbff26fa1c23e43ab2822ec8bad60bb599824dd31a9b`.
Stress takes alias the 16 original recordings and are never represented as
independent statistical observations or used for fitting.

## Time and memory

`Tools/Calibration/evidence.py` ran 20 fresh native Release processes, ten with one
16-recording analysis pass and ten with four passes. Across those processes it
verified 800 fresh file analyses, 320 cache hits and 200 maximum-capacity imports.
Every cache hit rechecked the complete audio bytes and actual decoder, decoded zero
PCM and prepared no numerical buffers. Nine deliberately corrupted outputs were
rejected, covering physical-evidence claims, counters, import capacity, split roles,
labels, audio identity, raw quantiles and presenter leakage.

| Fresh-process workload | Median analysis time | Median process peak RSS |
| --- | ---: | ---: |
| 16 recordings / 6.4 source seconds | 0.14129 s | 42,237,952 bytes |
| 64 recordings / 25.6 source seconds | 0.52198 s | 42,663,936 bytes |

The median 16-recording verified-cache pass took about 0.020 s. Median time for one
512-take decode/validation was about 0.156 s. Each pass verified 205,504 file bytes
and decoded 102,400 source frames. The pinned fixture profile's largest reported
prepared buffer count was 286,070 bytes, scalar reservation 1,200,000 bytes, retained
available scalar count 174, file-copy chunk 12,844 bytes and decoder chunk 257 frames.

Analysis timing includes snapshot copying/hashing, decoder preparation, numerical
work, summary construction and validation. Peak RSS includes the earlier import
stress, runtime and system-decoder overhead; it is a cumulative process high-water
mark, not a live DSP-buffer count. A 32 MiB median growth allowance for 16 versus
64 sequential analyses is a host smoke gate for accidental retained state, not a
hard memory ceiling. Numerical/profile scratch, dictionary/object overhead and
opaque codec/FFT allocations are distinguished in the guide. These operations are
offline worker work and do not claim allocation-free capture behavior.

## Correctness coverage

Focused native tests cover strict records and canonical order, exact large source
positions, changed dataset revisions, blinded presenter/controller separation,
relabeling, missing-media exclusions, seeded replay, transitive acquisition/hash
grouping, immutable session holdouts and rejection of forged assignments.

Analysis tests cover raw-unit empirical quantiles, unknown/changed recording
conditions, missing labels/coverage, exact cache identity and bounded collection.
Real-file tests independently check constant PCM RMS/dBFS, actual cache reuse and
invalidation, absent/corrupt/replaced media, source edits during/after snapshotting,
format/range errors, cancellation, resource limits, private snapshot permissions,
nonregular inputs, missing versus excluded audio and isolated batch failures.
Float32/Float64, preview/whole-interval profiles and uneven decoder partitions are
compared, with raw F0 checked against a known synthetic tone. Existing kernel
reference and allocation suites remain separate merge gates.

The dedicated CI job retains synthetic dataset/split/cache JSON, every raw native
report, distributions, corruption-control results, exact source/fixture hashes,
toolchain metadata and redacted command logs. Full correctness, sanitizer, iOS
compile/link, GitHub Codex review and local review results are recorded with the PR.
Physical/device and human evidence remains deferred to [#74](https://github.com/plx/hdxl-voice-processing/issues/74);
policy choices remain reviewable in [#125](https://github.com/plx/hdxl-voice-processing/issues/125).
