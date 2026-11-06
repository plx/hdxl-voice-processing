# Shared scheduler host evidence

```sh
python3 Tools/Scheduling/benchmark.py timing
python3 Tools/Scheduling/benchmark.py allocation
```

The separate, pinned [benchmark workspace](../../Benchmarks/README.md) measures
explicit light/full compositions. It does not add runtime dependencies or choose
universal presets for a host application. Use Xcode 27.0/Swift 6.4/Python 3.14.8 from
`Configuration/build.json`. Run timing on an otherwise idle host, separately from
the allocator-instrumented mode.

## Matrix and numerical recipes

Twenty one-second workloads cover:

- Twelve mono interleaved cases: Float32/Float64 × 16/44.1/48 kHz × light/full.
- Four full stereo cases: both precisions × interleaved/planar at 48 kHz.
- Two selected-region full cases at 16 kHz, one per input precision.
- Two finite whole-interval full cases at 16 kHz, one per input precision.

Light combines 25 ms rectangular digital levels with 50–700 Hz raw YIN. Full adds
100 ms warm-up K-weighting, the separate causal YIN tracker and CPPS. Source-rate
window/hop lengths use explicit integer division (`rate/40`, `rate/100`), so the
44.1 kHz level window is 1,102 samples. YIN uses the fixed-integration FFT recipe,
threshold 0.1 and 10 ms hop. Tracker continuity weight is 0.05.

CPPS uses Double numerical arithmetic, a 10 kHz analysis rate, 60 Hz frame floor,
10 ms hop, 20 ms centered time smoothing, 1 ms quefrency smoothing and the explicit
Praat 7.0.02 robust 60–330 Hz CPP fit (fit interval starts at 1 ms and extends through
the supported range). Preview conditioning uses 16 FIR lobes and cutoff fraction
0.9. Whole cases use the separately identified finite-interval interpolation recipe.
Full profiles retain raw CPP and raw/tracked YIN. All tails follow emit-unavailable
semantics. The complete encoded recipe and composition identity accompany every row.

PCM is an original harmonic, `0.3*sin(2π*125*t) + 0.07*cos(2π*375*t)`, rounded to
the declared input precision. Stereo right is left/2; selection is the explicit
scaled-Double arithmetic mean. The independent mono reference is left×0.75 rounded
once. Selected cases analyze the first and last 40% as separate regions, excluding
the middle 20% through a supplied annotation plan. They retain one second of original
source coverage and 0.8 seconds of analyzed input. Exact native PCM bytes are hashed.

## Verification and measured boundaries

`ScheduleWorkloadCheck` runs each composition with 63-frame, 173-frame and whole-source
chunks through the same 256-frame source tile. It requires exact per-lane digest parity
and unchanged prepared buffer sizes across replay/reset. It separately executes each
native kernel directly on independently converted mono input, one region at a time.
Numeric values, availability counts and original dependency-support sums must agree.
Per-lane accumulators avoid changing floating-point sum order when algorithms interleave.
Delivery delay is excluded from that direct-kernel comparison because external delivery
batching legitimately differs. Native fixture tests independently verify the kernels.

`workloads.py` checks the entire 20-case matrix, canonical composition identities,
explicit YIN/CPPS recipes, independent pinned K-weighting coefficient budgets,
level/pitch support and availability arithmetic, CPPS complete/partial frame counts,
selection geometry, input memory, finite checksums and digest parity. Mutation tests
retain original native metadata receipts and reject altered recipes, coverage,
reference outputs, identities, distributions and units.

Each case has separate Prepare and Run rows. Prepare constructs and destroys the
kernels, scratch, profile identities and, where requested, resolved mask/prefix counts.
Run includes ordinary reset or mask replay, processing the original second in 173-frame
chunks, finalization and fixed scalar digest accumulation. Input generation, direct
verification and borrowed-to-owned exports are outside measurement. File decoding,
transport copy/drain, I/O and UI are also outside this core matrix; their integration
parity is exercised by package tests.

`preparedBufferBytes` reports owned scalar/record buffers, tile, prefix counts and plane
descriptors. It excludes object/allocator overhead, opaque FFT setup and immutable mask
metadata. `preparedInputBytes` reports the primary PCM input; verification-only mono
reference storage is not a production scheduler allocation. These numbers are explicit
buffer budgets, not process resident-memory or leak measurements.

Three warm-up iterations precede up to 30 measured iterations/30 seconds. The wrapper
requires at least ten observations for every metric and all 40 timing rows or 41
allocation rows. It retains fresh compressed raw histograms, validates their counts and
nonnegative bins, checks exported p99 units and verifies allocator linkage. Every Run
row must have zero maximum malloc-count, malloc-byte and object-allocation counters.
Every allocation/ARC positive-control counter must be positive. ARC/free activity is
reported separately; it is not silently assumed to be zero.

Artifacts are written under `Benchmarks/.build/artifacts/schedule-{timing,allocation}`:
environment/toolchain, locked resolution, exact workloads, commands, raw distributions,
validated distribution summaries, p99 values, linkage and final status. Allocation-mode
timing is instrumentation overhead evidence, not comparable to the timing-mode result.
Throughput uses either original input seconds or analyzed selected seconds explicitly,
divided by a whole Run duration. No value is per-frame latency, capture-to-display
latency, sustained thermal behavior or physical-device real-time evidence. Those
measurements remain [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
See [bring-up evidence](../../Documentation/Evidence/scheduling.md) for the local
correctness and prepared-allocation results; hosted PR artifacts bind the reviewed tree.
