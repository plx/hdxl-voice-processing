# Correctness CI

The workflow uses GitHub's standard arm64 `xcode-27` hosted runner, explicitly
selects Xcode 27.0 (27A266a), and installs CPython 3.14.8. Every lane verifies the
Swift compiler build, SDK versions, and macOS 27 minimum against
`Configuration/build.json` before building. Xcode, Python, and action revisions
must be changed deliberately together with their provenance records. The runner
OS image itself is maintained by GitHub, so its exact image/build is recorded on
every run rather than presented as immutable.

The hosted label currently has preview status. GitHub documents its macOS 27 host
in the [runner announcement](https://github.com/actions/runner-images/issues/14404)
and the installed Xcode paths in the
[image inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).
The pinned actionlint predates that label; `.github/actionlint.yaml` recognizes
this one additional hosted label using the validator's custom-label setting.
No self-hosted runner, signing credential, or larger paid runner is provisioned.

## Checks and local reproduction

All six lanes run on PRs and `main`, without path filters that could skip a
correctness case. Each has a 120-minute timeout to retain complete CPPS reference
coverage under debug and sanitizer instrumentation. Strategy fail-fast is off so a
failure still leaves evidence from the other lanes. These are independent jobs:

| Lane / local command | What runs | Evidence scope |
| --- | --- | --- |
| `bash Tools/verify.sh` (`python3 Tools/ci.py debug`) | Format, provenance and gate tests, debug build and all tests, independent consumer, graph/link checks, network-denied consumer run | Native macOS correctness and consumer isolation |
| `python3 Tools/ci.py release` | All tests compiled with optimization | Native macOS optimized correctness; future numerical tests join this suite automatically |
| `python3 Tools/ci.py address` | Optimized Address Sanitizer capability control, then all tests in Release with Address Sanitizer | Native macOS instrumented memory accesses |
| `python3 Tools/ci.py thread` | Optimized Thread Sanitizer capability control, then all tests in Release with Thread Sanitizer | Native macOS exercised concurrency paths |
| `python3 Tools/ci.py ios-simulator` | All three products and independent core consumer, generic iOS Simulator destination, Debug | Compile/link only; no simulator execution or microphone capture claim |
| `python3 Tools/ci.py ios-device` | All three products and independent core consumer, generic iOS destination, Debug, signing disabled | Device-target compile only; no installed app or physical execution claim |

Address/thread lanes use `--configuration release --sanitize <mode>` so the full
scientific corpus remains practical under instrumentation. Every test and numerical
budget stays enabled. Ordinary debug and uninstrumented release lanes remain
separate; optimized sanitizer success does not substitute for either. Environment
artifacts record the actual configuration and sanitizer mode.

Before each sanitizer suite, `Tools/sanitizer-capability.py` compiles an independent
Swift control with `-O` and the same sanitizer. The address control deliberately
reads freed storage; the thread control deliberately races two workers after a
start barrier. These faults execute only in separate development subprocesses,
never in runtime products or the ordinary test process. The expected diagnostic
and configured nonzero exit code are mandatory: an unexpected success, unrelated
crash, unsupported runtime, compilation failure or timeout fails the lane.

Each compiler invocation is limited to 180 seconds and each fault process to
30 seconds; timeout terminates its process group. Each subprocess has a 1 MiB output
budget. Controls use fresh temporary binaries and record source/binary hashes,
exact commands, compiler/environment metadata and fixed probe runtime options.
The probe options do not propagate into the test process. Sanitizer/runtime
injection environment overrides are rejected before the suite. Reports are
`sanitizer-capability.json` and `sanitizer-capability.log` alongside the existing
lane artifacts, with the same redaction and retention policy. They establish
instrumentation availability, not exhaustive detection of every possible bug.

Do not combine address and thread sanitizers in one build. They have separate
scratch directories, as do release and extended runs. Sanitizers currently cover
the host test binary, not the iOS compile lanes, Apple framework internals, or
unexecuted code. Swift concurrency checking complements these runs; a sanitizer
pass is not a proof of real-time safety. Later state/buffer/unsafe interop tests
must enter the normal test suite so both instrumented lanes exercise them.

The weekly and manual `extended` job runs every Swift Testing test up to ten times
in release configuration, stopping a test's repetitions on failure. Reproduce
with `python3 Tools/ci.py extended`. The current suite contains contracts, diagnostics, independent reference fixtures
and analytic primitive checks. Native voice algorithms and audio stress coverage
arrive in their later issues. They should extend this lane when their
runtime warrants separation while retaining representative checks on every PR.
Controlled benchmark/baseline work belongs to #17/#20 and performance epics.
There is no elapsed-time pass threshold here; recorded job/command durations are
for CI cost and suite partition decisions, not performance claims.

Issue #17 adds a separate `benchmark-smoke` job using the same pinned host setup.
It runs `Tools/benchmark.py timing` and `allocation` from the isolated nested
package, verifies exported metric coverage and a positive allocator/ARC control,
and checks the optimized workload checksum. It enforces no timing threshold.
Its JSON/log artifacts come only from `Benchmarks/.build/artifacts/*/run/` and
are retained for 14 days; raw baseline storage and binaries are excluded.

No build output or test result cache is restored. The initial package has no
external Swift dependencies, so a cache adds little value and could obscure
whether a correctness check ran. A later dependency cache must key exact OS,
Xcode/compiler, architecture, configuration/sanitizer, and lockfile identities;
never restore numerical outputs in place of running tests.

## Artifacts and privacy

`Tools/ci.py` writes a fresh `.build/ci-artifacts/<lane>/` for each invocation:

- `environment.json`: source commit/dirty flag, host/SDK/compiler/Python versions,
  runner image identifiers, configuration, sanitizer, destination, evidence scope.
- `result.json`: pass/fail, error when present, ordered commands, exit status and
  duration. Child failure propagates to the workflow; no success from `tee` masking.
- `commands.log` and test `tests*.xml`: combined diagnostics and structured xUnit
  results. A build failure may prevent an xUnit file from being created.

SwiftPM writes Swift Testing results to `tests-swift-testing.xml` (the report
filename is framework-specific). The wrapper validates the reports, records
their test-case counts, and rejects a successful test command with missing/empty
reports or reported failures. Parameterized cases may be grouped under one test
in xUnit; retain the log for individual arguments and repetition details.

The workflow always attempts upload, retains evidence for 14 days, and fails if
no artifacts are present. Only these top-level JSON/log/XML files are selected;
build products, xcresult bundles, audio, test attachments, and source fixture
directories are excluded. Account/checkout paths are redacted. This is not a
general secret detector: tests must not log credentials, private recordings, or
identifying annotations. CI runs only reviewed public/generated fixtures and
does not request microphone access. Do not dump the environment or use shell
tracing with credentials. Downloaded workflow validation tooling is versioned
and SHA-256 checked before execution; temporary downloads are removed afterward.

The workflow uses `pull_request`, read-only repository permissions, and checkout
without persisted credentials. It does not run contributor code with publication
or signing credentials. A PR template requires fixture/profile, compatibility,
benchmark, provenance, consumer, and review evidence.

## Deferred evidence

Physical microphone paths, route/device lifecycle, real-time deadline/allocation
behavior, sustained thermal/energy measurements, watch capability, and device UI
journeys remain unmeasured here. The owner authorized initial bring-up to proceed
with these explicitly deferred to [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
Before making corresponding claims, collect that evidence and adjust thresholds,
implementations, and documented support as needed. Green CI does not close #74.

The benchmark smoke job also runs the independent instrumentation probe in system
and compiled-out configurations. It checks deterministic output, sampling/emission
counts and bounded callback counter assembly, then retains overhead observations
without timing thresholds. Actual Instruments recordings run locally; raw traces
are excluded from hosted artifacts.

## External references

Ordinary debug CI runs `Tools/Reference/verify.py` offline. Swift tests consume the
committed fixtures directly; reference processes are never required by consumers.
The separate `Reference regeneration` workflow runs on reference-related PR changes,
manually and weekly. It checksums/acquires the exact external Praat tool, repeats each
current original-synthetic workload three times, compares committed goldens and
measures release native fixture validation separately. Its artifacts include raw
numeric reference output and manifests for these original synthetic inputs only;
no executable, disk image, personal recording or external corpus is uploaded.
See [reference instructions](../Tools/Reference/README.md) and
[initial evidence](Evidence/references.md). Numerical/identity disagreements fail the
workflow; timing has no machine-independent pass threshold.

Level-related changes also regenerate the pinned MIT coefficient equations and independent
80-digit Decimal K-filter vectors with `Tools/Levels/reference.py acquire` then `verify`.
Only original synthetic numeric fixtures are retained. The separate `Level benchmarks`
workflow runs 100 configurations in timing and allocation modes, checks all measured
distributions and positive allocator controls, and retains its JSON/gzip/log evidence for
14 days. It reports host processing batches; physical capture and device energy remain #74.

## Licensed voice corpus

Debug correctness CI verifies `Tools/Corpus/corpus.py verify` with no network access
or corpus acquisition. It regenerates every derivative from the three small committed
originals, checks licensing/consent/identity metadata, and retains invalid/unsupported
cases in coverage. The native tests decode all source/derived bytes independently,
check exact source excerpts and run real speech through chunk-equivalent levels.

`Licensed voice corpus` adds a focused PR/manual job for corpus or diagnostic changes.
It uses the same pinned Xcode/Python environment and runs
`python3 Tools/Corpus/benchmark.py --output .build/corpus-evidence`.
Four stable subsets include an explicitly prepared synthetic 60-second stream with
declared join boundaries. Ten warm-cache load and preloaded decode trials per subset
retain raw distributions, expected failures, consumed-output checksums and exact source
identities. Metadata and sanitized logs are uploaded for 14 days; no WAV is uploaded.
File handling has no timing threshold or claim about DSP/device performance. See
[corpus definitions](VoiceCorpus.md) and [evidence](Evidence/voice-corpus.md).

## Cepstral references and workloads

Changes to the cepstral pipeline exercise the dedicated 38-case timing/allocation
workflow and the pinned reference-regeneration workflow. Regeneration verifies
committed fixtures, generates a fresh 41-case candidate below `.build`, validates
its complete stage/axis/provenance contract, compares the manifest exactly, and
runs the native 2,898-row stage comparison against the candidate. Artifacts retain
candidate JSON and the native report; committed fixtures are never overwritten.

The performance workflow retains 76 timing and 77 allocation rows with raw
distributions, p99, profiles, input hashes, geometry, memory and positive controls.
Prepared checksum/conversion runs require zero heap maxima; eight explicitly owned
export runs are measured separately. These are host pre-CPP baselines for #33,
with actual CPP pipelines required in #35. Physical evidence remains #74.

## Personal target fitting

The `Personal target evidence` workflow runs on core/profile/target-fixture changes
and manually. It uses committed original synthetic references without downloading
Praat, executes the exact-profile native test, and validates all frame, boundary,
chunk, identity and error-budget fields before constructing fitting receipts.
It then runs the separate public-API example in twenty fresh Release processes:
nine synthetic scenarios per process and either one or four 512-take, 32-session
fitting/evaluation passes. Independent Python expectations check numerical rules,
confusion counts, group identities, conditional uncertainty and activation/refusal.
Eleven corruption controls must fail validation.

The workflow retains synthetic JSON, redacted command logs and the profile xUnit
report for 14 days. It reports fitting/evaluation time separately from input setup,
and process RSS with its stated runtime/input/report overhead. Median RSS growth
between the one-pass and four-pass groups must stay within the declared 32 MiB
host smoke allowance. Every model is bounded to 64 KiB. These are offline software
checks; human listening, useful personal feedback and physical-device measurements
remain follow-up evidence. See [the target example](../Examples/PersonalTargetWorkflow/README.md)
and [reference definitions](../Tools/PersonalTargets/README.md).
