# Foreground iOS measurement capture

`IOSMicrophoneCapture` in `HDXLVoiceProcessingAudio` supports native iOS/iPadOS 27.
Construction does not inspect permission, obtain the shared session, create an
engine or capture audio. Mac Catalyst and background recording are outside this
adapter's baseline. The host owns permission UX, its usage description, signing,
foreground transitions and coordination with every other audio feature.

## Session ownership and startup

Use `prepareStart()` from the user's Start action **before** awaiting permission.
The returned single-use intent belongs to that adapter. `stop()` and
`enteredBackground()` invalidate pending intents, so a late permission response
cannot revive a stopped operation. Pass the same intent to `start`; the adapter
rechecks authorization and never prompts. Unknown, undetermined, denied and
restricted permission are typed failures.

`IOSCaptureHostLease` is the host session owner's explicit statement of activity
and a cooperative agreement lasting through startup and `finish()`. AVAudioSession
has no public active-state getter; a nonzero sample rate is not activation proof.
An unknown activity fails before native effects. A lease is single-operation,
not an exclusive system lock. Before another host feature changes or reuses the
session, invalidate the lease and await `finish()`; keep that agreement through
suspended activation/deactivation. The library cannot arbitrate unrelated session
users. It detects observed settings/route changes and stops conservatively.

| Request / lease | Adapter side effects |
| --- | --- |
| Host managed / active | Validate category and requested processing; construct its own engine. Never configure, activate or deactivate the shared session. |
| Host managed / inactive or unknown | Typed conflict; no engine or session mutation. |
| Delegated / inactive, activation permitted | Apply `.record` / `.measurement` with no category options for the measurement request, optionally set preferred sample rate, then await activation. |
| Delegated / inactive, activation denied | Typed conflict before session mutation. |
| Delegated / active | Validate the existing recording-capable category and requested processing; do not configure or activate a session already in use. |

For `observeHostConfiguration`, the existing category must be recording-capable;
the adapter does not select a substitute chat profile. A preferred format remains
a preference. Only its sample-rate hint is applied during delegated inactive
configuration; native channel count, encoding and layout are observed rather than
silently forced. Explicit worker channel selection happens after transfer.

Delegation grants configuration, activation and deactivation separately. On
teardown, the adapter deactivates only when it successfully activated this
operation, deactivation was granted, the lease remains valid, the session is not
known inactive, and the observed shared settings/route still match. Every outcome
has a `sessionDisposition` event. A skipped deactivation is not a claim that the
session is inactive. Failed deactivation also fails `finish()`. The adapter does
not restore a stale snapshot of shared settings; successful delegated changes
remain host-owned even if a later step fails.

The [development host](../Examples/IOSCaptureHost/README.md) demonstrates an
alternative: it explicitly configures/activates its exclusively app-owned shared
session and gives the adapter an active, host-managed lease. It owns cleanup even
when capture startup fails. A multi-feature host needs its own session arbitration.

## Observed configuration and bounded transfer

The session records native tap sample rate, channels, Float32/Float64 encoding,
layout, channel policy, epoch, input identity and processing observations. A
separate `audioSession` observation records effective hardware sample rate, I/O
buffer duration, category, mode/options and the specific
`echoCancelledInputEnabled` feature. These queries occur after activation and
before engine startup; detected changes invalidate that configuration.

Measurement mode minimizes some system processing; it does not prove raw audio.
The adapter disables and verifies engine voice processing and rejects conflicting
session mode or enabled session echo-cancelled input. General automatic gain
control and noise suppression remain unknown. A disabled session echo-cancelled
input feature does **not** prove the absence of cancellation elsewhere; the common
`processing.echoCancellation` stays unknown unless a known enabled stage proves
some cancellation is present. Preserve these distinctions in exported metadata.

Input UID and a stable SHA-256 fingerprint of the observed route remain local in
the observation. Hashing is identity normalization, **not anonymization**. Do not
print a complete session, error or event: it can contain private acquisition
identity. Render allowlisted categories/codes and obtain host consent for exports.

`CaptureBuffering` prepares bounded native storage off the callback. The exact
`PreparedCaptureTap` bridge is shared with macOS: borrowed read-only native buffers
are copied into preallocated slots, with no callback task creation, logging, file
I/O or analysis. Oversized chunks, queue overflow, clock discontinuity and malformed
input produce explicit loss/failure states. Requested tap frames are a hint, not
a guaranteed callback size. Retain one serial worker consumer; consume borrowed
bytes inside `withNext`, or use `session.makeSchedule` with the observed channel
policy. See [PCM transfer](PCMTransfer.md) and [shared scheduling](SharedScheduling.md).

## Lifecycle, completion and calibration

The main-actor owner uses iOS 27 async activation/deactivation and typed session
active/inactive/resumption messages. Route, engine-format, media-services
lost/reset and host background changes are relayed to a later control turn;
notification callbacks never tear down the engine or call user handlers directly.
A bounded control poll also detects callback faults, lease invalidation and shared
configuration changes. No notification automatically restarts capture.

Each successful start uses a new configuration epoch. Stop, interruption and
configuration changes close admission and report a `SourceDiscontinuity`; unknown
missing sample extent stays nil. Route changes use `routeChange`, settings/engine
changes use `profileChange`, media-services changes use `explicitReset`, and
stops/interruption/background use `pause`. A resumption recommendation is
informational. The host must prepare a new intent, resolve session ownership and
explicitly start again. Full automatic recovery belongs to #43/#59.

`stop()` is synchronous admission closure. Always await `finish()` **and** the
worker's completion before accepting an outcome. `finish()` waits for suspended
activation, retained callback references and permitted deactivation; it preserves
terminal faults published after Stop. A stopped event alone is not a successful
recording receipt. Keep the owner alive through completion.

An optional `CaptureCalibrationContext` compares saved acquisition conditions with
the new observation before engine start. Known differences report incompatible;
unknown fields report indeterminate, never a compatibility certificate. Matching
observed fields do not validate room, distance, microphone response, numerical
profile or a fitted calibration model. Conditions changing during capture emit
`calibrationInvalidated`. The adapter never modifies the supplied context or
relabels an incompatible calibration as valid.

## Software and physical evidence

Run all six root verification lanes from [Contributing](../CONTRIBUTING.md), plus:

```sh
python3 Tools/Capture/ios_host.py
python3 Tools/Capture/benchmark.py timing
python3 Tools/Capture/benchmark.py allocation
```

The iOS host lane builds an unsigned device app and executes a synthetic-only host
test plus app launch on a disposable iOS 27 Simulator. It verifies cancellation
before authorization, redacted errors, sample-preserving bounded transfer, closed
queue drainage and gap rejection. It checks the compiled usage description and
27.0 minimum, and rejects background declarations. No permission request, session
activation or microphone capture occurs in this path. Receipts retain the actual
runtime/build, source revision, dirty-tree status, test count, checks and binary
hashes; raw xcresults and audio are not uploaded.

Deterministic controller tests use injected authorization/session/engine providers
on macOS, including suspended activation and deactivation, cancellation, session
conflicts, calibration, late faults and no automatic restart. They are policy/race
tests, not a device audio path. Both iOS Simulator architectures and device builds
separately compile the real backend.

The shared callback benchmark measures the exact production bridge on macOS with
synthetic native buffers: forty timing/allocation workloads, positive allocator/ARC
controls and per-workload checks. This measures software callback work only,
excluding SDK delivery before the callback. It is **not iOS callback profiling**.
Physical iPhone/iPad callback duration/allocation, route behavior, permission and
interruption journeys, background/lock transitions and sustained behavior remain
**pending physical validation** in [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
The owner's bring-up amendment permits this separation; physical findings must
later correct policy, buffer budgets and support claims. See the host's device
protocol. Session/processing decisions are tracked in [#135](https://github.com/plx/hdxl-voice-processing/issues/135).

## Primary references

- [Measurement mode](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement)
- [Session preferences versus actual hardware](https://developer.apple.com/library/archive/qa/qa1631/_index.html)
- [Audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
- [Route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)

The installed Xcode 27.0 AVFAudio headers and Swift overlay supply the async
`activate()`/`deactivate()` and typed `didBecomeActive`, `didBecomeInactive`, and
`resumptionRecommendation` APIs used here. Legacy interruption-notification APIs
are unnecessary for the declared iOS 27 minimum.
