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
correctness case. Each has a 30-minute timeout. Strategy fail-fast is off so a
failure still leaves evidence from the other lanes. These are independent jobs:

| Lane / local command | What runs | Evidence scope |
| --- | --- | --- |
| `bash Tools/verify.sh` (`python3 Tools/ci.py debug`) | Format, provenance and gate tests, debug build and all tests, independent consumer, graph/link checks, network-denied consumer run | Native macOS correctness and consumer isolation |
| `python3 Tools/ci.py release` | All tests compiled with optimization | Native macOS optimized correctness; future numerical tests join this suite automatically |
| `python3 Tools/ci.py address` | All tests with Address Sanitizer | Native macOS instrumented memory accesses |
| `python3 Tools/ci.py thread` | All tests with Thread Sanitizer | Native macOS exercised concurrency paths |
| `python3 Tools/ci.py ios-simulator` | All three products and independent core consumer, generic iOS Simulator destination, Debug | Compile/link only; no simulator execution or microphone capture claim |
| `python3 Tools/ci.py ios-device` | All three products and independent core consumer, generic iOS destination, Debug, signing disabled | Device-target compile only; no installed app or physical execution claim |

Do not combine address and thread sanitizers in one build. They have separate
scratch directories, as do release and extended runs. Sanitizers currently cover
the host test binary, not the iOS compile lanes, Apple framework internals, or
unexecuted code. Swift concurrency checking complements these runs; a sanitizer
pass is not a proof of real-time safety. Later state/buffer/unsafe interop tests
must enter the normal test suite so both instrumented lanes exercise them.

The weekly and manual `extended` job runs every Swift Testing test up to ten times
in release configuration, stopping a test's repetitions on failure. Reproduce
with `python3 Tools/ci.py extended`. The current suite contains contracts, not
DSP accuracy or audio stress coverage. #18/#26 add fixture/reference infrastructure;
later streaming issues add stress cases. They should extend this lane when their
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
