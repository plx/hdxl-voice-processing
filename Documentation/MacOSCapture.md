# macOS capture

`HDXLVoiceProcessingAudio` supplies `MacOSMicrophoneCapture` on macOS 27.
Construction performs no permission query or engine operation. The host requests
microphone permission after an explicit action, then calls `start(request:buffering:)`
on the main actor. `stop()` is idempotent; a subsequent start rechecks authorization,
observes the current input, and creates a fresh stream epoch and transport.

The owner emits typed start, stop, failure, and configuration-change events on the
main actor. A configuration notification schedules owner work outside the engine's
internal callback, closes the transport, and stops capture. The host explicitly
starts again to accept the new route/format. The [lifecycle coordinator](CaptureLifecycle.md)
composes capture with serial analysis, reconfiguration and host-approved recovery.
Broader native acceptance remains #59, with physical evidence pending #74.

## Format and ownership

The native backend checks the input node's hardware format for a finite positive
rate and nonzero channels before installing a tap. Its output format must be
Float32 or Float64 with 1–32 channels. The new throwing `installAudioTap` API
reports installation failure. Preferred formats are recorded as preferences;
the adapter does not force a tap format unrelated to the native output format.

The tap copies every native channel to the bounded `PCMTransfer` without changing
layout or precision. `MacOSCaptureSession.makeSchedule` enforces the request's
channel selection against the analysis profile. The existing worker then selects
one channel or performs its documented scaled Float64 arithmetic mean. No acoustic
analysis, file write, permission query, task dispatch, UI, or logging occurs in the
tap. Preparation allocates descriptor and PCM storage. SDK read-only buffers and
their pointers are borrowed only for the call; they are not queued or retained.

`MacOSCaptureBuffering` defaults to a 4096-frame hint, 32768 maximum delivered
frames, and 16 slots, subject to the transport's 64 MiB cap. The requested size is
not a delivery guarantee. Oversized/full queues drop whole newest chunks and
publish explicit gaps. Use measured device data to tune these defaults (#74/#133).

macOS uses no shared audio session. Delegated session ownership and background
execution requests are rejected explicitly. Measurement requests disable engine
voice processing; other device processing remains unknown. The system-selected
input's Core Audio UID is observed where available and remains unknown otherwise.
UIDs can identify hardware and must not be exported implicitly. No device selection
or shared-system input setting is changed by this implementation.

## Timing and failure

`sourceStartSample` is a nonnegative epoch-local sample index. `deviceSampleTime`
preserves the signed device timestamp when actually supplied, otherwise nil.
`hostStartNanoseconds` is converted from valid host ticks using the integer Mach
timebase, or nil when unavailable/unrepresentable. No wall clock is invented.
Forward device-clock jumps advance the sample index, exposing missing intervals;
backwards jumps and known/unknown timestamp transitions publish discontinuities.
Consecutive unknown timestamps advance by delivered frame counts: this is an
explicit logical index and cannot prove physical continuity or detect unseen loss.

Format mismatches, malformed buffers, overlapping callback admission, and clock
overflow close the transport and publish an atomic fault. A 50 ms main-run-loop
control timer (or explicit `poll`) reports that fault and tears down the engine.
Timer delivery can be delayed by a busy host main loop. The tap already stops
accepting data; no per-buffer task is created. The worker drains to `.finished`. Transport completion alone is not capture success: await the owner's `finish()` before accepting a recording. This reconciles pending and late callback faults after outstanding callback references return, including when an explicit stop/deadline beats the polling timer.
After native tap removal, the control actor retains retired bridge storage until outstanding callback references have returned; a cleared admission flag alone does not prove the callback ARC epilogue has finished. This retirement never blocks capture.

A stopped event acknowledges closed admission, not a successful whole-session outcome. Late failures retain the prior epoch and can be delivered after a new explicit start.

Queued valid audio remains valid before terminal failure; the failure does not
assert a successful complete recording.

`MacOSCaptureFailure` preserves the attempted request and available configuration.
Authorization and unavailable-input failures are distinct; tap-install and engine-
start errors retain system domain/code without localized/private error strings.
Events describe the prior configuration when change is detected; the next start
observes the replacement input rather than guessing it.

## Signed development host

`Examples/MacOSCaptureHost` is a separate package, not a runtime product. Build and
verify its app bundle with `python3 Tools/Capture/host.py`. This also runs two
error-privacy unit tests and launches only the synthetic error-reporting probe;
the probe performs no engine, permission, or recording operation. The default identity is
ad-hoc; set `CAPTURE_HOST_SIGN_IDENTITY` to an existing development identity when
stable TCC identity is needed. No signing credentials are stored. The host uses
Hardened Runtime's `com.apple.security.device.audio-input` entitlement and an
explicit microphone usage description. It is not sandboxed; a sandboxed host
requires its own `com.apple.security.device.microphone` entitlement and file access.

The build script never launches the host. The evidence wrapper's synthetic probe
checks that the entry point exits unsuccessfully with a sanitized category, without
throwing a recovery object containing device identifiers into crash diagnostics.
System error domains and arbitrary localized descriptions are omitted; recoverable
details remain available programmatically. To conduct an explicitly authorized local test:

```sh
open -W -n .build/macos-capture-host/MacOSCaptureHost.app --args --request-permission
open -W -n .build/macos-capture-host/MacOSCaptureHost.app --args \
  --record /absolute/private/path/built-in.caf --seconds 5
```

The record action creates a local CAF plus a `.caf.json` receipt, refuses existing
destinations, and does not request permission implicitly. It preserves native
channels in the file, writes only on a worker, and rejects a gap as a failed
recording. The receipt omits device UID and records whether identity was available.
A failed recording can leave a partial CAF; its receipt is marked failed. The
operator must label the actual input device and assess the recording. Repeat with
an available external device selected through system settings. Never commit these
private recordings or machine-specific metadata.

## Evidence

The dedicated CI lane builds/ad-hoc-signs the fixture, runs only its synthetic
error-boundary probe (no permission or capture), and
measures the exact `PreparedCaptureTap.accept` path using prepared native buffers.
Forty workloads cover both floating encodings/layouts, 64/4096 frames, accepted and
unknown-clock input, overflow, oversized buffers, and format changes. Timing runs
disable allocator instrumentation. Allocation runs require positive allocator/ARC
controls and zero heap activity in every measured bridge histogram. These are
synthetic software measurements, excluding SDK work before the callback and native
device delivery. Fake-engine tests exercise start/stop and error/event ownership.

Built-in/external input recordings, permission grants/denials, disconnection, rate
changes, termination, long-duration capture, and device callback latency/allocations
remain **pending physical validation** in #74. Neither signing nor simulator/build
results substitute for that evidence. Decisions and an SDK copying-initializer
discrepancy discovered during synthetic testing are tracked in #133.

## Primary sources

- [Input-node availability](https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode)
- [Tap buffer-size and format contract](https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:))
- [Engine configuration changes and teardown](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)
- [Sample-time validity](https://developer.apple.com/documentation/avfaudio/avaudiotime/issampletimevalid)
- [Host-time validity](https://developer.apple.com/documentation/avfaudio/avaudiotime/ishosttimevalid)

The installed Xcode 27.0 AVFAudio Swift interface declares the throwing
`installAudioTap(onBus:bufferSize:format:tapProvider:)` and scoped `withAudioUnit`
APIs. Core Audio's `kAudioDevicePropertyDeviceUID` header documents caller ownership
of the returned CF object; the native backend releases that object after reading it.

`python3 Tools/Capture/host.py` builds and ad-hoc signs the development host,
runs its privacy tests and synthetic public-lifecycle test, then executes
`--self-test-error-reporting` and `--self-test-lifecycle`. These modes request no
permission and create no native capture operation; they do not qualify TCC or hardware.
