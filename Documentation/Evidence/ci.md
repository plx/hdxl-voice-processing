# CI bring-up evidence

Issue #19, verified 2026-11-04. Initial implementation commit
`406ddbcfb0f28d207fc5bbe20c98ba9886090419` completed the hosted
[six-lane positive run](https://github.com/plx/hdxl-voice-processing/actions/runs/41830279946).
Every executed job succeeded. The weekly/manual job was correctly skipped for
the PR event; its repeated suite was also run locally. Subsequent report-redaction
and consumer-build refinements are covered by the final checks on
[PR #81](https://github.com/plx/hdxl-voice-processing/pull/81).

Downloaded artifacts were inspected: all six had fresh `environment.json`,
`result.json`, and `commands.log`; each of the four test lanes had valid
`tests-swift-testing.xml` containing 20 tests. The environment recorded a clean
checkout, macOS 27.0.1 (26A434), hosted image `xcode-27-arm64`, Xcode 27.0
(27A266a), Swift 6.4, SDKs 27.0, and Python 3.14.8. Simulator/device lanes were
labeled compile-only with physical evidence deferred to #74.

Initial observed workflow cost, before adding the independent consumer to the
iOS lanes (seconds, not a performance baseline):

| Lane | Verification commands | Whole hosted job |
| --- | ---: | ---: |
| debug | 98.713 | 140 |
| release | 58.028 | 97 |
| address | 62.598 | 107 |
| thread | 81.289 | 132 |
| iOS simulator | 51.058 | 91 |
| iOS device build | 32.448 | 59 |

The six jobs consumed 626 aggregate job-seconds including setup and artifact
upload, with concurrency and queue time affecting wall time. The initial suite
is small enough to retain every correctness case on every PR. Revisit partitioning
as fixture/stress coverage grows (#80); no timing threshold is imposed.

## Negative workflow proof

The isolated `ci-probe/issue19` branch added only a deliberately failing Swift
Testing assertion, `#expect(1 == 2)`, to the implementation. Probe commit
`a3919e370f6f4e796527856a0f7dc4dd89a1dce7` was never part of the PR branch.
The [hosted negative run](https://github.com/plx/hdxl-voice-processing/actions/runs/41830035075)
failed all four test lanes at that assertion; both compile-only iOS lanes passed.
The test command returned status 1 through the wrapper to GitHub, and all six
jobs uploaded their expected artifacts despite the failures. This proves actual
test rejection, not merely workflow syntax validity or a setup failure.

## Local checks and review adjustment

All seven local commands in `Documentation/ContinuousIntegration.md` passed on
the declared Xcode/Python versions. The release/sanitizer lanes ran all 20 Swift
tests. Extended mode completed ten repetitions of each Swift Testing test.
Unsigned simulator and device builds cover all three runtime products; the
independent core consumer also builds at both destinations. The fast lane checks
the consumer dependency/link graph and executes it with networking denied.

Both first-cycle Codex reviews independently caught the same failure-artifact
bug: string replacement could insert `<checkout>` into an XML attribute. The fix
redacts parsed XML values before serialization. A regression test reparses a
report with checkout/home paths and an ampersand and checks the failure details.
The Python suite now has 21 gate/provenance tests, including child failure
propagation, stale-artifact replacement, toolchain drift, missing/empty/failed
reports, and valid XML redaction. Workflow syntax passes actionlint 1.7.12 with
the pinned archive checksum.

No physical capture, simulator runtime, thermal/energy, or performance pass is
implied by these checks. Hardware collection remains #74, and hosted-preview
maintenance remains #80.
