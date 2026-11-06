# Personal target evidence

Local development evidence on 2026-11-06 used Mac13,1, arm64, macOS 27.0.1
(26A434), Xcode 27.0 (27A266a), Swift 6.4.0.34.1 and Python 3.14.8. It was collected
from the implementation working tree before its commit; hosted PR artifacts bind
their own final tested commit/tree. Physical-device and human-listening evidence
are not part of these results.

## Exact-profile gate

The tested full schedule identity is
`c9fbb8420ee5ac5f76254129d42d10358dd393f868a5173ee7dea45e0ce9b01b`:
16 kHz Float64 mono, whole-interval Praat 7 Murton CPPS, FFT YIN at 50–700 Hz,
and unweighted compensated 400-sample/160-hop level windows. This does not validate
streaming-preview CPPS or another configuration.

Four complete synthetic PCM recordings and ten boundary prefixes cover empty,
short, exact-window, first-full-F0 and CPPS-hop boundaries. Eight valid-length inputs
retain actual pinned Praat 7.0.02 raw output and manifests. F0 expectations come from
the independent scalar Python YIN oracle, and level expectations from `math.fsum`
of original PCM windows. Positive short CPPS input returns typed unavailability;
those cases are boundary-contract checks, not external short-input scalar references.

| Metric | Independent reference cases | Chunk comparisons | Boundary cases | Maximum error / budget |
| --- | ---: | ---: | ---: | ---: |
| CPPS | 8 | 42 | 10 | 0.000020514 |
| Raw F0 | 14 | 42 | 10 | 0.000000000256 |
| Unweighted dBFS | 14 | 42 | 10 | 0.000035528 |

Absolute budgets are `1e-4 dB`, `0.001 Hz`, and `1e-10 dB`, respectively. All three
alternate chunk layouts preserve complete frame values and metadata exactly,
including one-sample chunks and acquisition positions beyond `2^54`. The tests
also compare selected-interval medians and repeated-finish behavior. Test failure
prevents publishing a passing native report. The evidence runner independently
checks complete denominators, profile/implementation identities and unchanged budgets
before constructing receipts for the fitter.

## Fitting and evaluation

Nine fabricated numerical scenarios exercise separated/inverted/overlapping labels,
usual values on both sides, an outlier, failed holdout separation, out-of-range
holdouts, and pitch/recording-level confounds. Python independently computes exact
whole-recording split identities, empirical quartiles, interval bounds, directions,
predictions and confusion counts. Wilson endpoints are calculated by numerically
inverting the score inequality rather than using the native algebraic expression.
These labels are synthetic software inputs, not personal preference evidence.

The separate public-API example imports bounded analysis records, freezes training
candidates, evaluates both holdout roles and exports datasets/splits/fits/evaluations
and activated models. Twenty fresh Release processes verified 180 scenarios and
fifty 512-take/32-session fits and evaluations. Eleven corruption controls rejected
changed profiles, missing cases/chunks, failed numerical budgets, invented available
frames, physical-evidence claims, reduced capacity, missing timing, altered fits,
erased confounds and changed split seeds.

The maximum-count dataset encodes 1,791,576 bytes. Its synthetic takes have distinct
acquisition/content identities. This measures the maximum record count, not a
maximum-16-MiB-metadata dataset. Each resulting model encodes to 3,411 bytes, below
the explicit 64 KiB cap. Repeated passes retain the same model identity.

| Fresh-process workload | Median fitting time per pass | Median evaluation time per pass | Median peak RSS |
| --- | ---: | ---: | ---: |
| One maximum-count pass | 0.34244 s | 0.40920 s | 45,334,528 bytes |
| Four maximum-count passes | 0.34670 s | 0.41582 s | 47,685,632 bytes |

Each group has ten independent process launches. For the four-pass group, timing
distributions use each process's median pass. Fitting/evaluation include validation,
hashing, grouping and report construction; input creation/import and output writes
are outside these two intervals. RSS is a process high-water mark including the
runtime, nine small scenarios, prepared inputs and report serialization. The median
increase is 2,351,104 bytes, within the predeclared 32 MiB host smoke allowance.
This does not establish callback allocation behavior, a hard device-memory ceiling,
causal feedback latency or useful real-world voice judgments.

## Reproduction and identities

Run `python3 Tools/PersonalTargets/evidence.py --output .build/personal-target-evidence`
from a clean checkout with the declared toolchain. The dedicated CI job retains
synthetic JSON, source maps, raw timings, corruption outcomes, redacted logs and
the profile xUnit report. It does not upload private recordings or require Praat
at runtime. Independent-reference regeneration is a separate explicit operation.

Local development receipt identities:

| Artifact | SHA-256 |
| --- | --- |
| Exact-profile fixture | `edb00cfac6cf03010e14a36e5441f8d21f4b27825b0529ba450d5b42eece02a0` |
| Independent fitting fixture | `3f9d8a299237c3f520b44d9710231e7c6e468eb3f46942ba67fb18b30d2d6d99` |
| Core source map | `67829e7c2e53ce1d682240f10c76c215fdb38d598dcf354f8de5636c0551d4ba` |
| Native profile report | `eed32275b1bc0415c75d4ae67ee9927bc56da84ee86f59d1e0e78a28391d3cf3` |
| Checked receipt envelope | `69429543783be8bf2733bd102bc1c805ea1f4b801aec1381d40050413dca87b0` |
| Aggregate evidence result | `d202ab988f84946a53d7713233236f5be160e3a1af46bf4d008f4c1c3014b17f` |

The full correctness, sanitizer, iOS build and two review paths remain separate PR
merge gates. Policy review is tracked in [#128](https://github.com/plx/hdxl-voice-processing/issues/128),
with eventual real-session/physical measurements in
[#74](https://github.com/plx/hdxl-voice-processing/issues/74) and
[#102](https://github.com/plx/hdxl-voice-processing/issues/102).
