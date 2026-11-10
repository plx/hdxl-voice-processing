# Optional SWIPE-prime pitch analysis

`SWIPEPrimeConfiguration` names the original, bounded
`hdxl-swipe-prime-centered-2008` profile. It implements SWIPE′, the first/prime
harmonic variant described by Camacho and Harris. It is a separate optional
estimator from YIN. Its complete mathematical conventions, licensing route,
independent reference generation, comparison rules, and numerical budgets are in
the [reference contract](../Tools/SWIPE/README.md).

## Prepare once and borrow the results

```swift
let configuration = try SWIPEPrimeConfiguration(
    sampleRate: 48_000,
    inputPrecision: .float32,
    pitchFloorHz: 70,
    pitchCeilingHz: 700,
    hopLength: 480
)
let analyzer = try PreparedSWIPEPrimeAnalyzer<Float>(
    configuration: configuration,
    epoch: epoch
)
try pcm.withUnsafeBufferPointer { samples in
    try analyzer.process(samples, interval: interval) { output in
        let result = output.result
        // result is owned scalar metadata. Every output buffer is borrowed only
        // until this callback returns; copy explicitly with an export budget.
        consume(result)
    }
}
try analyzer.finish { output in consume(output.result) }
```

The caller supplies mono PCM, its exact sample rate, and an uninterrupted integer
source interval. No microphone, audio engine, UI, network request, or runtime
model is involved. Float and Double inputs have separate profile identities;
the spectral and candidate arithmetic is Double for both. Prepare and process on
a single analysis worker, outside the real-time capture callback.

Preparation creates all Hann windows, FFT plans, auditory interpolation weights,
normalized prime-harmonic kernels, candidate grids, and scratch storage. The
frame estimator `PreparedSWIPEPrime` also accepts an already formed observed
support directly. `executionStatistics` reports owned buffer bytes and the
number of complete frames analyzed. Object bookkeeping and opaque FFT setup
tables are excluded from that byte count.

## Interpret strength and availability

An observation retains discrete and refined frequency and pitch strength, the
selected candidate index, whether refinement succeeded, and whether strength
passes the configured threshold. Strength is signed and uncalibrated; it is not
a probability and is never copied into `ScalarEstimate.confidence`.

`voiced` means the numeric observation passes the strength threshold. `uncertain`
retains a numeric observation and a `lowConfidence` warning. Silence and a
constant nonzero signal are `unvoiced`, with separate reasons. Insufficient
observations and nonzero signals with no usable window energy are `unavailable`.
An unavailable candidate strength is nil; zero and negative strengths remain
numeric values. `qualityReason` can describe an available warning, whereas
`unavailability` is nonnil only when the frame has no observation.

`measurementResult()` exports F0 in hertz using the exact profile identity and
timing. It preserves uncertain availability and leaves generic confidence nil.
For diagnostics, borrowed output exposes each ordinary magnitude spectrum,
raw auditory loudness vector, evaluated window strengths, blended candidate
strengths, and requested kernel rows. `exportCandidates(maximumCount:)` and
`exportIntermediates(policy:kernelCandidateIndices:)` make bounded owned copies
outside the processing storage guarantee. The intermediate budget counts every
copied scalar or index slot, including nil strength slots and repeated kernel
requests; partial frames expose no intermediate cells.

## Timing and continuity

All spectral windows are centered inside the longest required acquired support.
The reported frame center is the midpoint of that entire observed interval;
the minimum algorithmic delay is half its duration. A shorter output hop does
not shorten this dependency. The profile identity includes the pitch range,
grid resolution, hop, threshold, and every spectral convention.

The stream starts its frame grid at the supplied origin. `finish` emits at most
the earliest nonempty partial frame as insufficient data, or discards it when
configured. It never pads acquisition. Repeated finish is idempotent. Invalid
PCM, source intervals, or clock completion timestamps are rejected before
consumption. Optional source and host anchors are rebased onto each frame;
absent clocks stay absent and a process-call completion timestamp is not reused
by a later finish call.

`reset` requires an explicit discontinuity, discards pending PCM, and restarts
the local sample grid at zero. Ordinary resets reuse prepared storage.
`reconfigure` prepares the complete replacement before changing state. `cancel`
may be called from the output callback: the current borrow stays valid, the
returned process report names the consumed prefix, and no later frame or tail
is emitted. Reset after cancellation prepares replacement storage. Other
reentrant calls are rejected.

## Evidence and limitations

The independent fixture catalog covers 74 cases, including harmonic and missing
fundamental signals, salient upper harmonics, inharmonic mixtures, transitions,
noise, boundary impulses, extreme scales, both precisions, three input rates,
and three licensed speech slices. Native tests compare every retained spectrum,
loudness value, window strength, blended candidate, selected result, and kernel
probe within the budgets frozen before Swift implementation. They repeat those
comparisons through batch and irregular streaming delivery.

The profile has a documented pure-tone bias: the independent oracle missed the
initial 10-cent goal before native implementation. The declared tone regression
ceiling is 50 cents, while the harmonic-complex ceiling is 20 cents. The original
goal misses remain in reports and [follow-up #162](https://github.com/plx/hdxl-voice-processing/issues/162).
Native parity budgets were not relaxed. Corpus recordings do not have F0 ground
truth: the reports retain accepted coverage and support-aligned agreement with
YIN, without presenting estimator agreement as accuracy or claiming universal
superiority. Actual acoustic/device measurements remain separate follow-up work.
