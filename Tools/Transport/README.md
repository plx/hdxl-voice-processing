# PCM transport evidence

Run with the toolchain in `Configuration/build.json`:

```sh
python3 Tools/Transport/audit_callback.py
python3 Tools/Transport/benchmark.py timing
python3 Tools/Transport/benchmark.py allocation
swift test --filter HDXLVoiceProcessingAudioTests
```

Run timing separately from allocation instrumentation and other CPU-heavy work when
comparing performance. These host observations are not device callback deadline claims.

The audit compiles the actual Core module and complete optimized Audio implementation
for macOS arm64, iOS arm64, and arm64/x86_64 iOS simulators. Both public producer entry
points must call exactly the audited private implementation. Its only external calls
are bounded `memmove` copies. It rejects indirect calls, new runtime/allocator/locking
calls, exclusive retry instructions and a retry edge into admission. The source audit
also matters: the two loops validate/copy at most 32 channels, and the byte count is
bounded by the prepared maximum. Assembly is retained under `.build/transport-audit`.
This is a compiler-specific guard, not a general proof of arbitrary machine code.

The isolated benchmark package uses the repository's pinned benchmark framework and
allocator backend. Ten configurations cover Float32/Float64, interleaved/planar storage,
1/2/32 channels, 1/128/2,048/65,536-frame chunks and 2/8/16 slots. Seven operations per
configuration exercise the first offer on a fresh instance, an accepted burst, overflow,
oversized input, malformed input, closed admission and recovery after a loss.

Each iteration prepares its queue, buffers, planar descriptors and epoch token before
measurement. Only the offer batch and its small checksum loop are timed. Worker drain,
byte-for-byte payload verification, event/counter verification and destruction are
outside measurement. The first-offer case is cold **per instance**, with an already
initialized process/runtime; it makes no process-launch claim. Large input buffers are
touched before measurement, as a native adapter must prepare its storage before capture.

Timing binaries must not link the allocation interposer. Allocation binaries measure
malloc count/bytes, object allocations, frees, retains and releases. Positive controls
must observe every capability. Every capture workload's allocation **and free histogram
maximum** must be zero, rather than merely a rounded percentile. Harness ownership can
produce retains/releases; these are retained as observed metrics and are not described
as zero ARC. Fresh uniquely named baselines prevent stale result reuse. The tool retains
raw histograms, validated p99 exports, workload receipts, environment and binary linkage
under `Benchmarks/.build/artifacts/transport-{timing,allocation}`. Batches have 1, slot-count,
or 1,000 offers, recorded per workload. Batch p99 is not individual-callback p99.

Swift tests cover FIFO wraparound, buffer expiry, all native representations, exact and
unknown gaps, oversized/invalid input, epoch replacement, sequence exhaustion, reentrancy,
concurrent producer rejection, consumer contention, slow worker bursts, 100 close/publication
races and final-owner release during a borrow. The ordinary correctness workflow runs
these under Debug, Release, Address Sanitizer and Thread Sanitizer, including sanitizer
positive controls. Native callback serialization and teardown still belong to #28/#29;
physical latency, allocation tracing under native capture, power and tuning remain #74/#121.
