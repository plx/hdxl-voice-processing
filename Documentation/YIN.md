# YIN fundamental frequency

`PreparedYINAnalyzer` consumes mono PCM on one synchronous worker and emits raw
pitch candidates, a selected estimate when available, and optional causal candidate
tracking. It has no microphone, UI, network or CPP/CPPS dependency. A missing pitch
estimate does not suppress other measurements or modify the caller's PCM.

## Profile and support

The named profile `hdxl-yin-fixed-time-2002-steps2to5` implements the fixed integration
difference, cumulative-mean normalized difference (CMND), local threshold selection
and parabolic refinement from de Cheveigné and Kawahara (2002). It omits the paper's
step 6 neighboring-time search. It does not claim binary parity with the authors,
Aubio or librosa. The [reference contract](../Tools/YIN/README.md) gives the complete
equations, selection rules, frozen tolerances and independent Python oracle.

`YINConfiguration` serializes sample rate, input precision, inclusive frequency
limits, integration length, integer hop, threshold, silence threshold, backend,
partial-tail policy and numerical conventions. All participate in the identity.
Both Float and Double inputs use Double arithmetic. There is no implicit taper,
demeaning, conditioning or resampling. Peak normalization bounds arithmetic;
exported squared differences use that scaled amplitude, not original PCM units.

With sample rate `fs`, floor `fmin` and integration length `W`, full support is
`W + ceil(fs/fmin) + 1` acquired samples. The final sample is the interpolation
neighbor. `W` defaults to `ceil(fs/fmin)` and cannot be smaller. FFT padding supplies
no observed signal. For example, 48 kHz at 50–700 Hz uses W=960 and N=1921 samples:
40.0208 ms support and 20.0104 ms earliest delivery after the support midpoint.
At 25–2000 Hz, N=3841 and these become 80.0208 and 40.0104 ms. The hop controls
emission spacing, not the number of periods observed or that inherent delay.
An integer hop of 221 at 44.1 kHz is approximately 5.01134 ms, not exactly 5 ms.

Supported configuration limits are 4–192 kHz, floor ≥20 Hz, ceiling ≤fs/4, W≤16384,
and hop between one sample and full support. These are storage/numerical limits,
not a promise that every configuration meets a device's processing deadline.
`.scalar` sums squared differences directly with compensated arithmetic; `.fft`
uses linear correlation and directly recomputes cancellation-sensitive lags.
Both FFT operands are translated by the same integration-window mean to avoid
DC cancellation; that translation cancels in the difference statistic and does
not change the reported PCM support, input RMS or peak normalization.
Numerically ambiguous local/threshold decisions can fall back to the scalar frame.
`estimatorStatistics` exposes recomputation and fallback counts.

## Processing on a worker

Prepare once, then supply consecutive chunks with explicit sample intervals:

```swift
import Foundation
import HDXLVoiceProcessing

let configuration = try YINConfiguration(
    sampleRate: 48000, inputPrecision: .float32,
    pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 480)
let profile = YINProfile(
    estimator: configuration, tracker: try YINTrackerConfiguration())
let epoch = StreamEpoch(streamID: UUID())
let analyzer = try PreparedYINAnalyzer<Float>(profile: profile, epoch: epoch)

func consume(_ output: BorrowedYINAnalysisOutput) {
    let raw = output.raw.result // Small owned value; may be retained.
    if let frequency = raw.observation?.frequencyHz {
        // Pair frequency with raw.status and raw.timing, including uncertain estimates.
        _ = frequency
    }
    // output.raw.candidates and output.raw.values(...) are borrowed only here.
    // output.tracked preserves raw and separately reports changedSelection.
}

let chunk: [Float] = Array(repeating: 0, count: 1024) // Replace with acquired mono PCM.
let interval = try SourceInterval(
    epoch: epoch, startSample: analyzer.nextInputSample,
    sampleCount: Int64(chunk.count), sampleRate: 48000)
try chunk.withUnsafeBufferPointer {
    try analyzer.process($0, interval: interval, emit: consume)
}
// At the actual end of the stream, after all chunks:
try analyzer.finish(emit: consume)
```

The analyzer is single-owner and intentionally not Sendable. Serialize calls on a
worker, outside the capture callback. Prepare/reconfigure there too. Invalid
metadata, nonfinite input and invalid optional clocks are rejected before chunk
consumption. Recursive process/finish/reset/reconfigure calls are rejected.
`cancel()` is permitted inside the consumer: the current borrow remains valid
until return, then storage is released and later frames are suppressed. The
process report gives the consumed prefix. Reset or reconfiguration can restart a
cancelled analyzer; that restart allocates fresh storage on the control path.

`finish` emits at most the earliest remaining nonempty partial frame as
unavailable/insufficientData, or discards it under the configured policy. It never
zero-pads it into a valid estimate. Repeated successful finish is idempotent.
`reset(for:)` accepts an explicit `SourceDiscontinuity`, discards pending samples
and tracker history, and reuses prepared storage. The new epoch begins at sample
zero. If supplied, a missing interval must begin at the old next input sample.
`reconfigure` prepares the complete replacement before changing existing state.

For already framed PCM, `PreparedYIN.analyze` accepts an exact observed
`AnalysisTiming`; `PreparedYINTracker` is independently usable on those borrowed
outputs. Its calls must follow the configured frame grid and epoch. Reset before
skipping frames or changing epochs. It never retains borrowed buffers.

## Results and tracking

Every local candidate remains inspectable, including candidates refined outside
the configured range. A discrete global minimum is retained as a fallback.
Candidate fields expose lag, unbounded/refined period, Hz, error, periodicity,
local/global provenance, range membership and threshold eligibility. The explicit
2e-6-sample numerical boundary rule retains both the unbounded period and its
canonicalization flag. It is not a wider acoustic acceptance range.

| Status | Meaning |
| --- | --- |
| `voiced` | First in-range local candidate below the error threshold |
| `uncertain` | Available in-range fallback, with `lowConfidence` warning |
| `unvoiced` | Silence, or nonzero constant input with low confidence |
| `unavailable` | Insufficient observed support or unsupported candidate range |

Periodicity is `max(0, 1-error)`. It is an algorithm statistic, not calibrated
probability, a speech detector, a voice-quality rating or a health assessment.
Silence is based on input RMS (default threshold 1e-7 in unit-peak PCM units).
No estimate is represented by a fabricated 0 Hz. Complete rejected frames retain
their curves/candidates; partial frames expose empty diagnostics.

The optional `YINTrackerConfiguration` is separately serialized and has its own
identity. On continuous voiced frames it scores threshold-qualified candidates
by error plus `continuityWeight * abs(log2(hz/previousHz))`, default weight 0.05.
It cannot invent a candidate or fill an unvoiced gap. Uncertain/unvoiced/unavailable
frames and explicit resets clear history. Raw output is always preserved;
`changedSelection` distinguishes the tracker choice. This preference does not
guarantee correction of octave ambiguity.

## Time, ownership and persistence

Raw timing describes the actual observed frame. Optional source-seconds and host
nanosecond anchors can be supplied through the zero-length `origin`; emitted
anchors are rebased using integer sample offsets before floating conversion.
Without supplied anchors, those clocks remain absent. A process-call completion
timestamp applies only to outputs from that call, must follow the chunk's end on
the supplied host clock, and is not reused by a later finish call. Reset accepts
a new clock origin; it does not guess continuity across a gap.

Plot tracked values at `tracked.raw.timing`. The separate `dependencyTiming`
covers the complete continuous voiced history used to choose the current candidate.
Its midpoint can be much earlier than the current frame. Its effective delay is
therefore measured from that earlier midpoint; **tracking adds no future lookahead**.
Only a small history record is retained, not the past PCM or candidate arrays.

`raw.measurementResult()` explicitly creates the shared Codable scalar result in
Hz. `tracked.measurementResult()` uses the combined identity and full dependency
timing; persist the raw measurement too for current-frame placement. Preserve the
complete profile alongside results. Optional candidate copies and intermediate
snapshots use explicit maximum-count/scalar budgets; copies and persistence are
separate allocation boundaries from prepared execution.

The independent catalog retains all difficult cases and denominators: gross and
octave errors, fine error conditional on non-gross available estimates, full-support
coverage, and partial tails. Dominant upper harmonics can produce octave errors;
noise can yield uncertain numeric fallbacks. Real-speech excerpts have unknown
pitch truth, not invented labels. Human annotations remain
[#102](https://github.com/plx/hdxl-voice-processing/issues/102), physical evidence
[#74](https://github.com/plx/hdxl-voice-processing/issues/74), and profile decisions
[#117](https://github.com/plx/hdxl-voice-processing/issues/117).

The [initial evidence](Evidence/yin.md) reports reference-budget consumption,
difficult-case denominators, lifecycle checks and host workload measurements.
