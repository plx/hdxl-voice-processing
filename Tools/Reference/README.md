# Independent reference tooling

This directory is developer tooling for #26. The Swift package builds and consumes
committed golden fixtures without Python, Praat, network access, or microphone input.
The direct Praat CLI avoids Parselmouth/NumPy and their additional version/ABI locks.
Python 3.14.8 uses only its standard library; `toolchain.json` is the complete tool lock.

## Reproduce from a clean checkout

On macOS 27 arm64 with the repository's Xcode 27 and Python 3.14.8:

```sh
python3 Tools/Reference/setup.py
python3 Tools/Reference/fixtures.py --output .build/reference-inputs
python3 Tools/Reference/run.py --input .build/reference-inputs/saw-120ms.wav --output .build/cpps-candidate
python3 Tools/Reference/verify.py
python3 Tools/Reference/benchmark.py --output .build/reference-evidence
```

Use fresh output paths for another run. Setup downloads the official universal
Praat 7.0.02 disk image, verifies its byte count and published SHA-256, mounts it
read-only, copies the application into `.build`, detaches it, then verifies the
executable hash and exact version output. It does not install into Applications.
No executable or upstream implementation is committed or linked into Swift.
`--tool` may select another local copy, but the same exact executable hash is required.
The runner disables preferences/plugins, fixes `LC_ALL=C`/`LANG=C`, and requests UTF-8.
Scripts read PCM and emit stdout; they do not request Praat's full-trust capability.

`run.py --analysis hnr-ac|hnr-cc|perturbation|formants --input ... --output ...`
runs the other pinned recipes. Use `saw-500ms.wav` for these probes. All input must
be mono, 16 kHz, normalized PCM16 or IEEE Float32/Float64 RIFF WAVE; no rescaling,
channel averaging, gap stitching or implicit sample-rate conversion happens in the
wrapper. Praat's explicitly configured internal conversions are separate. Inputs
are bounded to 2,880,000 samples; minimum duration is 100 ms. CPPS matrix export is
limited to 50,000 scalars per matrix; `--frames-only` supports longer inputs.
Unsupported inputs fail explicitly without writing a candidate.

## Profiles, independent sources and scope

`Profiles/cpps-murton-praat7.json` is a complete schema-v1 `AnalysisProfile`.
It follows the parameter recipe in [Murton et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC7893528/):
60 Hz analysis floor, 2 ms hop, 5 kHz maximum frequency, 50 Hz pre-emphasis;
10 ms/1 ms smoothing; 60–330 Hz peak search, 0.05 tolerance, parabolic
interpolation; straight robust fit from 1 ms through the quefrency domain end.
Pre-smoothing trend subtraction is disabled. Physical Gaussian support is 100 ms,
analysis rate 10 kHz, FFT length 1024, 513 quefrency bins at 0.1 ms spacing.
Frame count uses the pinned binary64 duration after resampling before flooring;
there is no epsilon added at exact-hop boundaries. This follows the selected
`Sampled_shortTermAnalysis` convention, independently checked at 100/102/110/120/128/150/200 ms.

The paper used **Praat 6.0.40**. This profile is **Praat 7.0.02 with the recipe**,
not historical binary parity. In this pinned source, `Robust` selects Siegel repeated
median. The effective estimator is serialized, and [#86](https://github.com/plx/hdxl-voice-processing/issues/86)
tracks whether historical comparisons are wanted. The profile validator intentionally
accepts only this exact recipe. Add and review a new named recipe before changing
settings. `voice.recipe` defines the other complete external recipe parameters;
their native `AnalysisProfile`s and full conformance goldens belong to the respective
algorithm issues. They are not presented as shipped Swift algorithms.

The HNR routes are distinct AC and CC analyses, with 10 ms hop, 75 Hz floor,
0.1 relative silence threshold, and 4.5 periods per window. Silent raw -200 dB
sentinels become explicit undefined entries; an undefined mean is unavailable.
Pulse tracking uses explicit raw-CC pitch parameters followed by **Sound & Pitch**
to PointProcess CC, preserving alignment to the waveform. Jitter and shimmer use
numeric queries, never localized report text. Fraction outputs remain fractions;
absolute jitter is seconds, shimmer dB is a dB ratio. Burg formants use five formants,
5 kHz ceiling, 25 ms effective/50 ms physical Gaussian support, 10 ms hop and
50 Hz pre-emphasis. These choices are comparison fixtures, not clinical defaults.

Sources: [HNR AC](https://praat.org/manual/Sound__To_Harmonicity__ac____.html),
[HNR CC](https://praat.org/manual/Sound__To_Harmonicity__cc____.html),
[voice scripting](https://praat.org/manual/Voice_6__Automating_voice_analysis_with_a_script.html),
[jitter](https://praat.org/manual/PointProcess__Get_jitter__local____.html),
[Burg formants](https://praat.org/manual/Sound__To_Formant__burg____.html).
All numerical computation in these routes is the pinned external executable.
`fixtures.py` supplies six additional closed-form DFT/energy vectors, independently
hand-derived from the equations recorded in the manifest. No native analyzer generates
its own expected values. Full synthetic coverage arrives in #22, licensed recordings
in #27, and every algorithm's conformance evidence in its leaf and #66.

## Golden schema v1 and identity

The normative executable schema is `verify.validate`: it reconstructs the entire
manifest from the current recipe, lock, PCM and strict raw-output parser, requiring
exact canonical equality. The JSON layout is:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Exactly 1 |
| `referenceIdentity` | SHA-256 of `hdxl-reference-v1\n` plus canonical `identityInputs` |
| `identityInputs` | Runner version/source hash, complete tool lock, profile hash (or auxiliary recipe), input hashes, export mode; CPPS selection mask |
| `profile` / `result` | CPPS schema-v1 `AnalysisProfile` and `MeasurementResult` |
| `rawOutputSHA256` | Exact UTF-8 `reference.raw.txt` bytes; unrounded external queries retained |
| `data.axes` | Frame count/first center/hop, quefrency count/origin/step in seconds |
| `data.frames` | Raw and smoothed columns: time, slope dB/s, intercept dB, peak dB, peak quefrency seconds, CPP dB |
| `data.matrices` | Optional raw and smoothed linear-power cepstra, quefrency-row-major, explicit shape/unit |
| `support` / `tolerances` | CPPS source semantics and reviewed regeneration tolerances |
| auxiliary `data` | Typed scalar outcomes; pulse times, HNR frames or formant frames with Hz frequency/bandwidth and 1-based indices |

Canonical JSON uses sorted keys, compact UTF-8, NFC, finite numbers and normalized
negative zero, matching the profile contract for this recipe. File hashes include
the final LF; identity hashes exclude it. Artifact and normalized Float64-LE PCM
hashes are both recorded, so changing an encoding or a sample changes identity.
Auxiliary selection is the entire contiguous input, recorded in its recipe.
Raw line protocols require opening/closing markers, declared counts, exact coverage,
unique indices and expected units. Undefined is null/an unavailable outcome; NaN,
infinity, malformed text, process failures and unexpected warnings fail validation.

CPPS `result` describes the whole input interval, all included samples and source
epoch 26. Its display anchor is the source midpoint; algorithmic availability waits
to the interval end, so effective delay is half the interval duration. Host timestamps
are unknown. Individual frame centers do not imply causal streaming support: Gaussian
windows and centered smoothing use surrounding data. Native streaming issues must
state their own buffering/support delays and preserve excluded intervals.

`verify.compare` accepts already-validated manifests and returns `identityMismatch`,
`referenceDisagreement`, or `match`. `compare_outcomes` additionally distinguishes
`unsupportedInput` and `matchingUnavailable`. Counts, indices, identifiers, units,
status and coverage are exact. Axis tolerance is 1e-12 s; reference regeneration
uses 1e-8 absolute/1e-10 relative for dB/linear outputs. These conservative initial
limits check reproducibility of the same binary, not clinical equivalence or a
preapproved tolerance for a future native algorithm. Each algorithm leaf must review
its conditioning, error distribution and coverage before selecting native tolerances.

## Review and performance

Candidates are written only to fresh directories under `.build`. Nothing silently
updates committed goldens or provenance. Review old/new identities, raw changes,
component differences and reasons before replacing a fixture. After approval of the
change in its PR, update artifact/generator hashes in `Configuration/provenance.json`.
The ordinary correctness workflow runs `verify.py` offline. The separate
`reference-regeneration.yml` workflow runs the pinned executable for reference changes,
manually, and weekly, and retains only original-synthetic candidates and JSON reports.

`benchmark.py` separates acquisition, per-run verification/setup, external process
regeneration/export, parser validation, and native fixture validation. It repeats
smoke, intermediate-export, and full-current-catalog workloads; "catalog" currently
means the original synthetic inputs, not a human corpus. #27/#25 expand registration
when licensed fixtures exist. Raw trial distributions and median/p95/throughput are
reported with identities and host metadata. External allocations are explicitly
unavailable without an audited backend. Native validation is a release Swift test
with bounded `ReferenceValidation` signposts and no PCM logging; it is not a benchmark
of a native CPPS algorithm. Future native algorithm benchmarks must link their own
profile, reference identity and actual workload instead of reusing these timings.
