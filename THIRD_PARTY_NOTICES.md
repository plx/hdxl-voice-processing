# Dependency and source notices

This is an inventory index, not a new license grant or a legal compatibility
determination. Exact versions, uses, and hashes are recorded in
[`Configuration/provenance.json`](Configuration/provenance.json). No third-party
implementation source, binary, recording, model, font, or image is currently vendored.

The project's own license is **pending owner decision in
[#78](https://github.com/plx/hdxl-voice-processing/issues/78)**. Original source and
generated contract fixtures are not represented as licensed for redistribution while
that decision is pending. Public visibility alone is not a license grant. Actual
distribution is gated by `python3 Tools/verify-provenance.py --for-publication`.

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
| Praat 7.0.02 | Pinned external development CLI in `Tools/Reference` and the `Tools/Framing` Gaussian oracle; never vendored or linked into products | [Distributed application's GPL-3.0-or-later](https://praat.org/manual/License.html) and [component notices](https://praat.org/manual/Acknowledgments.html) |
| IVoice | Design context only; no code, assets, or thresholds copied | Root `IVoice-Source/LICENSE`: MIT, copyright 2025 Iman Noferesti, in the [archive](https://tintin.cs.uiowa.edu/Pages/Software/IVoice/Documents/IVoice-Source.zip); bundled assets/tools have separate notices |

The inspected IVoice archive SHA-256 is
`b72be0624623971e3a9af21698f6cdf76b009c8a764329a897fff43aa286e4dc`.
Its root MIT notice does not relicense every bundled item. No archive content is
redistributed here. Praat's own source and its complete distribution also have
distinct license considerations; review the exact selected release and its notices.

There are no external SwiftPM consumer dependencies or optional pretrained models.
Papers and algorithm descriptions are cited as methods; a citation does not grant
rights to their text, figures, recordings, or source. Original implementations of
mathematics are recorded separately from copied/modified third-party code, which
must retain applicable licenses, attribution, exact origin, and modification records.
