# Licensed voice corpus evidence

Issue #27, checked 2026-11-04 on macOS 27.0.1, Xcode 27.0 (27A266a),
Swift 6.4.0.34.1, CPython 3.14.8, Mac13,1. This is host engineering evidence;
physical capture and qualified listener expansion remain #74/#102.

## Source and reproducibility

Three publisher-pinned PVQD v3 originals were acquired independently from the
public file endpoints and checked against the publisher's sizes/SHA-256. The
optional acquisition command was then exercised independently with the same pins.
The CC BY 4.0 grant, attribution/modification terms, and public-use consent methods
are linked in [the corpus guide](../VoiceCorpus.md) and the repository notices.
Actual file parsing confirms mono 44.1 kHz PCM16, rather than relying on a paper's
general sample-format description. Original byte identities are:

| Source | SHA-256 |
| --- | --- |
| `pvqd3-bl01` | `c98e50f90453ec26cfe2e61acaf7a166848bfbbb2f4788c6e2f49281cee37e62` |
| `pvqd3-bl02` | `a1603f9d04b9c004b4f886c6eee8397d530c8f6a79eea2962f7b096f533b2b3b` |
| `pvqd3-bl03` | `989a72597e06da51d6da550812ebcd9f757bb5c1df98e5551015c5cd1ea9206c` |

The committed corpus manifest SHA-256 is
`189aa4b7da5b01a7ed7e971e26aca9591c106c47b00fa29e859e79414fd83fd4`.
It records both generator source hashes, all 24 audio artifact hashes, source
sample support, each transform's input/output identity, raw PCM hashes, typed
decoder expectations and complete coverage. Every transformation regenerates
byte-for-byte offline. Acquisition is opt-in and checks integrity before writing a
source file; a changed-byte failure test verifies rejection.

Twelve project-selected excerpts cover the four declared tasks in three sources.
Nine explicit simulations exercise low-level quantization, seeded noise, clipping,
zero-fill dropout/silence, stereo, empty input, truncation and a nonfinite sample.
There are 17 decodable and four negative inputs; all 21 remain in coverage. Task
annotations are provisional project annotations, not clinically verified labels.

## Validation

Six native tests independently check all source/artifact hashes and PCM digests,
exact original-to-excerpt sample slices, declared statistics/outcomes, malformed
headers, and whole versus irregular chunk levels for all twelve natural excerpts.
The sixth test activates the separate performance procedure only when requested.
Sixteen Python corpus/benchmark tests include meaningful failure injection for
licenses/consent, private annotation fields, duplicate IDs/paths, bounds, rates,
durations, transformation identities, lost negative coverage, unsupported/invalid
PCM, traversal/symlinks, source integrity, candidate overwrites, incomplete timing
records, false continuity/analysis claims and unconsumed output.

All six final local correctness lanes passed: 110 Swift xUnit cases each in debug,
release, Address Sanitizer and Thread Sanitizer, plus both iOS compile/link destinations.
Debug also passed all 116 Python tests, 110 provenance records, existing external/synthetic
offline fixture checks, formatting, independent consumer, dependency/link checks and
network-denied consumer execution. Pinned workflow syntax validation passed. The
fresh corpus benchmark passed all four subsets and all raw-trial output checks.
Hosted CI artifacts and both Codex review results are audited on the PR before merge.

## Loading and decoding

The benchmark reports warm-cache native file loading separately from preloaded
RIFF validation and owned PCM16-to-Float64 decoding. It verifies every input hash,
expected rejection, decoded count and complete-output energy checksum. Ten trials
per operation/subset retain raw values; nearest-rank quantiles are observations,
not tail-latency guarantees. Compilation, acquisition, transformation, hashing and
checksum consumption are outside the timed operation.

| Stable subset | Decoded samples | Input file bytes | Decoded payload bytes |
| --- | ---: | ---: | ---: |
| `corpus-smoke/v1` | 176,400 | 352,888 | 1,411,200 |
| `corpus-batch/v1` | 1,142,190 | 2,284,908 | 9,137,520 |
| `corpus-difficult/v1` | 441,000 | 1,764,389 | 3,528,000 |
| `corpus-long-stream/v1` | 2,646,000 | 5,292,044 | 21,168,000 |

The difficult subset includes the file bytes and outcomes of all four rejections;
decoded-sample counts intentionally exclude rejected payloads. Payload bytes are
not peak memory or allocator counts. Those quantities are explicitly unavailable
in this native test process. Long-stream preparation records 29 artificial joins;
it is 30 repetitions of a two-second excerpt, not continuous natural speech.
`FixtureLoad` and `FixtureDecode` signposts carry only process-local numeric metadata.
No frame/hop or DSP throughput is inferred from these file-handling measurements.

## Local timing observations

These pre-commit working-tree measurements retain exact generator, decoder and test
source hashes in the report. They do not assert a clean committed checkout; hosted
CI supplies that separate evidence before merge. Values below are median milliseconds.

| Subset | Load ms | Decode ms | Trials each |
| --- | ---: | ---: | ---: |
| `corpus-batch/v1` | 0.599541 | 5.970375 | 10 |
| `corpus-difficult/v1` | 0.476583 | 2.341625 | 10 |
| `corpus-long-stream/v1` | 0.919083 | 13.706166 | 10 |
| `corpus-smoke/v1` | 0.079000 | 0.912958 | 10 |

Full local report SHA-256: `ea8ec1697772f6fd1739da6e8ea90171dc6eca40bf5994ce06585f7c538692e2`.
The report retains every raw load/decode observation and all ten output-consumption
checksums per subset; timings are not cross-machine pass thresholds.
