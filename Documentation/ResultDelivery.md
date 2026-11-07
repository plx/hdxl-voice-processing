# Bounded results and runtime diagnostics

`BoundedResultPublisher<Value>` in the core product delivers owned `Sendable`
values from one worker/control owner. Each `ResultSubscription` has an independent
fixed ring buffer and one logical iterator. Publishing never awaits a consumer or
creates a task per result. Short mailbox locks run on worker/consumer paths, never
in a capture callback. Consumer diagnostics have a separate lock that publication
never acquires.

| Policy | Full-buffer behavior | Intended use |
| --- | --- | --- |
| `.newest(capacity:)` | Replace the oldest queued publication; count intentional coalescing | Current-state displays |
| `.failOnOverflow(capacity:)` | Reject the incoming publication; drain accepted values, then throw overflow once | Bounded handoff to a sink requiring every accepted result |

Capacity is explicit, from 1 through 4096 publications. A core publisher permits
1–64 active subscribers, default 16. The capture lifecycle permits 16. There is no
shared subscriber backlog. Lag or overflow affects only that subscriber. Strict
delivery is not durable storage or a lossless recording guarantee; sinks must bound
their own work and treat overflow as failure.

These bounds count publications. Generic callers must also bound payload contents
and retained downstream history. There is one additional value in a pending handoff
and at most one optional publisher replay. Native snapshots retain at most three
scalar metric results and bounded current control state, with no PCM or scratch.

The mailbox implements overflow explicitly. Compare Apple's [AsyncStream buffering
policies](https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy);
there is no ignored `yield` result or implicit unbounded stream. `publish` reports
accepted, coalesced and overflowed subscriber counts. Receipts and subscription
`statistics` retain cumulative counts, occupancy, high water and observation lag.
Counters saturate instead of wrapping.

## Capture lifecycle

Prepare an intent, subscribe, then perform host-owned permission/session handling
and call `start` with that intent. See the [lifecycle guide](CaptureLifecycle.md)
for startup arguments and host responsibilities.

```swift
let lifecycle = CaptureLifecycle(diagnostics: .sampled)
let intent = try lifecycle.prepareStart()
let display = try lifecycle.subscribeResults(.newest(capacity: 1))
let export = try lifecycle.subscribeResults(.failOnOverflow(capacity: 128))
```

Subscriptions belong to one operation and end on completion, including startup
failure or interruption. Prepare the next start/resume/reconfiguration before
subscribing again. A late subscriber to a completed operation receives its terminal
reason. Reconfiguration never revives an earlier subscription.

Consume with `for try await`. Use `defer { subscription.cancel() }` when a consumer
can stop early while another copy remains retained. Dropping the last subscription
or iterator lease releases its buffer. Copies share cancellation. Overlapping
`next()` calls and a second logical iterator are rejected. Publishers retain
subscriber registrations weakly.

The first terminal reason wins. Finish drains accepted publications, then returns
nil. Failure drains accepted publications, throws once, then returns nil.
Cancellation discards queued publications and wakes a waiting consumer; a value
already handed off can finish observation while cancellation races it. Capture
failure first publishes its typed lifecycle completion, then throws `upstreamFailure`.
An already overflowed subscriber keeps its own overflow reason. Owner disposal
reports `publisherReleased`.

`CaptureResultSnapshot.event` is the exact event that produced a snapshot. Strict
consumers can process the event sequence; coalesced displays use retained state.
The three `frames` slots keep complete immutable `ScheduledFrame` values and
channel maps: profile, native validity/applicability, coverage, acquisition and
continuity epochs, and dependency timing. A new level result cannot erase an
unavailable pitch result. Nonrunning states, gaps, resets and discontinuities clear
stale frames. Calibration revalidation and gap evidence persist for the operation.

`loss` describes published gap evidence, including unknown extents; missing duration
is never inferred from timestamps. `runtime.capture` contains actual transfer drop
and fault counters, sampled again after retirement. This preserves loss that stop
prevented the worker from announcing as a gap. `hasReportedAcquisitionLoss` combines
both sources. False means no reported loss, not proof of healthy capture. Intentional
display coalescing remains separate in the delivery receipt.

`latestResultSnapshot` allows control-plane inspection; worker observations and
final transfer counters can update telemetry between publications. Completed state
remains until the next prepare-start operation. The original synchronous `onEvent`
hook remains available and must return promptly.

## Clock boundaries

Scientific timing never changes to make delivery appear current. Receipt timestamps
describe publication and observation after `next()` resumes, in monotonic host
nanoseconds. They do not claim physical display presentation.

| Observation | Exact boundary |
| --- | --- |
| Capture block start to worker | First dequeued block's supplied first-sample host anchor → actual worker dequeue observation |
| Processing | Start → finish of one successful synchronous worker drain |
| Worker to publication | Drain finish → start of publication of its nonempty result batch |
| Subscriber lag | Publication → consumer observation in `next()` |
| Host rendering work | Explicit synchronous closure passed to `ResultRenderingDiagnostics.measure` |

Missing or reversed clocks yield unavailable, not zero. Processing summaries exclude
idle polls. Block-start latency includes the age of the first source sample; it is
not callback execution or queue-enqueue residence. No new enqueue timestamp is
collected in the callback. The [AVAudioTime host clock](https://developer.apple.com/documentation/avfaudio/avaudiotime)
and worker use the same mach-based domain converted to nanoseconds. Unknown clocks
and nominal source projections never become measured latency. Each batch has one
first-publication observation; each result receipt also has its own timestamp.

`RuntimeLatencySummary` keeps bounded count, unavailable count, last/minimum/maximum
and sum. Saturated totals cannot produce a valid mean. Raw trial or distribution
export is an explicit bounded host/probe operation.

## Instrumentation and privacy

Disabled mode adds no optional processing timers or signpost records. Reliability
counters and publication/observation stamps remain because delivery semantics need
them. Sampled and detailed modes retain scalar timing summaries; sampled admits
every sixteenth signpost group and detailed every group. Worker groups count drain
attempts, including idle polls. Both modes use the [shared instrumentation](Instrumentation.md)
facade, budgets, sampling and system/compiled-out sink behavior.

Worker `AnalysisFrame`, `CaptureHandoff`, `Dequeue`, `Overrun` and `Reset` observations
are separate from `ResultPublication`, consumer `ResultDelivery`, and explicit host
`Rendering`. Handoff/dequeue signposts are worker observations after a drain;
timestamp-derived block latency is retained separately. Rendering measures the
supplied host work, not compositor scheduling or presentation. Lexical scopes close
on errors and never cross an `await`.

Ordinary telemetry contains numeric counters/timestamps and fixed vocabulary, with
no PCM, text, private paths, route IDs, calibration values or dynamic per-buffer
messages. Snapshots can contain host-private acquisition metadata for consumers;
this is never automatically serialized into telemetry. Audio recording, diagnostics
containing samples and persistence remain explicit host operations.
Physical evidence remains pending [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
Capacity and terminal policy review is tracked in [#139](https://github.com/plx/hdxl-voice-processing/issues/139).

## Reproducible software evidence

Run `python3 Tools/Capture/delivery.py` with the declared Xcode and Python toolchain.
It runs the release `captureDeliveryEvidenceTrials` test and validates 36 trials:
levels and levels/YIN/CPPS, all three diagnostic modes, two overload scenarios,
and three repetitions. Mode order rotates between repetitions. Each trial uses a
fresh real serial analysis worker and the capture result-delivery bridge, with
44.1 kHz mono Float32, 2048-frame blocks, four PCM slots and sixteen producer bursts.
This controlled producer does not operate a native engine, audio session or lifecycle
pump. Public lifecycle integration and both native hosts have separate synthetic tests.

Four blocks per burst exercise display coalescing without PCM loss. Eight blocks per
burst force four accepted and four rejected blocks before draining, sustaining known
PCM loss across every burst. A fast strict consumer reads each publication; a
capacity-one display reads every fourth burst; a stalled strict consumer has eight
slots and must fail on its ninth publication. Tests preserve complete fast-consumer
event order and verify clock-free scientific fingerprints across modes/repetitions,
including available CPPS results. Native lifecycle tests separately compare complete
frames with direct-memory analysis in every diagnostic mode.

`.build/capture-delivery-evidence/` contains the exact environment, source hashes,
test report, raw `trials.json`, and `distributions.json`. Nearest-rank p50/p95/p99,
minimum/maximum/mean and sample counts describe worker calls, optional internal
timers, publication, subscriber lag, and queue depth. Disabled optional timing has
zero samples; it is never reported as measured zero latency. Paired sampled/detailed
minus disabled totals retain all three repetitions without a universal speed gate.

Whole worker-call timing includes the actor hop; internal processing covers only
the synchronous drain. Publication timing excludes consumer verification. The
external end-to-end observation runs from the synthetic block stamp to the first
metric result observed from that block's drain. It is not an acoustic-support-to-screen
measurement. Signal preparation, checksums, JSON formatting and final validation
are outside the measured worker-call/publication intervals, though test orchestration
still affects scheduling. These controlled trials establish bounded behavior and
retain comparative measurements; hardware deadline, thermal, energy and physical
capture/display evidence remain deferred to #74.
