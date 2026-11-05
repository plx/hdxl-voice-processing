# Cepstral reference and performance tools

These development-only tools execute the pinned Praat 7.0.02 binary specified by
[the shared toolchain lock](../Reference/toolchain.json). Its source revision is
`6f3da9ef1d8cce0d5684afc104d02888dfc71b25`; executable SHA-256 is
`8af6acef5b539d69e5decc07a016882a3f04f7a545715756dd9a5e5c7fdf599a`.
Python 3.14.8 and the binary's identity are checked before generation. No Praat
code or executable is linked into the Swift products. Original wrappers invoke
public commands and implement published equations; third-party provenance and
licensed-speech attribution remain in the repository manifest and notices.

```sh
python3 Tools/Reference/setup.py
python3 Tools/Cepstrum/verify.py
python3 Tools/Cepstrum/reference.py --output .build/cepstrum-candidate
python3 Tools/Cepstrum/verify.py --directory .build/cepstrum-candidate
HDXL_CEPSTRUM_REFERENCE_DIRECTORY="$PWD/.build/cepstrum-candidate" \
HDXL_CEPSTRUM_REFERENCE_REPORT="$PWD/.build/cepstrum-comparison.json" \
  swift test --filter cepstrumExternalStageReferences
```

The candidate directory must be absent or empty and below `.build`. Generation
never replaces committed fixtures. `--case NAME` can isolate a failure; the full
verifier requires all cases. `--calibrate` retains route differences as explicitly
unapproved evidence, which the normal verifier rejects. Promoting fixtures is a
separate reviewed action requiring updated hashes/provenance and native validation.
The native comparison environment variables are test-only, not runtime dependencies.

## Two external routes

`interval.praat` invokes the full Sound-to-PowerCepstrogram command, exports up to
five evenly selected complete frames with **every quefrency bin**, and exports
whole resampled PCM and axes. The original Python recipe extracts the same frame
using fused center arithmetic and fused raw pre-emphasis. `frame.praat` consumes
that already-conditioned frame and uses public mean-removal, Gaussian2, Spectrum,
and inverse-Spectrum commands to expose every intermediate bin. It reproduces
power/log scaling explicitly, including the unfloored Nyquist. The public
pre-emphasis menu command rescales to 0.99 and is deliberately not used as the raw
analysis filter. The standalone PowerCepstrum conversion is also a different recipe.

Full and decomposed external cepstra must agree under the predeclared independent
route tolerance `1e-5 + 2e-5*abs(reference)`, with matching availability. The native
implementation never supplies expected values. Files retain input, generator,
toolchain and raw-command output digests, recipes, units/scaling, axes, classification,
all seven stages, full-route power cepstrum and route comparison. Undefined reference
values serialize as JSON `null`, never as valid zero or nonstandard NaN.

The 41 cases cover original noise, pulses, harmonic/missing-fundamental sums,
filtered vowels, impulses, DC, silence, uniform gains including 1e-140/1e-160,
10/16/44.1/48 kHz equivalent sources, 2/5/10 ms hops, pitch-floor settings,
near-minimum support geometry, and Float-rounded PCM. Eight cases use previously
reviewed CC-BY-4.0 corpus excerpts, including consonants and noisy/dropout variants.
These are limited numerical comparisons, not labels of voice health or quality.

`verify.py` operates offline. It checks exact catalog and file coverage, all hashes,
source samples, generator/toolchain, axes and fused frame grid, mean/window equations,
power/log/square equations, availability, route agreement and frozen comparison policy.
Native tests compare all stage values from isolated frames and the whole-input path.

## Native comparison policy

A reference frame is `deepMinimum` when its finite natural-log power range is at
least 32 (about 139 dB power range); otherwise it is ordinary. Deep minima amplify
small Fourier differences through the logarithm. Ordinary speech has separately
tight bounds. Every record carries the same frozen policy from `cepstrum_catalog.py`.

Frame conditioning/spectrum/power errors are normalized by the reference conditioned
frame peak (squared for power). Whole-input comparisons use the maximum of that peak
and the whole-source PCM peak, because full-input Fourier roundoff can enter quiet
frames. A zero scale uses one. Log and signed-cepstral comparisons are absolute.

| Stage budget | Isolated frame | Whole-input path |
| --- | ---: | ---: |
| Normalized window | 2e-14 | 2e-11 |
| Normalized spectrum components | 2e-16 | 2e-13 |
| Normalized power spectrum | 2e-18 | 2e-15 |
| Ordinary log spectrum | 2e-8 | 2e-7 |
| Ordinary signed cepstrum | 2e-6 | 2e-5 |
| Deep-minimum log spectrum | 0.02 | 0.02 |
| Deep-minimum signed cepstrum | 0.002 | 0.5 |

Power-cepstrum error is propagated from signed error `e` as
`e*(2*sqrt(referencePower)+e) + 8*ulp(1)*abs(referencePower)`. These are numerical
verification limits for the specified corpus and profile, not clinical tolerances.
They may not be silently widened to make a regression pass.

## Host performance matrix

```sh
python3 Tools/Cepstrum/benchmark.py timing
python3 Tools/Cepstrum/benchmark.py allocation
```

`CepstralCase.matrix()` defines 38 cases across Float32/Float64 input, always Double
analysis. For each input precision:

- One 1000-sample/10 kHz already-conditioned frame, with a borrowed scalar checksum.
- The same frame with all seven owned intermediate exports (4102 scalars).
- Explicit input-conversion plus full-output checksum for 1000 and 48,000 samples;
  Double uses a borrowed input baseline and Float widens to prepared Double storage.
- 16/48 kHz source × 1/60 seconds × whole-interval 2 ms / preview 5 ms / preview 10 ms.
- 1 second/48 kHz with a bounded owned matrix at each of those three hops.

Pipeline analysis uses 10 kHz, pitch floor 60 Hz, 1000 observed samples, N=1024,
50 Hz fused pre-emphasis, 256-sample delivery chunks, depth-50 whole conditioning or
16-lobe/0.9-cutoff preview. Owned matrix cases permit 500 rows/256,500 scalars.
The original input is 125/250 Hz harmonics plus UInt32 LCG seed-33 noise, rounded
once to the declared input precision outside measurement. Immutable PCM hashes
are retained. The frame-only case treats this signal as already conditioned.

Every case has separate `Prepare` (construct **and destroy** prepared workspaces and
identities, excluding input generation) and `Run` rows. Pipeline Run includes reset,
all source chunks, finalization and borrowed-output checksum consumption. Frame and
conversion Run measure their declared operation. Owned-export rows include explicit
copies/collector creation and consumption. Verification outside measurement checks
exact geometry/availability/memory, and identical counts/checksums at chunk sizes 256
and 63. This is a **pre-CPP checksum baseline**, not CPP computation; #35 must add
actual CPP and combined pipelines under the sequencing amendment in #104.

Three warmups precede up to 30 measured iterations/30 seconds. The wrapper requires
at least ten samples per metric, all 76 timing or 77 allocation distributions, exact
p99 units, locked dependency resolution and inspected binary linkage. The 30 prepared
checksum/conversion Run rows require zero **maximum** heap count/byte/object counters.
The eight explicit owned-export Run rows may allocate. All six allocation/ARC positive
controls must be positive. ARC activity is reported separately; instrumentation timing
is not comparable to the uninstrumented timing binary.

Artifacts under `Benchmarks/.build/artifacts/cepstrum-{timing,allocation}` retain exact
profiles, input hashes, frame/availability/retention counts, explicit prepared scalar
and source bytes, hardware/toolchain/SDK, raw compressed histograms, counts/maxima,
p99, commands and outcomes. Each latency distribution covers its **entire declared
operation**. Input seconds divided by batch seconds gives throughput; dividing batch
time by frame count is an average, not a measured per-frame latency distribution.
Opaque Accelerate tables, object overhead and process RSS are excluded from scalar
workspace bytes. Capture latency, mobile thermal/energy measurements and device
applicability are deferred to #74. Host timings are recorded in
[the evidence note](../../Documentation/Evidence/cepstrum.md).

The dedicated workflow collects both performance modes. Reference-regeneration CI
verifies committed fixtures, generates a fresh candidate, verifies it and compares
its manifest byte-for-byte, then runs native stage comparison against that candidate.
Its artifacts include the candidate and comparison report; no fixture is overwritten.
