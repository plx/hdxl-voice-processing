# Mask reference tooling

This directory contains original developer tooling, independent mathematical checks,
and command wrappers for the pinned external Praat 7.0.02 executable. No Praat code,
binary, Python package, fixture, or model is linked into the Swift runtime products.

```sh
python3 Tools/Reference/setup.py
python3 Tools/Masks/verify.py
python3 Tools/Masks/reference.py --output .build/mask-candidates
python3 Tools/Masks/verify.py --directory .build/mask-candidates
cmp Tests/HDXLVoiceProcessingTests/Fixtures/Masks/manifest.json .build/mask-candidates/manifest.json
HDXL_MASK_REFERENCE_DIRECTORY="$PWD/.build/mask-candidates" \
HDXL_MASK_REFERENCE_REPORT="$PWD/.build/mask-native.json" \
swift test --filter ltsfReferenceCatalog
```

Generation requires the exact Python version and executable hash in
`Tools/Reference/toolchain.json`, creates candidates only below `.build`, and never
overwrites a nonempty directory. Promotion is a separate reviewed repository edit.
The generator fingerprint covers every numerical generator, wrapper, oracle, and
reference-setup dependency. Changes require new external runs and fixture identities.

The 35 cases contain 5,088 feature frames and 103,571 retained spectral values.
Inputs include original annotated signal surrogates, existing synthetic cases,
eight licensed speech excerpts, 8/16/44.1/48 kHz grids, 2/5/10/30 ms hops,
fractional averaging windows, one-frame inputs, disabled relative intensity,
Float32 input, and a 12-second history/rebase case. Raw output digests cover every
external spectrogram cell, even though compact fixtures retain selected spectra.
Full temporal features and all output interval tiers are retained.

Expected spectral powers, temporal flatness, and interval labels come directly
from external commands. An independent Python quadrature and full temporal GM/AM
calculation cross-checks the flatness using the external spectral matrix. Expected
intensity features use independent integration of those external powers; the
external intensity and combined interval tiers provide an additional end-to-end
check. No native Swift value is used as an expected result.

Budgets were frozen before the first native comparison: spectrum power
`1e-16 + 1e-9 × |expected|`, temporal flatness `1e-8 + 1e-10 × |expected|`,
reference intensity `1e-7 dB`, interval boundaries `1e-12 seconds`, and exact
sample boundaries after declared quantization. These are numerical comparison
budgets, not applicability or clinical thresholds.

The initial off-grid comparison exposed a frame-centering difference: the pinned
executable fuses the source-sample product with subtraction, then the final
half-width addition. Reproducing those operations fixed sample placement at exact
half-sample boundaries. The budgets were unchanged; all 35 cases then passed,
including exact agreement on every interval boundary.

`reference-anomalies.json` keeps three negative reference cases separate:

- Including frequency row 1 exposes its in-place scratch mutation. Immutable-input
  and mutation-aware mathematical checks distinguish the behavior.
- A 60 ms interval with a longer minimum speech duration reaches the detector after
  successful matrix export, then exceeds a five-second subprocess timeout.
- A minimum non-speech duration longer than the same input returns all speech early.

The native supported-domain profile rejects the row-1 configuration and reports
too-short input as insufficient data. A timeout is never a successful numeric
baseline. See [decision #109](https://github.com/plx/hdxl-voice-processing/issues/109).

Offline verification checks the complete catalog, source PCM regeneration/hashes,
dimensions, interval partitions, oracle agreement, external receipts, negative cases,
and artifact inventory. Python tests exercise malformed protocols and semantic
corruption with repaired file hashes. Human-derived fixtures retain their upstream
attribution and consent chain in `Configuration/provenance.json` and
`THIRD_PARTY_NOTICES.md`; synthetic surrogates are not human phonation labels.

## Performance matrix

`benchmark.py` is a separate host-only performance runner. It does not invoke Praat
and does not modify the reference fixture manifest. Its `float32`, `float64` and
`operations` shards cover 26 configurations. Run each shard in both `timing` and
`allocation` mode. The nested Swift benchmark package's dependency lock remains
unchanged; the root library gains no benchmark or reference dependency.

Every PCM case represents 600 seconds; generated inputs and the 30,000-observation
mask are prepared outside timing. Setup/destruction and Run are separate benchmark
names. LTSF retains bounded PCM/spectral history and per-frame scalar/interval
scratch; energy has constant-size value state, and routing borrows original PCM.
Dense resolution and complete JSON metadata export are deliberately allocating
control operations. Their cost and byte volume must not be attributed to the
prepared detector. No CPP kernel runs in this matrix.

Ten complete measured passes plus one warmup are used for PCM Runs; other operations
request thirty measured passes and three warmups. The evidence validator requires
at least ten samples, rejects missing metrics/cases or inconsistent coverage and
storage, and requires positive malloc/ARC controls. A p99 from ten observations is
approximately the observed maximum, not an individual-window latency guarantee.
Timing binaries exclude allocator interposition; diagnostic binaries include it.
A pass in one mode is not interchangeable with a pass in the other.

Each bundle under `Benchmarks/.build/artifacts/masks-*` retains environment and
locked-resolution records, exact input/plan hashes, expanded profiles, layout,
processed counts, prepared scalar storage, selected/missing durations, metadata
volume, fresh compressed raw distributions and p99 exports. `result.json` is the
pass/fail record. Physical-device/thermal/capture measurement remains issue #74.
