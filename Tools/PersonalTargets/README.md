# Personal-target references

These tools separate DSP reference evidence from fabricated fitting scenarios.
Neither collection contains human voice or establishes useful personal feedback.
See [Personal targets](../../Documentation/PersonalTargets.md) for scope and policies.

The complete public-API, capacity and repeated-memory gate is:

```sh
python3 Tools/PersonalTargets/evidence.py --output .build/personal-target-evidence
```

It retains twenty fresh processes, 180 synthetic scenarios, fifty maximum-count
fitting/evaluation passes, actual exact-profile test evidence and eleven negative
validation controls. See the [example](../../Examples/PersonalTargetWorkflow/README.md)
for timing/RSS boundaries and the declared memory-growth allowance.

Verify committed expectations without running Praat:

```sh
python3 Tools/PersonalTargets/profile_reference.py verify --directory Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets/Profile
python3 Tools/PersonalTargets/fitting_reference.py verify --path Tests/HDXLVoiceProcessingTests/Fixtures/PersonalTargets/fitting-reference.json
python3 -m unittest discover -s Tools/Tests -p 'test_personal_target_references.py'
```

Generate fresh candidates under `.build` using the pinned Python 3.14.8 environment
and the existing [reference tool setup](../Reference/README.md):

```sh
python3 Tools/Reference/setup.py
python3 Tools/PersonalTargets/profile_reference.py generate --directory .build/target-profile-candidate
python3 Tools/PersonalTargets/profile_reference.py verify --directory .build/target-profile-candidate
python3 Tools/PersonalTargets/fitting_reference.py generate --path .build/target-fitting-candidate.json
```

Generation refuses an existing destination. Promotion is a separate, reviewed
operation that must update the provenance inventory. No command silently replaces
committed expected values or derives them from native measurements.

The profile collection contains 14 cases: ten empty/short/window/hop boundary
prefixes and four complete original C01 recordings. Eight valid-length inputs have
actual pinned Praat 7.0.02 CPPS raw output and reference manifests. Positive short
inputs have one typed unavailable CPPS result; empty inputs have no frame. They
are boundary-contract checks, not claims that Praat computed short-source CPPS.
Independent scalar Python YIN calculations compare with the declared native FFT
backend. Unweighted dBFS comes from `math.fsum` over original PCM windows. Raw
signals retain amplitude; unavailable values remain null. Complete source,
generator, profile, executable, input and artifact identities are retained.

The native profile test checks every expected frame/value and pitch status,
selected-interval medians, exact complete-frame equality under three alternative
chunk layouts, repeat-finish behavior and large acquisition offsets. Its budgets
are absolute `1e-4 dB` CPPS, `0.001 Hz` F0 and `1e-10 dB` level. These are
software parity budgets, not measurement uncertainty or perceptual thresholds.

```sh
HDXL_PERSONAL_TARGET_PROFILE_REPORT="$PWD/.build/target-profile-report.json" \
  swift test -c release --filter personalTargetExactProfile
swift test -c release --filter personalTarget
```

For a candidate, set `HDXL_PERSONAL_TARGET_REFERENCE` to its `profile-reference.json`.
Set `HDXL_PERSONAL_TARGET_FITTING_REFERENCE` for candidate fitting expectations.
Require the test process to succeed. `validation.validate_profile_report` checks
the exact full profile identity, analysis implementation, reference hash, complete
case/metric/frame denominators and unchanged error budgets before returning the
three components of a fitting validation receipt. The receipt identifies retained
artifacts; it is not a signature or authentication of arbitrary caller claims.

The fitting collection has nine independent scenarios: separated, inverted,
overlapping, usual values on both sides, a training outlier, overlapping holdout,
out-of-range holdout, recording-level confound and pitch confound. Python computes
whole-recording split hashes, lower empirical quantiles, bounds and confusion
counts independently. Wilson endpoints use numerical inversion of the score
inequality, cross-checking the native algebraic expression. Labels are assigned
after role selection solely to balance fabricated software scenarios. This must
not be presented as an independent listening-study design.
