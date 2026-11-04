# Independent synthetic sources (V03)

These standard-library Python tools create original mathematical test signals. They
never call the Swift analyzers or Praat. SwiftPM copies the compact catalog into the
test bundle only; no runtime product depends on Python or contains these resources.
The source, recipes, PCM, expectations, and catalog each have explicit SHA-256
identities. Ordinary CI regenerates all bytes offline and rejects drift.

```sh
python3 Tools/Synthetic/verify.py
python3 -m unittest discover -s Tools/Tests -p test_synthetic.py
python3 Tools/Synthetic/generate.py --output .build/synthetic-candidate
swift test --filter synthetic
```

Generation requires a **fresh** output directory under `.build`. Review candidates
before manually copying them into `Tests/HDXLVoiceProcessingTests/Fixtures/Synthetic`
and updating `Configuration/provenance.json`. Do not automatically bless changed
bytes. Changing any of the four numerical source files recorded in `catalog.json`
changes the generator identity and every case identity, even if PCM is unchanged.
Benchmark orchestration has its own source hash. No host timestamps or local paths
participate in committed fixture identities. Canonical JSON uses sorted keys, compact
UTF-8, NFC strings, normalized signed zero/integral floats, and a trailing LF outside
hashes of JSON definitions. Boolean types remain distinct from numbers.

## Models and limits

A recipe fully specifies source rate/count, phase, gain, clipping, filter coefficients
through pole parameters, initial per-section state, and missing intervals. Signals
are mono binary64 normalized PCM in Float64 RIFF WAVE (16-byte `fmt`, `fact`, `data`).
Count zero is a valid empty test case. Rates are integer 1–192 kHz; compact rendering
is capped at 192,000 samples. Streaming rendering is bounded to 65,536 samples per
read and one hour at 192 kHz; WAVE additionally enforces its 32-bit chunk-size limit.
No normalization is inferred from observed signal peaks. Overrange output is rejected
unless hard clipping was explicitly requested; clipped counts are recorded.

- DC and impulses are directly specified values. Harmonics are sums of
  `A[k] sin(2 pi (f[k] n/fs + phase[k]))`. Frequencies/phases are rational turns;
  integer phase arithmetic prevents accumulated phase drift. The symmetry-reduced
  sine polynomial through degree 25 uses separately rounded binary64 operations;
  its independently tested absolute error bound is `5e-15`. Cardinal samples are
  exact, including the zero-amplitude sampled sine at Nyquist. Short rational cycles
  are cached (at most 16,384 samples); longer cycles use the same equation.
- Noise uses the specified SplitMix64 unsigned recurrence and the top 53 output bits
  mapped to `[-1,1)`. Seeds are unsigned 64-bit values. It is uniform test noise,
  not Gaussian noise or a recording. Tests anchor the first words and use eight
  fixed 4,096-sample ensembles with explicit mean/energy bounds. Finite realization
  component SNR is `10 log10(sum(source²)/sum(scaledNoise²))`; the mixture records
  the cross term. This is neither total-mixture energy ratio nor estimated HNR.
- Pulses are delta impulses at exact rational cumulative times, rounded to the
  nearest sample with ties to even. Requested times, rendered indices, and rounding
  errors are retained. Collisions are rejected. Declared period/amplitude arrays
  remain available independently of sample-grid quantization and waveform detection.
- Each all-pole section has conjugate poles `r exp(±i theta)`,
  `r=exp(-pi B/fs)`, `theta=2 pi F/fs`, denominator `[1,-2r cos(theta),r²]`,
  and numerator `1+a1+a2` for unit DC response. The recurrence is
  `y[n]=g*x[n]-a1*y[n-1]-a2*y[n-2]`; cascades retain separate state. Pole radii
  must be strictly below one in binary64. Decimal precision 80 computes the radius
  using the committed pi constant. These are **pole** frequency/bandwidth parameters,
  not a promise that finite spectra/LPC peak estimates equal those parameters.
  Algebraic complex transfer responses are recorded separately from rendered PCM;
  the source/filter projection test discards 4,000 of 8,000 samples to suppress
  initial transients. The Iseli/VoiceSauce correction model remains owned by #52.

Source generation timing describes causal input support starting at zero with no
host clock anchor. It does not claim an analysis delay. Filter phase delay varies
with frequency. Missing intervals are explicit exclusion spans in the original
support; they never erase PCM, compress time, or join neighboring sequence windows.

## Expected values and applicability

`catalog.json` maps every A01–A18 algorithm issue to analytic/invariant and difficult
or undefined cases. `algebra.json` contains hand-derived DFT/cepstral, difference,
background, smoothing, aggregation, and spectral-moment examples. `sequences.json`
contains exact rational perturbation results (logarithmic shimmer additionally has
an 80-digit decimal value). Every scalar uses the #15 measurement/unit/outcome
contract. Silence, insufficient data, invalid periods, and valid zero statistics
are distinct. Explicit masks produce partial-coverage warnings for available values.

The accepted-sequence profile uses **all explicitly included entries** for the
normalization mean. Adjacent differences use contiguous included pairs; APQ/PPQ/RAP
use contiguous centered windows of the stated width. Absolute jitter is mean
absolute adjacent period difference; local jitter/shimmer divide adjacent differences
by the normalization mean. RAP/PPQ/APQ divide the mean absolute center-minus-window-
mean difference by that mean. DDP is 3 RAP; DDA is 3 APQ3. Shimmer dB is
`20 mean(abs(log10(A[i]/A[i+1])))`. Nonpositive included periods/amplitudes are invalid,
except an all-zero amplitude sequence is silence. This profile does not reproduce
Praat's waveform eligibility, factor-based filtering, or endpoint rules. Those
production comparisons belong to #50/#51.

Tests anchor hand arrays and rational fractions independently of the generators,
compare the oscillator against system sine, recover known poles via the quadratic
formula, project steady-state harmonics, compute small direct DFTs, and check
energy/gain/polarity/time/rate identities. All source kinds are invariant to read
block size, including persistent noise/filter state. Swift tests independently
consume PCM, typed metadata, sequence outcomes, and transform identities without
Python. Some changes of rate coincide at common sample times; this does not certify
an arbitrary resampler's antialiasing or transient behavior.

Exact identities apply only under their stated convention. Known source F0 does not
guarantee a pitch estimator finds it. A component SNR change does not guarantee a
monotonic frame-by-frame HNR/CPP response. Estimator bias, eligibility, and empirical
trends must be established by the algorithm leaves. No healthy-voice, pleasantness,
or clinical interpretation is defined by these fixtures.

## Performance and prepared inputs

```sh
python3 Tools/Synthetic/benchmark.py --matrix full --trials 3 --output .build/synthetic-generation
python3 Tools/Synthetic/benchmark.py --mode prepare --matrix full --output .build/synthetic-prepared
HDXL_SYNTHETIC_PERFORMANCE=1 swift test -c release --filter syntheticNativeValidationPerformance
```

`--matrix smoke` (default) selects the six 1-second inputs. The full registration is
24 combinations: 1/10/60/**300** seconds × 16/44.1/48 kHz × source F0 50/600 Hz,
with fixed harmonic amplitudes/phase and a 4,096-sample synthesis block. An exact
`--workload synthetic-1s-16000hz-f0-50` selects one. Preparation is one pass and writes
PCM; generation timing repeats without writing PCM. All trials consume/hash generated
bytes and must agree. Setup (validation and table/coefficient construction), render
blocks, serialization/hash work, and buffered writes/close are measured separately.
Render distributions separate full blocks from the shorter final block. Trial totals,
nearest-rank latency/throughput distributions, precision, hardware model, rate,
duration, source profile/hash, and suggested 40-ms/10-ms analysis frames/hops are
reported. Suggested analysis dimensions are registration metadata, not executed DSP.
Memory is bounded in sample storage; timing summaries retain one scalar per block.
Allocations are explicitly unavailable without an audited Python allocator backend.

**#25 consumers must verify the prepared manifest/PCM identity and load or map input
before the native timed loop.** Synthesis is never analysis performance. The native
validation probe preloads fixture data, warms decoding, and times ten catalog
contract/hash validation passes under bounded `referenceValidation` signposts from
#18. It logs no PCM. It is also not a production algorithm benchmark; its frame/hop
are inapplicable. The dedicated workflow retains numeric evidence, not long WAVs.
Device timing/allocation claims remain deferred to #74.

## Method sources and provenance

All generators, formulas-as-code, hand arrays, and assets here are original work;
no reference implementation code is copied or linked. Method context:

- [Praat jitter definitions](https://praat.org/manual/Voice_2__Jitter.html).
- [Praat shimmer definitions](https://praat.org/manual/Voice_3__Shimmer.html).
  The local dB formula is the absolute log **ratio**, as also confirmed in pinned
  Praat 7.0.02 `AmplitudeTier.cpp`; prose about amplitude differences must not be
  interpreted as taking the log of a signed difference.
- Steele, Lea, Flood, [Fast Splittable Pseudorandom Number Generators](https://gee.cs.oswego.edu/dl/papers/oopsla14.pdf),
  OOPSLA 2014, DOI 10.1145/2660193.2660195 (SplitMix method).

These methods do not create a runtime dependency or import a third-party license
into the original assets. Redistribution inherits the project license decision
tracked in #78. Every committed asset is inventoried with generator/source hashes,
permission, and no-human-voice consent classification.
