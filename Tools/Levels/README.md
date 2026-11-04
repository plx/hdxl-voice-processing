# Level reference development tooling

This oracle separates the external coefficient calculation from filtering and
from the native implementation. It does not measure integrated loudness.

1. Acquire the pinned MIT-licensed `BrechtDeMan/loudness.py` source and license into
   an ignored cache. Both hashes are checked before any function is evaluated.
2. Evaluate the author's unchanged coefficient function with a minimal `math`
   compatibility surface. Its two `lfilter` calls capture coefficients; they do
   not invoke NumPy or SciPy.
3. Filter original generated PCM with an independent 80-digit Decimal direct-form-I
   cascade. The native implementation uses independently reconstructed ITU tables.

The pinned source is revision `dc0f83883d247cbeb106064784e32d8c38ce1573`, associated
with Brecht De Man's 2018 AES paper, “Evaluation of Implementations of the EBU R128
Loudness Measurement.” The reference source is used for coefficient equations;
this tool makes no claim to execute that paper's full evaluation or SciPy's filter.
The normative 48 kHz coefficients are in [ITU-R BS.1770-5, Annex 1, Tables 1 and 2](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/en).

```sh
python3 Tools/Levels/reference.py acquire
python3 Tools/Levels/reference.py generate --output .build/level-candidate.json
python3 Tools/Levels/reference.py verify
```

Only `acquire` performs network access. Ordinary package tests consume the committed
fixture offline. `generate` requires a fresh candidate under `.build`; `verify`
regenerates and compares without overwriting the golden. Neither approves a changed
baseline. Reference or generator changes require fixture review, identity updates,
and affected native correctness/performance validation.

The 240 cases cover ten rates from 16–192 kHz and both Float32/Float64 input, with
explicit rounded PCM hashes. Each includes selected filtered samples and seven
128-sample/64-hop window energies. Normalizing oracle outputs by the recorded input
scale preserves tiny nonzero energies. Cases include silence, impulse, DC, step,
Nyquist, full-scale/attenuated sine, white noise, finite-band pink noise, over-range
square wave, and tiny sine. The pink realization uses original seeded phases and
1/sqrt(bin) spectral amplitudes before explicit PCM quantization; no recordings or
standard-owned audio files are redistributed.

Coefficient, sample, energy, phase, magnitude, and group-delay budgets are recorded
separately in the fixture. The phase-delay oracle uses a central difference of the
complex transfer function; native evaluation uses analytic derivatives. These are
numerical tests of K-weighting, not LUFS, true-peak, acoustic SPL, or device evidence.

## Host performance matrix

```sh
python3 Tools/Levels/benchmark.py timing
python3 Tools/Levels/benchmark.py allocation
```

These commands use the isolated, exactly pinned [benchmark package](../../Benchmarks/README.md).
`LevelCase.matrix()` defines 100 cases: 72 noise cases (two input precisions × direct/sliding
accumulation × 16/44.1/48 kHz × 10/50/400 ms windows × raw/combined K-weighted analysis),
24 silence/denormal cases at 400 ms with K-weighting, and four three-analyzer cases. Each
three-analyzer case owns distinct 16 kHz/10 ms, 44.1 kHz/50 ms, and 48 kHz/400 ms profiles;
execution is serialized, so this is independent-state evidence, not a parallel-scaling claim.

Each analyzer processes one second in 256-sample input chunks with a 10 ms hop and explicit
100 ms K warm-up. Preparation/destruction and prepared Analyze are separate rows. Analyze
includes ordinary reset, every complete window, explicit unavailable warm-up outcomes, and
discarding the final partial grid window. Prepared input generation and workload verification
are outside measurement. Verification checks exact availability counts, owned buffer sizes,
subnormal outcomes, and identical checksums when chunks change from 256 to 63 samples.

Noise is an original UInt32 LCG with seed 32, mapped to `(state-2^31)/2^32` and rounded to input
precision. Denormal input is `leastNormalMagnitude/64 * (state%31-15)` in the input precision.
The observable checksum sums normalized unweighted energies plus three times normalized
available weighted energies; it remains informative when linear mean square underflows.
Expected silence is explicitly zero and is not rejected as an absent checksum.

Three warmup iterations precede up to 30 measured iterations/30 seconds. A wrapper requires at
least ten samples per metric, all 200 timing or 201 allocation rows, valid raw histograms and
p99 export units, unchanged resolution, and the expected allocator linkage. Every prepared
Analyze row must have zero **maximum** malloc-count, malloc-byte, and object-allocation counters;
all six allocation/ARC controls must be positive. ARC activity itself is reported, not assumed
zero. Allocation-instrumented timings must not be compared with uninstrumented timing results.

Artifacts under `Benchmarks/.build/artifacts/level-{timing,allocation}` contain the exact profiles,
input duration, frame/hop and precision, warm-up/availability counts, prepared buffer/input bytes,
checksums, host/toolchain/SDK, commands, raw compressed distributions, p99, linkage, and outcomes.
Each timing value covers a whole processing batch, including all three seconds of total input
in a three-analyzer row. Throughput is total input seconds divided by batch seconds. These
distributions are not individual-window, capture-to-result, thermal, or physical-device evidence.
See [local evidence](../../Documentation/Evidence/levels.md); physical collection remains #74.
