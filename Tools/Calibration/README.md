# Calibration fixtures and evidence

```sh
python3 Tools/Calibration/generate.py verify --directory Tests/HDXLVoiceProcessingTests/Fixtures/Calibration
python3 Tools/Calibration/generate.py generate --directory .build/calibration-candidates
python3 Tools/Calibration/evidence.py --output .build/calibration-evidence
```

Generation and verification use Python's standard library and exact integer PCM;
there is no download or private recording. Generation requires a new directory and
never changes committed expectations/provenance automatically. The 16 recordings
and metadata demonstrate contracts, not language, vocal effort or personal preference.
Their generator/artifact hashes and rights are in `Configuration/provenance.json`.

The evidence runner builds the separate public-API Swift example in Release, then
runs 20 fresh processes: ten with one 16-recording analysis pass and ten with four.
Every process also performs ten 512-take dataset imports and a verified cache pass.
It retains raw outputs and distributions, verifies exact audio/profile identities,
recomputes split assignments and PCM16 level-window quantiles independently in
Python, checks coverage/counter bounds, and verifies that temporary audio is removed.
Nine deliberate corruptions must fail validation. Python tests cover malformed
counts, nonfinite measurements, fake cache hits, fixture integrity and holdouts.

The resident-memory comparison allows at most 32 MiB growth in the fresh-process
median when increasing from 16 to 64 sequential analyses. This is a host smoke gate
for unintended retained state, not a hard memory ceiling or a physical-device budget.
Each process peak includes the earlier maximum-capacity import and system/runtime
overhead. Per-pass decoder, prepared-buffer and scalar bounds are checked separately.
All timings include file snapshot/hash and analysis work; no allocation-free,
real-time callback, display-latency or clinical-validity claim is made.

The CI workflow retains only these synthetic JSON results and redacted command logs.
Fixture audio remains in the committed test-only inventory; private input is never
accepted by this evidence command. See [Calibration](../../Documentation/Calibration.md).
