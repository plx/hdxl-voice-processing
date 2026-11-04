# A04 digital-level numerical and host evidence

Implementation based on main `47e62784a89c3393696e2cbf497dc38b005f76ed`, collected
2026-11-04 on the development Mac13,1 with macOS 27.0.1, Xcode 27.0, and Swift 6.4.
These are mathematical and host measurements. Physical capture latency, route behavior,
sustained energy/thermal behavior, and microphone calibration remain #74; policy review is #100.

## Independent numerical evidence

The native coefficients independently reconstruct ITU-R BS.1770-5's 48 kHz tables.
The reference obtains coefficients from the original author's MIT-licensed implementation,
pinned to `BrechtDeMan/loudness.py` revision `dc0f83883d247cbeb106064784e32d8c38ce1573`.
Source and license hashes are verified before its unchanged coefficient function is evaluated.
Original 80-digit Decimal direct-form-I filtering supplies the expected samples/energies;
native processing uses a Float64 transposed direct-form-II cascade. Neither the external
source nor NumPy/SciPy is linked into runtime products.

The committed fixture has 240 cases: ten rates × two PCM precisions × twelve original
synthetic signals. Each includes precision-rounded input with SHA-256, selected filtered
samples, and seven 128-sample/64-hop windows. Coefficients, complex response, and an independent
central-phase-difference group delay are checked separately.

Fixture SHA-256: `3e85291e5662f67e5fd4f922a9f61328efee3d5a4ba3e0235cd60bdc35507165`.
Generator SHA-256: `eb0e7be6789cdcaff6db8bdb017098f3627df5b2330d3c13d6553a4dfa98644d`.

Observed maxima in the focused native matrix:

| Comparison | Maximum absolute error | Committed budget |
| --- | ---: | ---: |
| Coefficients | 1.1756e-12 | 2e-12 |
| Normalized filtered samples, either input precision | 1.2334e-11 | 2e-9 |
| Normalized mean square, both accumulation methods | 5.4576e-12 | 2e-9 |
| Response magnitude | 4.5400e-11 | 3e-9 |
| Group delay, seconds | 4.0175e-10 | 1e-6 |

These are matrix observations, not universal error guarantees. Direct/sliding long-stream
comparisons, high-to-tiny amplitude transitions, exact chunk partitions, large Int64 origins,
warm-up, partial support, nonfinite rejection, clipping, reset/cancellation, strict serialization,
and diagnostic pairing also pass. Full gate results are recorded below.

## Host performance

The [100-case matrix](../../Tools/Levels/README.md#host-performance-matrix) records preparation
and Analyze separately. Preparation includes destruction. Analyze includes ordinary reset,
one second per independently configured analyzer, every complete window and warm-up outcome,
and partial-tail discard. Synthesis and verification are outside measurement. Multi-analyzer
rows execute three independently configured workers serially; they do not measure parallel scaling.

All **200 timing rows / 400 metric distributions** and **201 allocation rows / 1,407 metric
distributions** passed with 30 measured samples each after three warmups. The modes use separate
binaries and verify allocator linkage. All **300 prepared heap histograms** (malloc count,
bytes, object allocations across 100 Analyze rows) have maximum zero. Preparation allocates.
Positive-control maxima: malloc count 2, bytes 4,120, frees 2, object allocations 1, retains 2,
releases 3. ARC activity in Analyze is reported, not asserted absent.

Each value below is p99 wall time in milliseconds for one preparation/destruction or one full
one-second input batch at 48 kHz with K-weighting. Hop is 480 samples, input chunks 256, and
K warm-up 4,800 samples. Window duration changes support and the number of emitted windows.

| Input precision | Accumulation | Window ms | Prepare ms | Analyze ms | Prepared buffer bytes |
| --- | --- | ---: | ---: | ---: | ---: |
| float32 | direct | 10 | 0.1698 | 4.2338 | 26,880 |
| float32 | direct | 50 | 0.0765 | 4.8756 | 134,400 |
| float32 | direct | 400 | 0.1052 | 6.3099 | 1,075,200 |
| float32 | compensatedSliding | 10 | 0.0569 | 4.8863 | 26,880 |
| float32 | compensatedSliding | 50 | 0.0652 | 4.8636 | 134,400 |
| float32 | compensatedSliding | 400 | 0.1008 | 4.5383 | 1,075,200 |
| float64 | direct | 10 | 0.0573 | 4.2794 | 26,880 |
| float64 | direct | 50 | 0.0647 | 4.6708 | 134,400 |
| float64 | direct | 400 | 0.1007 | 6.3035 | 1,075,200 |
| float64 | compensatedSliding | 10 | 0.0988 | 5.0170 | 26,880 |
| float64 | compensatedSliding | 50 | 0.0625 | 4.7482 | 134,400 |
| float64 | compensatedSliding | 400 | 0.1062 | 4.7330 | 1,075,200 |

Raw histograms, sample counts/maxima, p99, hardware/toolchain, exact profiles, per-instance
frame/availability counts, checksums, and memory geometry are retained in the artifact family.
Batch throughput is total input seconds divided by batch wall seconds; these values do not
measure individual-window latency, capture callback deadlines, process RSS, or device suitability.
No performance regression threshold is asserted.

Timing raw-distribution SHA-256: `ff10091df6666a8e699c8a88e909105de4fa160f274f74adb53070e134fcac70`.
Allocation raw-distribution SHA-256: `ca5c5efa4868f991d9c15b63f0de4e09208c39307694a4d9f2b75b81ebc2ef24`.

## Full correctness gates

All **104 xUnit cases** passed in each of debug, release, Address Sanitizer, and Thread
Sanitizer with no failures or errors. The debug gate also passed **100 Python tests**,
provenance for **85 fixtures**, dependency/link isolation, and network-denied independent
consumer execution. Fresh regeneration verified all **240 independent level cases**.
Formatting and workflow lint passed. Hosted checks and artifact audits are required on the
reviewed commit before merge; local sanitizer success is not physical-device evidence.
