# Contributing

Use Xcode 27.0 (27A266a), Swift 6.4, and Swift 6 language mode. Select Xcode
using `DEVELOPER_DIR` or `xcode-select`. The MVP targets macOS 27 and iOS 27;
older OS compatibility is intentionally outside scope by owner direction.

From a clean checkout:

```sh
bash Tools/verify.sh
bash Tools/build-ios.sh
```

`verify.sh` runs formatting, debug build/tests, the independent core consumer,
and graph/link checks. Tests use Swift Testing. iOS builds do not require signing
or a microphone. CI in issue #19 will run these same commands, add optimized
and sanitizer tests, and record the exact selected SDKs.

Format with `bash Tools/format.sh --write`; check with `--check`. The formatter
is the `swift-format` bundled with the declared Xcode, configured by `.swift-format`.
Only Git-visible Swift files are formatted, excluding build products and dependencies.

Keep each implementation PR tied to one leaf roadmap issue with `Closes #N`.
Describe behavior, verification, numerical/profile impact, and known limitations.
Run local `codex review --base origin/main` and request the GitHub Codex reviewer.
Address findings for at most three review cycles; track remaining findings in
the follow-up epic. Merge only with passing applicable checks.

Do not commit private recordings, signing assets, credentials, generated build
output, or machine-specific paths. Add numerical reference/provenance evidence
when implementing algorithms. Physical-device evidence is deferred to #74;
simulator and compile results must retain their actual labels.

Dependency and fixture changes follow [the provenance policy](Documentation/ProvenancePolicy.md).
Update `Configuration/provenance.json` and `THIRD_PARTY_NOTICES.md` in the same PR.
`verify.sh` checks hashes, permissions metadata, lockfile identities, provenance
failure cases, and the consumer under a network-denied runtime sandbox.
The project license is pending owner decision #78; publication checks fail until
that decision and the corresponding license file are recorded.
