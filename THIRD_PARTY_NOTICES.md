# Dependency and source notices

This is an inventory index, not a new license grant or a legal compatibility
determination. Exact versions, uses, and hashes are recorded in
[`Configuration/provenance.json`](Configuration/provenance.json). No third-party
implementation source, binary, model, font, or image is currently vendored. The
licensed PVQD recording subset described below is redistributed as test data.

The project's own license is **pending owner decision in
[#78](https://github.com/plx/hdxl-voice-processing/issues/78)**. Original source and
generated contract fixtures are not represented as licensed for redistribution while
that decision is pending. Public visibility alone is not a license grant. Actual
distribution is gated by `python3 Tools/verify-provenance.py --for-publication`.

The 16 PCM files and manifest under
`Tests/HDXLVoiceProcessingTests/Fixtures/Calibration` are original outputs of
`Tools/Calibration/generate.py` version 1. They use integer triangle waveforms,
deterministic noise and artificial gaps, with scripted metadata and labels. They
contain no human voice, participant information or listening-study evidence and
inherit the pending project-license decision. Exact generator/artifact hashes and
the example's executable analysis-profile identity are in the provenance inventory.

| Component | Use and current status | Upstream terms/evidence |
| --- | --- | --- |
| Xcode 27.0 / SDKs 27.0 / Swift 6.4 | System toolchain/frameworks, not vendored | [Xcode and Apple SDKs agreement](https://developer.apple.com/support/terms/) and notices distributed with the tools |
| CPython 3.14.8 | Development-only scripts, not a runtime dependency | [Python license](https://docs.python.org/3.14/license.html), PSF-2.0 and included notices |
| actions/checkout, setup-python, upload-artifact | Revision-pinned CI actions, executed by GitHub; not vendored or linked to products | MIT; exact release license URLs in the provenance manifest |
| rhysd/actionlint 1.7.12 | Checksum-pinned workflow syntax validator, downloaded for development/CI only | [MIT](https://github.com/rhysd/actionlint/blob/v1.7.12/LICENSE.txt); binary not redistributed |
| ordo-one/benchmark 1.38.0 | Isolated development benchmark package; not linked by runtime consumers | [Apache-2.0](https://github.com/ordo-one/benchmark/blob/1.38.0/LICENSE) |
| malloc-interposer 1.6.1 | Optional allocation diagnostic backend in the benchmark package only | Apache-2.0; retains upstream [SwiftNIO-derived machinery notice](https://github.com/ordo-one/malloc-interposer/blob/1.6.1/NOTICE) |
| swift-argument-parser, swift-atomics, swift-numerics, swift-system | Transitive development benchmark dependencies | Apache-2.0 with Swift Runtime Library Exception; exact selected license files and hashes in the manifest |
| hdrhistogram-swift, TextTable | Transitive development benchmark reporting dependencies | Apache-2.0 and MIT respectively; exact revisions and license hashes in the manifest |
| Praat 7.0.02 | Pinned external development CLI in `Tools/Reference`, the `Tools/Framing` Gaussian oracle, `Tools/Cepstrum` stage references, `Tools/CPP` peak/fit references, `Tools/CPPS` smoothing/aggregation references, and `Tools/Masks` speech-activity references; never vendored or linked into products | [Distributed application's GPL-3.0-or-later](https://praat.org/manual/License.html) and [component notices](https://praat.org/manual/Acknowledgments.html) |
| IVoice | Design context only; no code, assets, or thresholds copied | Root `IVoice-Source/LICENSE`: MIT, copyright 2025 Iman Noferesti, in the [archive](https://tintin.cs.uiowa.edu/Pages/Software/IVoice/Documents/IVoice-Source.zip); bundled assets/tools have separate notices |
| Brecht De Man, loudness.py | External K-filter coefficient reference in an ignored development cache; math-only compatibility shim, no NumPy/SciPy execution or runtime linkage; source not redistributed | [MIT, copyright 2018 Brecht De Man](https://github.com/BrechtDeMan/loudness.py/blob/dc0f83883d247cbeb106064784e32d8c38ce1573/LICENSE), pinned revision in the manifest |
| Perceptual Voice Qualities Database (PVQD), version 3 | Three original recordings and explicitly modified excerpts in test resources only; not runtime resources | [CC BY 4.0 dataset](https://data.mendeley.com/datasets/9dz247gnyb/3); attribution and modification notice below |

## PVQD recording attribution

Walden, Patrick R. (2020), **Perceptual Voice Qualities Database (PVQD)**,
Mendeley Data, V3, [doi:10.17632/9dz247gnyb.3](https://doi.org/10.17632/9dz247gnyb.3).
The database was supported by The Voice Foundation's Advancing Scientific Voice
Research Grant. Its publisher makes the dataset available under
[Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)
([legal code](https://creativecommons.org/licenses/by/4.0/legalcode.en)). The licensed
material is supplied as-is, without warranties; the license's disclaimer applies.
Neither the contributor nor the foundation endorses this project.

`Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/originals` retains BL01 ENSS.wav,
BL02 ENSS.wav, and BL03 ENSS.wav byte-for-byte under stable file IDs. The `samples`
directory contains **modified** material: sample-indexed excerpts and the declared
gain, noise, zero-fill, channel, empty, truncation, and nonfinite transformations.
The accompanying manifest records every modification, original/derived SHA-256,
and source URL. No additional restriction is imposed on upstream licensed material.
The project code and original manifest/annotation contributions remain subject to
the pending project license decision; they do not replace the recordings' CC BY terms.

`Tests/HDXLVoiceProcessingTests/Fixtures/Cepstrum/speech-*.json` contains further
**modified** representations of eight of those excerpts: resampled and pre-emphasized
frame samples, windowed samples, and spectral/cepstral numerical vectors. These
speech-derived data retain the same CC BY 4.0 attribution and terms. Each file records
its input path/hash, transformation settings, reference-tool identity, and output
hashes; `Configuration/provenance.json` connects it to the original recording and
excerpt transformations. The Praat executable and implementation source are not
included in these numerical fixtures or linked into package products.

`Tests/HDXLVoiceProcessingTests/Fixtures/CPP/speech-*.json` further selects the
documented external power-cepstrum frames and adds peak/background/CPP numerical
queries and residual diagnostics. These **modified** representations retain the same
CC BY 4.0 attribution and consent evidence. Each records its parent numerical-file
path/hash and selected frame; the provenance inventory carries the original recording
and excerpt transformation chain. Independently calculated mathematical fit checks
are identified separately from external reference values.

`Tests/HDXLVoiceProcessingTests/Fixtures/Masks/speech-*.json` contains further
**modified** representations of eight licensed excerpts: selected spectral vectors,
temporal-flatness and relative-intensity features, and operational speech-activity
intervals. These derivatives retain the same CC BY 4.0 attribution and public-use
consent evidence. The provenance inventory preserves their original recording and
excerpt transformations. Detector labels are not independently annotated phonation
or health labels. Original synthetic mask inputs contain no human recording.

The speech-derived files in `Tests/HDXLVoiceProcessingTests/Fixtures/CPPS/` add
**modified** numerical representations: selected original/pretrend/smoothed power
vectors, per-frame CPP/CPPS fits and interval means. They retain the same CC BY 4.0
attribution and consent evidence. Acquired dropout-region slices retain original
positions and the full transformation chain in the provenance inventory. Explicit
unmasked dropout characterization is not represented as numerical parity success.
Constructed CPPS power probes and catalog metadata contain no human recording.

The speech-derived files in `Tests/HDXLVoiceProcessingTests/Fixtures/HNR/` and
`HNRStages/` contain further **modified** representations: half-second prefixes at
the original 44.1 kHz rate, lossless Float64 WAVE transport, external AC/CC HNR
frames, and independent window/correlation/candidate numerical vectors. They
retain the same CC BY 4.0 attribution and consent evidence. The provenance inventory
preserves parent recording/excerpt hashes and the explicit prefix transformation;
there is no additional resampling, private recording, or bundled reference code.

Public-use consent evidence is the dataset author's coauthored
[methods, “Study Design and Participants”](https://pmc.ncbi.nlm.nih.gov/articles/PMC11193840/).
Private consent forms, participant names, and clinical/demographic labels are not
included. See [Voice corpus](Documentation/VoiceCorpus.md) for the annotation
limitations, reproduction commands, and removal procedure.

The inspected IVoice archive SHA-256 is
`b72be0624623971e3a9af21698f6cdf76b009c8a764329a897fff43aa286e4dc`.
Its root MIT notice does not relicense every bundled item. No archive content is
redistributed here. Praat's own source and its complete distribution also have
distinct license considerations; review the exact selected release and its notices.

There are no external SwiftPM consumer dependencies or optional pretrained models.

`Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets/` contains original
synthetic software scenarios and numerical derivatives of the original C01
calibration PCM. The exact-profile fixtures retain pinned Praat 7.0.02 CPPS raw
output and reference identities, plus independently calculated Python F0 and
unweighted level values. The fitting fixtures contain fabricated labels and
summaries, independent quartiles/confusion counts, and numerical inversion of
the Wilson score inequality. They contain no human voice, real listening labels,
copied paper content or upstream implementation. All input, generator, artifact
and profile identities are inventoried in `Configuration/provenance.json`.

Papers and algorithm descriptions are cited as methods; a citation does not grant
rights to their text, figures, recordings, or source. Original implementations of
mathematics are recorded separately from copied/modified third-party code, which
must retain applicable licenses, attribution, exact origin, and modification records.

`Tools/Fourier/oracle.py` is an original direct mathematical DFT implementation.
Its generated numerical vectors are inventoried as original synthetic fixtures;
no external FFT implementation or source is copied into the oracle. The runtime
uses the system Accelerate framework through its public APIs.

`Tools/Levels/reference.py` evaluates the pinned author's K-filter coefficient
function using a minimal math-only compatibility surface, then uses an original
80-digit Decimal direct-form-I cascade to produce synthetic vectors. This is not
an execution of SciPy or a full integrated-loudness conformance result. The native
K design independently reconstructs the ITU-R BS.1770-5 tables by inverse bilinear
transformation and stage-specific prewarping; no external implementation is copied
into the Swift package. The author reference is associated with Brecht De Man,
“Evaluation of Implementations of the EBU R128 Loudness Measurement,” AES 145, 2018.
