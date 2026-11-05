# Contributing

Use Xcode 27.0 (27A266a), Swift 6.4, and Swift 6 language mode. Select Xcode
using `DEVELOPER_DIR` or `xcode-select`. The MVP targets macOS 27 and iOS 27;
older OS compatibility is intentionally outside scope by owner direction.

From a clean checkout:

```sh
bash Tools/verify.sh
python3 Tools/ci.py release
python3 Tools/ci.py address
python3 Tools/ci.py thread
python3 Tools/ci.py ios-simulator
python3 Tools/ci.py ios-device
```

Address/thread lanes run the complete suite with optimized sanitizer instrumentation
and a bounded fault-detection capability control. Debug and ordinary release checks
remain separate.

`verify.sh` runs formatting, debug build/tests, the independent core consumer,
and graph/link checks. Use CPython 3.14.8 for the verification scripts. Tests use
Swift Testing. iOS builds do not require signing or a microphone. CI runs these
same commands and records exact toolchain/SDK/destination and results in
`.build/ci-artifacts/<lane>/`. `bash Tools/check-workflows.sh` checks workflow syntax
with a checksum-pinned actionlint download (macOS arm64, network required).
See [CI coverage and artifacts](Documentation/ContinuousIntegration.md) for the
fast versus extended lanes, sanitizer limits, and artifact privacy policy.

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

Benchmark smoke checks are isolated from runtime consumers:

```sh
python3 Tools/benchmark.py timing
python3 Tools/benchmark.py allocation
```

These also run in a separate CI job. See [the benchmark guide](Benchmarks/README.md)
for backend capabilities, export interpretation, filtering, and local baselines.
Diagnostic timing is affected by instrumentation; use timing mode for timing work.

Dependency and fixture changes follow [the provenance policy](Documentation/ProvenancePolicy.md).
Update `Configuration/provenance.json` and `THIRD_PARTY_NOTICES.md` in the same PR.
`verify.sh` checks hashes, permissions metadata, lockfile identities, provenance
failure cases, and the consumer under a network-denied runtime sandbox.
The project license is pending owner decision #78; publication checks fail until
that decision and the corresponding license file are recorded.

Worker instrumentation changes also run `python3 Tools/instrumentation.py` and
`python3 Tools/instrumentation.py --compiled-out`. For actual local trace evidence,
use the commands in [Instrumentation](Documentation/Instrumentation.md); keep raw
Instruments traces local and share only the approved summaries.
