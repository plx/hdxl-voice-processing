# A03 conditioning reference and host evidence

Implementation based on main `9ae5201b92c1acb458213b5632a4874269a1e78e`, collected
2026-11-04 on the development Mac13,1 with macOS 27.0.1, Xcode 27.0, and Swift 6.4.
These are mathematical and host measurements. Physical-device memory, latency, energy,
thermal behavior, and microphone bandwidth remain under #74; policy review is #98.

## Independent reference calibration

The pinned Praat 7.0.02 executable is verified by SHA-256 before execution. Original
precision-rounded inputs are exported as Float64 WAV. Numeric queries export the output
axis, selected/full samples, and predecessors; an independent scalar raw pre-emphasis
formula produces expected conditioned output. No native implementation generates its
own numerical golden. The source and licensing records are in provenance; no GPL
implementation code is incorporated.

Both Praat menu pre-emphasis commands scale peak amplitude to 0.99 in the pinned binary.
The seven-sample calibration confirms that raw first sample 0.25 becomes
0.283645005104449 under menu scaling; raw peak 0.8725695695182821 is scaled by
1.134580020417796. Native conditioning instead preserves raw gain. Attention #97 records
this distinction.

The committed matrix contains 184 cases across both precisions, including 60-second
16/44.1/48 kHz sources, identity/2×/general ratios, unusual uncached rational phases,
maximum depth, short boundaries, count ties, impulse/step/DC/tone/sweep/noise, and gain
and pre-emphasis variants. Large vectors independently export 64 selected positions;
short vectors export every position. All source hashes are checked before/after native
processing. Preview has a separate uncached scalar convolution oracle and independent
spectral/support/clock tests; it is not claimed to match the whole-interval reference.

Fixture SHA-256: `feb8bafe6d2af61ef61e67842704b31b04448aa628e3fe42482e3b0ab38ab32f`.
Composite generator SHA-256: `a10f1e527982979837bc070494eadadcb8a5e15161f4eee451b59b23b6b9e340`.

The expanded native reference run passed both precisions. Maximum observed error divided by
its committed budget was **0.017529 (Float)** and **0.021067 (Double)**. This is a matrix
observation, not a universal bound. Exact source-coordinate, boundary, delay, gain, reset,
reentrancy, cancellation, and 60-second integer-clock tests also passed. Full debug, release,
Address Sanitizer, and Thread Sanitizer each passed **86 xUnit cases** with zero failures or
errors. The offline developer-tool suite passed **91 Python tests**, including reference
integrity and benchmark evidence rejection cases. Provenance checks passed for 84 fixtures;
independent-consumer dependency/link and network-denied execution checks also passed.

## Host performance collection

The 120-case conditioning matrix records three operations per case: preparation,
prepared conditioning, and conditioning plus rectangular1024/hop256 framing and FFT.
Preparation includes conditioner destruction; prepared operations include reset and
finalization. Input synthesis and downstream pipeline setup are excluded. Every row
consumes an entire declared interval, not a single capture callback.

`workloads.json` includes exact profiles, rates, durations, chunks, frame/hop/FFT sizes,
delay, scalar workspace and input bytes, output/frame counts, and checksums. Its preflight
checks direct versus Fourier energy and exact checksum agreement across chunk sizes.
Scalar bytes exclude object/allocator bookkeeping and opaque Accelerate setup. Timing
and allocation binaries are separate, pinned, and linkage-checked; raw histograms and
p99 exports retain framework scaling one. The dedicated hosted job runs the two modes
sequentially and retains all JSON/log evidence.

Final local timing and allocation modes run sequentially after correctness and reference
validation. These development-host observations have no regression thresholds. The reviewed
head's dedicated CI evidence will be checked separately before merge. Host throughput does
not establish physical capture deadlines or device suitability.

## Local timing observations

All **360 timing rows / 720 metric distributions** passed with 30 samples each after three
warmups. Allocator instrumentation was absent. Each value below is p99 wall time in
milliseconds for one full source interval or one conditioner preparation/destruction.

| Profile | Precision | Source→target Hz | Duration s | Prepare ms | Condition ms | Condition + FFT ms | Conditioner scalar bytes |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Praat7 | float32 | 48000→10000 | 1 | 6.902 | 8.268 | 10.454 | 1,282,984 |
| Praat7 | float64 | 48000→10000 | 1 | 1.762 | 8.947 | 10.779 | 2,565,968 |
| Preview | float32 | 48000→10000 | 1 | 0.071 | 3.105 | 5.154 | 9,676 |
| Preview | float64 | 48000→10000 | 1 | 0.090 | 3.474 | 5.486 | 19,352 |
| Praat7 | float32 | 48000→10000 | 60 | 229.689 | 524.013 | 649.967 | 81,031,272 |
| Praat7 | float64 | 48000→10000 | 60 | 87.060 | 553.081 | 674.291 | 162,062,544 |
| Preview | float32 | 48000→10000 | 60 | 0.072 | 176.468 | 311.593 | 9,676 |
| Preview | float64 | 48000→10000 | 60 | 0.071 | 200.061 | 341.275 | 19,352 |

These rows use input chunk1024 and preview output capacity256. Full rate/target/chunk coverage
is retained in the artifacts. A 60-second row is whole-interval throughput, not per-chunk p99.

Timing raw-distribution SHA-256: `479746a0255ec93f60b9721883d52b4ceea800cb345872e6531708ffed2b1416`.

## Local allocation evidence

All **361 allocation rows / 2,527 metric distributions** passed with 30 samples each.
The 240 prepared conditioning/pipeline rows produced **720 zero-maximum heap histograms**
(malloc count, malloc bytes, object allocations). Preparation is measured separately and
allocates. ARC retain/release counts are reported rather than assumed to be zero.
The positive control observed these maxima:

| Counter | Positive-control maximum |
| --- | ---: |
| retainCount | 2 |
| releaseCount | 3 |
| objectAllocCount | 1 |
| mallocCountTotal | 2 |
| mallocBytesCount | 4120 |
| freeCountTotal | 2 |

The allocator interposer was linked and verified in this mode. Both modes used an unchanged
exact dependency lock. Allocation raw-distribution SHA-256: `d9b7122a2986a99695cd135f90b66862331b5d13bf302ab85ef16e249aac9afa`.
