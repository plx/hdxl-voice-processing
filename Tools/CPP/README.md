# CPP reference tools

These development-only tools use the pinned Praat 7.0.02/Python 3.14.8 toolchain in
[`Tools/Reference/toolchain.json`](../Reference/toolchain.json). The executable,
source revision, input objects, script/settings, seeds and outputs have recorded
identities. No reference executable or GPL implementation is included in Swift
products. Runtime processing does not require Python, a network or a microphone.

```sh
python3 Tools/Reference/setup.py
python3 Tools/CPP/verify.py
python3 Tools/CPP/reference.py --output .build/cpp-candidate
python3 Tools/CPP/verify.py --directory .build/cpp-candidate
cmp Tests/HDXLVoiceProcessingTests/Fixtures/CPP/manifest.json .build/cpp-candidate/manifest.json
HDXL_CPP_REFERENCE_DIRECTORY="$PWD/.build/cpp-candidate" \
HDXL_CPP_REFERENCE_REPORT="$PWD/.build/cpp-native.json" \
  swift test --filter cppExternalReferences
HDXL_CPP_PCM_REFERENCE_REPORT="$PWD/.build/cpp-pcm-native.json" \
  swift test --filter cppWholePCMExternalSpeechReferences
```

Candidates must be generated into an absent/empty directory below `.build`.
Generation cannot overwrite committed fixtures. `--case NAME` can isolate a
reproducer; full verification requires the complete catalog. `--calibrate` retains
unapproved diagnostic candidates, which the normal verifier rejects. Promoting
goldens is a separate reviewed action requiring numerical, provenance and identity
checks; native output never supplies expected values.

## Coverage and independent expectations

The 216 inputs comprise 19 original constructed power cepstra and all 197 selected
full-route frames from the independently generated #33 fixtures. Fourteen upstream
frames are unavailable and retain that status. The 202 usable inputs each have seven
profile rows: least squares, pinned Praat `Robust`, and complete Theil–Sen, each with
none/parabolic peak interpolation, plus the unsmoothed Murton-style modern recipe.
This gives 1,414 comparisons. All 40 licensed speech frames retain their existing
CC BY 4.0 attribution/provenance; no new human recordings are acquired.

Constructed inputs include straight/flat backgrounds, narrow/broad peaks, close/far
equal peaks, two search-edge peaks, multiple rhamonics, subharmonic competition,
plateaus of widths 2/5/8, outliers, dense ripple, near ties, the finite power floor,
very large finite power, and all-zero power. Hand-derived native tests independently
check known lines, a parabolic peak and small robust-regression examples. Such
signals test numerical definitions, not the voice health or pleasantness of people.

`fit.praat` reads a public-format PowerCepstrum text object and queries slope,
intercept, CPP, peak magnitude and quefrency separately. Requested and effective fit
ranges remain separate. Each reference fit query resets its RNG to the recorded
seed, preventing different queries from silently selecting different randomized
search paths. Ordinary methods use seed 7002; `Robust slow` is checked at 7002,
271828 and 314159. There are 2,222 external trials in total.

Least-squares and pinned-robust expected coefficients come from those external
queries. Complete mathematical Theil–Sen coefficients come from an independent
Python implementation of the published all-pair median and median intercept; its
peak still comes from the external peak query. Expected provenance names this
distinction in every row. Residual statistics are independently derived from the
recorded input bins and expected line. External trial fields are retained unchanged.

## Pinned implementation details and exceptions

The source revision is `6f3da9ef1d8cce0d5684afc104d02888dfc71b25`. Inspection and
black-box probes established three details, recorded in
[#107](https://github.com/plx/hdxl-voice-processing/issues/107):

- A requested fit of `0.001–0 seconds` selects the whole quefrency domain, then
  excludes q=0. It does not preserve a 1 ms effective lower bound.
- Praat `Robust` takes the final slope median from the **first n−1** pointwise slope
  medians. Each pointwise median still uses all other fit points, and the intercept
  uses all n residual intercepts. The Swift `praat7002Robust` mode reproduces this;
  complete `siegelRepeatedMedian` is separately named and tested.
- Praat `Robust slow` targets the complete pairwise median but its randomized
  selector is defective on some constructed tied/degenerate inputs. At seed 7002,
  18 profile rows disagree with the complete median; 12 rows change beyond the
  fixed tolerance across seeds; two rows fail in the external median selector.
  Categories overlap and affect 16 constructed inputs (32 profile rows).

The explicit exception list is in `cpp_catalog.py`; unknown exceptions fail
verification, and listed cases must actually show the recorded incompatibility.
The very-large-power case retains six failed trials: seed 7002 triggers the pinned
`median_common.h` line-193 assertion, while the other two seeds trigger line 369,
for each interpolation. Checkout paths in failure evidence are normalized before
hashing. Other failures are not accepted. No supplied speech or other external
cepstral frame exhibited these Theil failures.

This does not relax numerical tolerances or silently substitute mathematical output
for reference output. The mathematical profile has its own identity. Its complete
median must match independently derived expectations on every usable input; all
other Theil cases must also match every recorded external seed. Native selection
has no randomization or subsampling. A future reference upgrade requires a separate
pin, comparison and identity decision.

## Frozen isolated-kernel budgets

These limits were set before native comparisons. Both implementations consume the
same input power bins. They are numerical verification budgets, not clinical limits
or allowances for upstream PCM conditioning differences.

| Quantity | Absolute limit |
| --- | ---: |
| CPP, peak, background, intercept and residual statistics | 1e-8 dB |
| Slope | 1e-6 dB/s |
| Peak quefrency | 1e-12 s |

The first complete native comparison of all 1,414 rows used at most
0.00018189894035458565 of a budget. Complete mathematical Theil matched the independent
oracle exactly on that host. These observations do not imply exactness on every host.

`verify.py` runs offline. It checks catalog/file coverage, canonical bytes, source
power and geometry, generator/toolchain/seed identities, manifest hashes, effective
fit bins, independent mathematical medians, residual statistics, expected-versus-
external separation, and the exact exception policy. Corruption tests rehash changed
records so formatting or a stale hash cannot be the only rejection reason.
Reference-regeneration CI reproduces the complete manifest and compares native
outputs against the fresh candidate before retaining evidence.

See [the CPP API guide](../../Documentation/CPP.md) for bounded work, units, ownership,
availability and pipeline integration. The [Praat manual](https://www.fon.hum.uva.nl/praat/manual/PowerCepstrum__Get_peak_prominence___.html)
names the basic measure; [the pinned implementation](https://github.com/praat/praat.github.io/blob/6f3da9ef1d8cce0d5684afc104d02888dfc71b25/dwsys/SlopeSelector.cpp)
resolves estimator behavior that its older manual text does not capture.

## Whole-PCM comparisons

All eight speech inputs also run through native PCM conditioning, framing, FFT,
power cepstrum and pinned robust CPP. The 40 selected frames compare to the external
whole-route references, including peak, background, slope/intercept and all residual
statistics. Their separately frozen absolute budgets are 1e-4 dB, 0.01 dB/s and
1e-8 seconds of quefrency. These account for upstream conditioning/FFT rounding;
they do not change the stricter same-input CPP budgets above. The first complete
run consumed at most **0.05227198244028841** of a whole-path budget. This check is
scoped to ordinary speech; it makes no blanket claim for deep-minimum synthetic
spectra or arbitrary PCM. CI retains this comparison separately.

## Host performance matrix

```sh
python3 Tools/CPP/benchmark.py timing --shard kernels
python3 Tools/CPP/benchmark.py allocation --shard kernels
```

Repeat both commands for `float32-16000`, `float32-48000`, `float64-16000` and
`float64-48000`. The five disjoint groups cover **77 workloads**:

| Cases | Work |
| ---: | --- |
| 48 | Isolated fit/search: 257/513/1025 bins, sparse/dense peaks, all four fits, none/parabolic interpolation |
| 24 | Actual PCM-to-CPP: Float/Double source, 16/48 kHz, 1/60 seconds, whole-input 2 ms or preview 5/10 ms hop |
| 4 | Full-output conversion/checksum: both source precisions, 1,000 samples at 10 kHz and 48,000 at 48 kHz |
| 1 | Explicit owned dB/background/residual snapshots and shared measurement-result construction |

Every case has separate `Prepare` and `Run` measurements. Preparation constructs
and destroys workspaces and identities; input generation is excluded. Prepared
processing consumes all CPP scalar diagnostics and includes reset/finalization in
pipeline cases. Only the owned-export Run may allocate. Every allocation group
also requires a positive buffer/object/ARC control, with zero maximum heap counts
for every prepared non-export Run. Timing has no allocator interposition.

Isolated inputs are original sloped dB backgrounds with a Gaussian peak and optional
dense ripple. The PCM matches #33's harmonic-plus-noise signal, rounded once to its
source precision. Every exact input is hashed. The pipeline binds the modern Murton
settings to its full upstream recipe: analysis 10 kHz, 1,000-sample support,
1,024-point FFT, 513 bins, 512 fitted points and 261,121 slope evaluations per frame.
Preview uses 16 FIR lobes and a 0.9 cutoff fraction. Both source precisions use Double
analysis. Isolated inputs are already power cepstra and are not labeled PCM durations.

`CPPWorkloadCheck` validates repeated execution, 63/256-sample chunk equivalence,
frame counts, availability, bounded exports and observable output. The wrapper
independently checks complete group membership, recipe, precision, work bounds,
prepared scalar memory, input identities, metric units and raw distributions.
Full matrix membership is the union of the five groups; an individual artifact
does not claim to cover the other groups. CI runs each group separately.

Each 60-second Run uses one warmup and ten measured complete operations, with a
3,600-second cap; other cases use three warmups and thirty operations, with a
60-second cap. Evidence requires at least ten measured samples. **p99 of ten samples
is effectively a sample maximum**, not a precise population-tail estimate. Raw
histograms retain sample counts and maxima. These relatively expensive complete
robust fits are not silently replaced with subsampled or least-squares estimates.

Artifacts in `Benchmarks/.build/artifacts/cpp-MODE-GROUP/` include environment and
locked dependencies, workload descriptions, separate CPP/upstream buffer bytes,
`raw-baseline.json.gz`, `distributions.json`, `p99.json`, commands and results.
Prepared scalar bytes exclude opaque Accelerate tables, object overhead and process
RSS; input storage is separate. Whole-input analysis waits until interval completion.
Pipeline distributions describe complete batches, not individual capture deadlines.
See [host evidence](../../Documentation/Evidence/cpp.md). Physical capture, device
load and thermal measurements remain [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
