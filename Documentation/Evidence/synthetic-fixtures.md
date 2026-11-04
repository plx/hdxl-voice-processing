# Independent synthetic fixture evidence (#22)

Observed 2026-11-04 on Mac13,1 arm64, macOS 27.0, Xcode 27.0 / Swift 6.4,
CPython 3.14.8. This is host synthesis and fixture-validation evidence, not a
production DSP performance or physical-device claim. Device evidence remains #74.

- Generator identity: `374db54ac8271ed4ca877cb965487ccc398f37eaf0567b571b47469191770089`.
- Catalog identity: `4a774c2f7e05a197641b6a7e67ef0f87398884eae1c6d6d4a6d0ea58082268b5`.
- 34 PCM cases, 10 sequence cases, 8 algebra cases, all 18 algorithm groups mapped.
- 71 committed artifacts, 810,253 bytes total; original-only, test-bundle resources.
- 64 Python tests; full debug lane passed (37 xUnit cases, including 6 new Swift
  tests). Offline candidate regeneration, 81-asset provenance inventory, package
  graph, independent consumer, network-denied consumer, and actionlint passed.
- Native optimized validation: ten preloaded catalog decode/contract/selection/PCM
  hash passes with detailed bounded `referenceValidation` signposts. Median
  4.6143 ms, range 4.3634–4.8973 ms.
  No audited allocation count; frame/hop inapplicable to this validation operation.

## Full generator matrix

Each row has three no-file-write generation trials. A separate preparation pass
wrote all 24 inputs, then independently rehashed every WAVE file. All prepared
identities and PCM hashes matched the generation records. Largest input: 14,400,000
samples (300 seconds at 48 kHz); no duration-sized sample array is needed. The
four-harmonic source uses amplitudes 0.125, 0.0625, 0.03125, 0.015625 at orders
1/2/3/5, phase zero, no filter, gain one, no clipping, binary64. Synthesis blocks
are 4,096 samples; suggested future analysis frames/hops are 40/10 ms.

Render time excludes setup, packing/hashing and writes. Full-block p95 is the median
of each trial's nearest-rank p95; shorter final blocks are separately recorded.
Throughput below divides source samples by render time only. These numbers establish
measurement boundaries and repeatability; no performance threshold is asserted.

| Seconds | Rate | F0 | Median setup ms | Median render ms | Full-block p95 ms | Msamples/s |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 16000 | 50 | 2.177 | 5.818 | 1.515 | 2.750 |
| 1 | 16000 | 600 | 0.569 | 5.716 | 1.476 | 2.799 |
| 1 | 44100 | 50 | 6.167 | 16.121 | 1.552 | 2.736 |
| 1 | 44100 | 600 | 1.072 | 16.002 | 1.559 | 2.756 |
| 1 | 48000 | 50 | 6.426 | 17.692 | 1.611 | 2.713 |
| 1 | 48000 | 600 | 0.612 | 17.435 | 1.538 | 2.753 |
| 10 | 16000 | 50 | 2.145 | 58.622 | 1.594 | 2.729 |
| 10 | 16000 | 600 | 0.603 | 57.812 | 1.591 | 2.768 |
| 10 | 44100 | 50 | 6.202 | 162.817 | 1.612 | 2.709 |
| 10 | 44100 | 600 | 1.090 | 161.237 | 1.599 | 2.735 |
| 10 | 48000 | 50 | 6.471 | 178.003 | 1.628 | 2.697 |
| 10 | 48000 | 600 | 0.601 | 173.218 | 1.584 | 2.771 |
| 60 | 16000 | 50 | 2.133 | 354.647 | 1.627 | 2.707 |
| 60 | 16000 | 600 | 0.589 | 346.382 | 1.572 | 2.772 |
| 60 | 44100 | 50 | 6.148 | 975.719 | 1.607 | 2.712 |
| 60 | 44100 | 600 | 1.076 | 955.506 | 1.570 | 2.769 |
| 60 | 48000 | 50 | 6.389 | 1062.234 | 1.610 | 2.711 |
| 60 | 48000 | 600 | 0.603 | 1042.389 | 1.575 | 2.763 |
| 300 | 16000 | 50 | 2.158 | 1761.811 | 1.600 | 2.724 |
| 300 | 16000 | 600 | 0.610 | 1737.111 | 1.578 | 2.763 |
| 300 | 44100 | 50 | 5.928 | 4886.424 | 1.617 | 2.708 |
| 300 | 44100 | 600 | 1.105 | 4783.125 | 1.584 | 2.766 |
| 300 | 48000 | 50 | 6.490 | 5319.386 | 1.619 | 2.707 |
| 300 | 48000 | 600 | 0.612 | 5209.123 | 1.582 | 2.764 |

Raw local reports are in ignored `.build/synthetic-generation-final` and
`.build/synthetic-prepared-final`. Reproduce with the commands in
[the tool guide](../../Tools/Synthetic/README.md). The dedicated `Synthetic fixtures`
workflow repeats the full matrix and native validation, uploads JSON/logs for
review, and omits long WAV assets. Hosted evidence will be checked before merge.

Decisions about accepted-sequence normalization, pole-model interpretation,
component SNR, and the 300-second / 50–600 Hz stress range are recorded in #89.
Production estimator comparisons remain requirements of their original leaves.
