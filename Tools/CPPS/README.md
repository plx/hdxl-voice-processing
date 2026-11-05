# CPPS numerical contract

Issue #37 implements the modern published recipe against pinned Praat 7.0.02;
this does not claim historical Praat 6 parity. Toolchain/source receipts remain
in `../Reference/toolchain.json`. No GPL implementation is linked or copied into
the package. The probes and analytic basis-integration oracle are original work.

## Budgets fixed before native CPPS implementation

The isolated stage consumes identical externally supplied power bins. Its budgets
are: linear power **1e-10 absolute + 1e-11 relative**, CPP/peak/background/intercept
**1e-8 dB absolute**, slope **1e-6 dB/s absolute**, peak quefrency **1e-12 seconds**,
axes **1e-12 seconds**. Counts, indices, identity and availability are exact.
Aggregate means use the same dB budget; they do not compound with frame count.

Whole-PCM speech comparisons inherit the separately established upstream allowance:
**1e-4 dB**, **0.01 dB/s**, **1e-8 seconds** of peak quefrency. These are numerical
verification limits, not clinical thresholds. They make no blanket parity claim
for arbitrarily deep synthetic spectral minima. Isolated smoothing checks still
cover constructed inputs and all cepstral bins without this upstream allowance.

## Pinned behavior

Time smoothing precedes quefrency smoothing, both in linear power. Each axis is
active only when floor(requested width/grid step) > 1. Interpolated means clip to
actual sample support and the object domain, then normalize by that support.
For the published 10 ms/2 ms time grid, discrete interpolation lookahead is 6 ms.
The q=0 endpoint has no negative-quefrency cap; temporal endpoints may have caps
inside the larger original sound domain. Singleton time columns remain defined.

Pretrend fits the original dB curve, clips negative residuals, and converts back to
power. The final CPP fit still runs. Requested tolerance is serialized even though
the pinned CPPS matrix path does not use it. Black-box probes and the manual
discrepancy are recorded in [#111](https://github.com/plx/hdxl-voice-processing/issues/111).
The fit uses the pinned first-n-minus-one robust estimator and full-domain
autowindow described in [#107](https://github.com/plx/hdxl-voice-processing/issues/107).

Reference candidates must remain under `.build` until independently verified;
native output never supplies golden values. Probe output distinguishes original,
pretrend-prepared and smoothed power, original/final CPP, and the frame mean.

## Applicability and retained diagnostic failures

Full-PCM acceptance gates compare **final CPPS** on independently conditioned
acquired regions. Raw CPP is retained as a diagnostic; the same-input raw CPP
contract remains governed by #35. A 120 ms synthetic case passes final CPPS but
has one raw-fit intercept difference just above the ordinary-speech allowance.

The corpus's explicit 0.5–0.7 second zero-replacement dropout is retained as an
unmasked characterization case. It is not counted as whole-path parity success.
Its conditioned spectrum has deep minima: independent external frame probes
measured natural-log power ranges 42.8–55.2 within that region, above #33's existing
deep-minimum boundary of 32. Smoothing spreads this conditioning sensitivity to
neighboring CPPS frames. Both sides of the known acquisition gap are therefore
also analyzed independently, with unchanged numerical acceptance budgets. The
mask-aware tests reject full-input dependency support spanning that gap. Digital
zero alone is not an acquisition-loss annotation.

The first unmasked comparison's maximum raw CPP difference was 0.06494 dB and
final CPPS difference 0.01530 dB. Passing its whole mean did not establish frame
parity. [#112](https://github.com/plx/hdxl-voice-processing/issues/112) tracks this
domain limitation and future conditioning/physical-evidence work. No tolerance
has been widened to absorb these failures.

## Host performance matrix

`CPPSCase.matrix()` declares **87 six-second PCM workloads**:

- 72 Double/16 kHz preview cases cross 2/5/10/30 ms hops, 10/20/50 ms time
  smoothing, 1/5 ms quefrency smoothing, and 1/3/5 second rolling windows.
- Six representatives add Float/16 kHz, Float/48 kHz and Double/48 kHz input
  with 1/5 second windows at 10 ms hop, 20 ms time and 1 ms quefrency smoothing.
- Four whole-interval published-recipe cases cover both input precisions and rates.
- Two cases exercise 2/4 second windows; one enables pretrend; two copy all seven
  diagnostic stages and shared frame/rolling measurement exports, with/without pretrend.

Every frame performs raw CPP, time/quefrency smoothing, final CPP, rolling append
and a source-clock query against an explicitly all-eligible mask. The checksum
consumes scalar diagnostics, rolling means and coverage; export cases also consume
every copied value. The unavailable partial preview tail is counted separately and
suppresses the strict completion and latest rolling number. Whole-interval inputs
retain their complete dependency support, even when their center lies outside the
current rolling window. This is a benchmark population, not automatic speech/voice
selection.

Prepare constructs/destroys conditioning, FFT, two CPP workspaces, smoothing and
rolling rings, identities and two immutable source masks. PCM generation is outside
measurement. Run includes reset, actual chunked processing, per-frame aggregation,
finish and checksum. Replays alternate two independent source IDs using the actual
`newSource` discontinuity API and matching prebuilt masks; no new mask is built
inside Run. The checker replays with 256- and 63-sample chunks and requires exact
value/checksum/count agreement. Delivery delay is recorded separately for each
chunk size because batching legitimately changes it.

The original signal is 125/250 Hz harmonics plus deterministic UInt32 LCG seed-37
noise, rounded once to input precision. SHA-256 identifies exact prepared PCM bytes.
`workloads.json` includes complete numerical/statistic settings and identities,
frame counts, lookahead, scalar/record workspace bytes and ring capacities. Memory
counts exclude opaque FFT tables and object/mask overhead; input memory is separate.
The smoothing ring is duration-independent; whole-interval conditioning retains the
declared input. A 2 ms hop is a configuration, not a real-time deadline guarantee.

```sh
python3 Tools/CPPS/benchmark.py timing --shard h2-w3
python3 Tools/CPPS/benchmark.py allocation --shard h2-w3
```

The twelve `h{2,5,10,30}-w{1,3,5}` groups each contain six primary cases; `variants`
contains fifteen. CI runs every group. Timing disables allocator interposition;
allocation uses the pinned interposer plus a mandatory positive allocation/ARC
control. All prepared Run heap-count/byte/object maxima must be zero, except the
explicit OwnedDiagnostics rows. ARC traffic remains reported, not claimed absent.

Each Run has one warmup and ten measured complete operations (3600 second cap);
Prepare has three warmups and thirty samples (60 second cap). At least ten samples
are mandatory. P99 with ten observations is effectively the observed maximum,
not a stable population tail estimate. Raw histograms, sample counts/maxima, p99,
exact commands, locked dependency hashes and toolchain/hardware/source metadata
are retained under `Benchmarks/.build/artifacts/cpps-*`. Per-frame cost obtained by
dividing a whole operation is amortized throughput, not worst-case delivery latency.
Physical device, capture and thermal measurements remain #74.
