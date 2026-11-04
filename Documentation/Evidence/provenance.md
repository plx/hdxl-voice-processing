# Provenance evidence

Issue #16, checked 2026-11-04 on macOS 27.0.1 with Xcode 27.0 (27A266a),
Swift 6.4, and CPython 3.14.8. No runtime Swift implementation or package graph
changes were needed for this issue.

- `python3 Tools/verify-provenance.py`: passes for both existing fixture artifacts,
  their exact generator source hash, dependency records, and the empty external
  runtime/model inventories.
- `python3 -m unittest discover -s Tools/Tests -p 'test_*.py'`: sixteen tests pass,
  including deliberately changed/missing provenance, unlisted audio, license/consent
  violations, path traversal, duplicates, dependency source/revision drift, fixture
  removal before staging, mandatory generator records/resolved pins, symlink
  rejection (including discovery of broken links), standard audio extensions,
  Git-visible license/notice files, and independent golden reproduction.
- `swift test` through `Tools/verify.sh`: all twenty Swift tests pass.
- The Python generator's candidate files compare byte-for-byte with both committed
  contract fixtures. No expected outputs or profile identities were changed.
- `bash Tools/verify-offline.sh`: the independent core consumer runs under a macOS
  sandbox denying all network access and restores an insufficient-data result.
- `python3 Tools/verify-provenance.py --for-publication`: intentionally fails with
  the unresolved owner license decision #78. This is a verified publication gate,
  not a development-test failure or a claim that release is authorized.

IVoice's archive was downloaded into ignored scratch storage and inspected without
execution or vendoring. Its root MIT license names Iman Noferesti (2025); bundled
font/tool notices are distinct. Archive SHA-256:
`b72be0624623971e3a9af21698f6cdf76b009c8a764329a897fff43aa286e4dc`.
Praat and Parselmouth license descriptions were checked against their primary
sources. Selected release files and transitive licenses must be checked again when
the planned benchmark/reference environments are activated in #17/#26.
