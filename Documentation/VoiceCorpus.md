# Licensed voice corpus

Issue #27 provides a small offline engineering corpus for numerical regression and
benchmark input. It is not a representative clinical cohort, a diagnostic dataset,
or a set of authoritative voiced-region labels. The version is
`pvqd3-engineering/v1`; its manifest is
`Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/manifest.json`.

## Source and permission

The corpus pins [PVQD version 3](https://data.mendeley.com/datasets/9dz247gnyb/3),
the version named by the roadmap. Version 4 exists; adopting it requires an explicit
corpus revision. Patrick R. Walden publishes version 3 under CC BY 4.0. Full
attribution, license links, the disclaimer, and modification notices are in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Public availability alone is
not the permission basis: the license grant and the dataset author's coauthored
[public-use consent statement](https://pmc.ncbi.nlm.nih.gov/articles/PMC11193840/)
are separately recorded. No private consent forms are copied.

The first three lexically ordered BL records are pinned by publisher file IDs,
original filenames, byte sizes and SHA-256. The exact originals occupy 8,299,456
bytes; 21 derived files occupy 4,049,297 bytes, plus a small manifest. All actual
original headers declare **mono 44,100 Hz signed PCM16**, despite a later paper's
general description of 32-bit WAV. Parsed bytes determine the sample format.
Every original remains a distinct, immutable reference. None of these files is a
resource of a runtime product; SwiftPM copies them only into the test bundle.

## Tasks, variation, and limitations

Twelve excerpts cover /a/, /i/, an intended all-voiced sentence, and a consonant-rich
sentence from each source. Sentence task labels refer to the CAPE-V elicitation
protocol. They do not assert that every recorded sample is voiced or that the
speaker exactly realized the script. Source task order, on-device Apple SpeechAnalyzer
word-time assistance, and signal-support inspection informed the project-selected
integer boundaries. Speech model revision is not exposed by the system; no speech
model or transcription process is required for reproduction. These are provisional
project annotations, **not a human listening audit or phonetic alignment**.

The recordings provide natural pitch and phonation variation without assigning
diagnoses, demographic labels, or inferred participant identities. Coverage breadth
and qualified listener review are tracked in
[#102](https://github.com/plx/hdxl-voice-processing/issues/102). Primary corpus
metadata records only source IDs, engineering conditions, task provenance and
uncertainty. It does not copy the source's demographic or clinical spreadsheets.

Nine derivatives of the first /a/ excerpt exercise difficult inputs:

| Condition | Exact operation | Developer decoder outcome |
| --- | --- | --- |
| Low level | Integer gain 1/256, rounding toward zero | Available PCM; quantization is explicit |
| Added noise | xorshift32(2701), shifts 13/17/5, modulo 4097 minus 2048 LSB | Available PCM; measured SNR 10.933437212212 dB |
| Clipping | Integer gain 16, saturate at −32768/+32767 | Available PCM with 56,345 rail samples |
| Dropout | Replace samples [22050, 30870) with zero | Available PCM; replacement is not observed silence |
| Silence | Replace the full excerpt with zero | Available zero energy; not a natural recording of silence |
| Stereo | Duplicate the mono channel | `unsupportedRange` pending an explicit channel policy |
| Empty | Well-formed zero-length PCM payload | `insufficientData` |
| Truncated | Remove seven bytes without repairing RIFF length | `invalidInput` |
| Nonfinite | Convert to Float32 and replace sample 123 with qNaN bits 0x7fc00000 | `invalidInput` |

These are **simulated defects**, not assertions about the original capture or the
speakers. Noise SNR uses the entire excerpt's input energy divided by the actual
added error energy after PCM quantization/saturation; no nominal SNR is substituted.
The generator records both exact integer sums of squares and its final random state.
No filtering, resampling, automatic peak normalization, or inferred gap repair occurs.
PCM16 normalization is `sample / 32768`; positive PCM16 rail is below +1, while
negative rail equals −1. Rail counts are file diagnostics, not an acoustic SPL value.

Each transformation records parameters and input/output byte hashes. Source support
uses half-open integer sample intervals. A zero-filled dropout must not be treated
as verified observed silence by a downstream coverage policy. Decoder availability
only describes file applicability; it does not certify validity for a measurement.
The aggregate always includes all 21 files: 17 decodable, two invalid, one empty,
and one unsupported. No accepted-only denominator hides the four negative cases.

## Offline verification and deliberate acquisition

```sh
python3 Tools/Corpus/corpus.py verify
python3 -m unittest discover -s Tools/Tests -p 'test_corpus*.py'
swift test --filter corpus
```

Default correctness CI checks license/consent/attribution, duplicate IDs and paths,
source and derived hashes, actual rates/counts/durations, excerpt bounds, chain
continuity, stable subset membership, all decoder outcomes, and complete coverage.
It regenerates each candidate from the committed originals and compares bytes.
Strict pinned metadata prevents adding unapproved participant fields or labels.
Both the corpus checker and the repository-wide provenance inventory reject
unlisted artifacts and symbolic-link paths. Network access is not used by verify,
generate, prepare, tests, or benchmark execution.

```sh
# Optional: fetch only the three explicitly pinned public files, checking size/hash.
python3 Tools/Corpus/corpus.py acquire --output .build/corpus-acquired
# Or use the committed originals as the source root.
python3 Tools/Corpus/corpus.py generate --root .build/corpus-acquired --output .build/corpus-candidates
python3 Tools/Corpus/corpus.py verify --root .build/corpus-candidates
```

Acquisition is an explicit developer command. It has no credentials, private source,
floating version, or full-dataset download. A changed upstream file fails its pin.
Candidate output must be new or empty and cannot overwrite committed fixtures.
Changes require review of source terms, identities, recipes, numeric differences and
coverage before copying candidates and updating `Configuration/provenance.json`.
The original metadata/recipes are in `Tools/Corpus/corpus_catalog.py`; the manifest
hashes it and `corpus.py` together. Test-only native decoding independently checks
the same file outcomes and normalized Float64 PCM hashes. Real excerpts also run
through native K-weighted levels with whole versus irregular chunks and unchanged
original source indices.

## Stable performance subsets

| ID | Content | Interpretation |
| --- | --- | --- |
| `corpus-smoke/v1` | One vowel and one all-voiced task | Short integration smoke |
| `corpus-batch/v1` | All twelve unmodified excerpts | Representative small batch of the selected material |
| `corpus-difficult/v1` | All nine simulated conditions, including four rejections | Input applicability and negative coverage |
| `corpus-long-stream/v1` | First all-voiced excerpt repeated to exactly 60 seconds | Synthetic transport/load exercise; every two-second join is a continuity boundary |

```sh
python3 Tools/Corpus/corpus.py prepare-long-stream --output .build/corpus-long
python3 Tools/Corpus/benchmark.py --output .build/corpus-evidence
```

Long-stream preparation writes a separate WAV and manifest with all join indices and
exact identities. It does not manufacture a minute of continuous natural speech.
Downstream DSP workloads must honor those boundaries or explicitly define another
synthetic continuity policy. It is never prepared inside a timed analysis loop.

The benchmark records ten raw trials each for warm-cache file reads and separately
for preloaded RIFF validation/owned Float64 decoding. It consumes every decoded
sample outside the timed decode and verifies expected energy and negative outcomes.
Hashes, preparation, compilation and acquisition are excluded. `FixtureLoad` and
`FixtureDecode` worker signposts contain bounded numeric metadata only. No PCM,
transcript, participant string, or full source ID goes into signposts.

Reports retain hardware/OS/compiler/SDK, exact checkout and source identities,
counts, file and decoded payload bytes, raw timings and nearest-rank distributions.
Allocation counts and peak memory are unavailable in this test process; payload
bytes are not a claim about peak RSS. Ten trials do not characterize tail latency.
Frame/hop are explicitly inapplicable because this measures file handling, not DSP.
Physical capture/device feasibility remains deferred to #74. The dedicated corpus
workflow retains metadata and logs, not another uploaded copy of the recordings.

Removal or permission changes follow [ProvenancePolicy.md](ProvenancePolicy.md):
stop using affected IDs, file a scoped removal issue, invalidate dependent references,
review archives/caches and coordinate any history cleanup with the owner.
