# Public-contract evidence

Issue #15, collected 2026-11-04 with Xcode 27.0 (27A266a), Swift 6.4 in Swift 6
language mode, arm64 macOS 27.0.1, and iOS Simulator 27.0 SDKs.

`bash Tools/verify.sh` passes all 20 Swift Testing tests (including parameterized
cases), strict-concurrency compilation, formatting, the independent consumer, and
the package/link graph checks. `bash Tools/build-ios.sh` builds all three products
for arm64/x86_64 iOS Simulator. These are compile/host-test results, not hardware
capture evidence. Physical evidence remains deferred to #74.

The contract tests exercise:

- Golden profile/result bytes and a Python-computed SHA-256; dictionary insertion
  order, all profile dimensions, typed parameter values, complete result-level
  negative-zero handling, and canonically equivalent Unicode text settings.
- Fail-closed future schemas/fields/enums, validated decoding, malformed input,
  nonfinite values, impossible coverage, explicit units, and all unavailable reasons.
- Int64 sample positions near the maximum, checked interval/epoch arithmetic,
  independent source/display/completion clocks, and known versus unknown gaps.
- Shared intermediate budgets, default scalar-only output, immutable array ownership,
  serialization of snapshots, and transfer of snapshots across a detached task.

Fixtures were independently assembled as sorted compact JSON using Python's JSON
and hashlib modules, with this profile SHA-256:

`11af161bd9d8054c8549b8d5de5d106c62a9afed741ba97de5358ffc0793f1e0`

The fixture named `fixture-cpps` demonstrates contract fields; it is not a validated
CPPS implementation or numerical golden output. The independent consumer builds a
profile, preserves an insufficient-data result, and restores it through the public
Codable API without importing optional products. Its initial debug binary at
`b58667c` was 808,320 bytes on this host, informational only. No result-allocation benchmark is claimed before
the isolated harness and result-delivery implementations exist.

Processor lifecycle rules are specified by the protocol and ADR. Execution tests
for real processors belong to framing (#24), scheduling (#40), and lifecycle (#43).
