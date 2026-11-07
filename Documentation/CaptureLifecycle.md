# Capture and analysis lifecycle

`CaptureLifecycle` in `HDXLVoiceProcessingAudio` owns a foreground native capture
adapter, its bounded PCM transfer, and one serial analysis worker. It supports
native macOS 27 and iOS/iPadOS 27. Construction does not inspect authorization,
create an engine, activate a session, prompt, or capture. Host configuration,
permission UX, signing and iOS session ownership remain application responsibilities.
See [host integration](HostCaptureIntegration.md), [macOS capture](MacOSCapture.md)
and [iOS capture](IOSCapture.md).

## Commands and transitions

Commands and events run on the main actor, outside the audio callback. The worker
owns its mutable prepared scheduler on a separate actor. No result task is created
per callback or per frame.

| State / condition | Command or event | Outcome |
| --- | --- | --- |
| Idle, stopped, failed or fully reclaimed interruption | `prepareStart()` | Single-use, owner-bound intent; permission pending; no audio effects |
| Permission pending | Matching `start(intent:...)` | Configuring; current authorization and native ownership checked; worker prepared for actual input |
| Configuring | Native and analysis preparation succeed | Configuration announced, calibration compared, then running and results |
| Permission pending/configuring | Stop, cancellation or background | Intent invalidated; suspended work cannot revive capture; cleanup reconciled |
| Running | Native route, format, session, interruption or media-service change | Admission closes; old result publication stops; discontinuity and calibration-revalidation events; asynchronous cleanup |
| Interrupted after cleanup | Host accepts `completion.recoveryIntent` with `prepareResume` | Fresh start intent; the host supplies current settings and a fresh iOS lease |
| Any newer stop/start/reconfiguration | Previously issued recovery intent | Rejected; delayed host system callbacks cannot undo Stop |
| Running | `prepareReconfiguration()` | Stop/discard/reclaim old operation; grant fresh intent only after successful cleanup |
| Reconfiguration awaiting cleanup | Explicit Stop or task cancellation | No new intent; cancellation wins |
| Active operation | `stop()` / `cancel()` | Admission and publication close immediately; stopping, then stopped or failed |
| Active operation | `finish()` | Stop and await native plus worker retirement; return the completion for that operation |
| Stopping | Concurrent stop/finish | Same retirement operation and terminal report; no duplicate completion |
| No active operation | Repeated stop/finish | Existing completion; no duplicate terminal event |
| Configuring/running/stopping or an existing pending intent | New start/prepare | Typed conflict; existing operation remains owned |
| Any setup/worker/cleanup failure | Failure | Cleanup still runs; failed completion retains typed recovery context |

Only Stop/cancel and background forwarding are supported synchronously from the
event handler. Queue start, resume or reconfiguration commands for a later control
turn. Other reentrant commands report a conflict. The handler must return promptly
and bound any retained history. Result subscription/coalescing policy belongs to
#54; this coordinator provides synchronous delivery and a single completion per
operation, rather than an implicit unbounded stream.

## Starting and choosing a recipe

A host obtains the intent **before** awaiting its explicit permission action.
The library never requests permission. A late answer cannot use an intent that
Stop invalidated. On iOS, acquire a fresh cooperative `IOSCaptureHostLease` under
the [session ownership contract](IOSCapture.md) for every start or resume.

```swift
let lifecycle = CaptureLifecycle { event in
    // Update bounded host state. No implicit persistence or export occurs here.
}
let intent = try lifecycle.prepareStart()
// Await the host's permission UX if needed; Stop may invalidate intent meanwhile.
let configuration = try await lifecycle.start(
    intent: intent,
    request: CaptureRequest(channelSelection: .arithmeticMean, processing: .measurement),
    buffering: CaptureBuffering(),
    workerLimits: CaptureLifecycleWorkerLimits(),
    lease: nil, // Native macOS. iOS requires the host's current single-use lease.
    analysis: { format, channels in
        try AnalysisScheduleProfile(
            inputFormat: format, channels: channels,
            levels: LevelConfiguration(
                sampleRate: Int(format.sampleRate),
                inputPrecision: format.encoding == .float32 ? .float32 : .float64,
                windowLength: 400, hopLength: 200,
                accumulation: .compensatedSliding, weighting: .none))
    })
```

The Sendable profile factory runs on the worker using the **effective** native
format and requested channel selection. It must choose an explicit valid recipe;
no rate, precision, channel or algorithm substitution is made by the coordinator.
The profile identity and actual observation are announced before results. A host
can reject observed conditions by calling Stop from `configured`; no worker result
is published after that decision. Unsupported whole-interval profiles fail
continuous preparation. A failed setup still stops native capture and releases
all owned resources.

Capture may already be filling the bounded transfer while analysis is prepared.
If that preparation or host publication is slow, transport overflow remains an
explicit PCM gap. Setup is not a promise of lossless recording.

## Resumption preserves Stop

The package does not restart itself. After an interruption, the completion can
contain a `CaptureLifecycleRecoveryIntent`. A host choosing automatic compatible
resumption saves that intent, waits for its own session/policy conditions, and
calls `prepareResume(intent)` on a later control turn. It then starts with current
configuration validation and a fresh iOS lease. Explicit Stop, a newer start or
reconfiguration invalidates the recovery intent, including one saved by a delayed
notification handler. Do not call `prepareStart()` from a delayed automatic-resume
callback: that method expresses a **new host action**, not permission to revive an
old interrupted operation.

A recommendation or active-session notification alone does not establish compatible
capture or exclusive ownership. The host checks its policy; the new configuration
is observed again. Calibration comparison never rewrites stored baselines.

## Epochs and discontinuities

Each published configuration uses one stream identity with a checked monotonically
increasing epoch. Stop/change announces its exact successor before any future valid
value. New format, route, processing request, selected channels or analysis recipe
use fresh capture storage and a newly prepared scheduler. Unpublished failed starts
do not skip a published epoch. Old callbacks and late worker batches are rejected
by operation generation, even while an earlier cleanup is suspended. Cancelling
the task awaiting `start` also stops the operation when cancellation comes from
a synchronous configuration/calibration/running handler; publication is part of startup.

PCM loss is different from configuration change. The transfer scheduler emits its
gap and analysis-reset events before subsequent frames, preserving original source
positions. Its analysis continuity epoch advances while the capture configuration
epoch remains unchanged. Each prepared worker receives a fresh analysis stream
identity, announced as `initialAnalysisContinuityEpoch` in its configuration. A
gap advances that worker's continuity sequence; a later configuration uses a new
analysis stream, so native result intervals can never alias a prior gap region.
Missing duration is unknown unless the transfer actually
measured the missing interval; no zero-filled audio or concatenated continuity is
invented. See [shared scheduling](SharedScheduling.md).

## Bounded work and cleanup

A worker pull consumes at most one transfer event. Its output array is limited by
`maximumResultEvents` (default 256, allowed 1...4096). Exceeding capacity cancels the
batch and fails explicitly; a partial scientific batch is not silently published.
Choose capacity with the maximum accepted input chunk and recipe hop sizes in mind.
There is one pull/publication task and at most one owned batch in flight. These
bounds do not bound history that a host deliberately retains. PCM storage retains
its separate configured ring budget.

Stop discards queued analysis and incomplete windows. It does **not** certify a
complete recording or flush a durable sink. Its order is:

1. Invalidate intents and old-generation publication; cancel worker/startup tasks.
2. Close native admission and stop the engine outside SDK notification callbacks.
3. Reconcile suspended startup, callback retirement and permitted session release.
4. Wait for the worker, cancel its scheduler and release scratch/transfer references.
5. Release the adapter/observers and publish one typed completion.

`finish()` binds to the operation it stopped; another caller starting later cannot
replace that caller's terminal result. Native activation or an already-running
bounded DSP unit is not forcibly preempted. Deinitialization starts the same
retirement without retaining the public owner; explicit `finish()` is the observable
barrier when ownership will be reused. Reclamation and recovery latency depend on
workload and platform and have no universal hardware-independent threshold.

The completion retains at most a primary failure and one distinct cleanup failure,
plus the observed iOS session disposition. Failure values contain typed stage,
reason, epoch and recovery action, not PCM, localized error strings, paths or device
IDs. Configuration observations may contain private route identity and must not be
printed/exported wholesale. Neither diagnostics nor lifecycle events retain audio.

## Verification and physical follow-up

Deterministic fake adapters exercise delayed startup/cleanup, stop versus
reconfiguration, late worker batches, stale native events, host-controlled recovery,
backgrounding, setup/cleanup failures, handler reentrancy, exact-once completion,
concurrent repeated stops and deinitialization. Real Float/Double PCM passes through
the prepared worker, with checked channel selection, values, history resets and
gap-before-reset-before-frame order. A full levels/YIN/CPPS recipe matches direct
memory analysis across a channel-selection reconfiguration, including profile
identity, source epochs, fresh history and retired transfer storage. Native adapter
tests verify assigned epochs
before tap publication and observer invalidation after retirement.

Run `swift test --filter 'lifecycle|iosCapture|macCapture'` during development and
all required lanes in [CONTRIBUTING](../CONTRIBUTING.md) before merging. Device builds
are unsigned; software/fake evidence is not physical capture evidence. Both host
probes also execute the public coordinator's late-intent rejection and idempotent
finish without creating native capture.

Run `python3 Tools/Capture/lifecycle.py` for release resource evidence. The probe
runs ten trials for each of eight Float/Double, mono/stereo and ring-size combinations.
Each trial processes known level input before and after a host-approved interruption
resume, checks values/epochs/completions, and verifies that both weak transport
references and fake observer callbacks retire. It records initial setup,
interruption-to-retirement, resumed setup and explicit-stop retirement durations in
monotonic nanoseconds. Analysis runs outside the measured phases. Raw trials,
nearest-rank p50/p95/p99, means/extrema, profile/source hashes and environment are
retained in `.build/capture-lifecycle-evidence/` and CI. Trials include the first
iteration in an already-initialized process; they are neither cold-process nor
native-engine measurements. No universal duration threshold is imposed.

Physical Mac/iPhone route changes, interruption recovery and reclamation measurements
remain **pending #74** under the owner-approved bring-up amendment. Repeat the host
protocols with actual format/profile/route, buffer capacities, OS/build, cold/warm
state and scenario recorded. Measure change-to-retirement, host-approved-resume-to-
first-valid-output and resource release separately from algorithm latency. Retain
distributions and observed loss/failures; hardware findings must drive later fixes
and support-matrix updates. Decision review is tracked in #137; broader native
acceptance and sustained qualification remain #59 and #64.
