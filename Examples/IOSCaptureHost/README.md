# iOS Capture Check development host

Open `IOSCaptureHost.xcodeproj`, choose the shared `IOSCaptureHost` scheme and an
iOS 27 iPhone/iPad destination. For a physical device, select your own development
team/signing configuration in Xcode. Do not commit signing assets. The project
uses the root package through a local path; it is outside the library products.

Nothing requests permission or starts audio on app launch. Tap **Start capture**
to request permission if needed, explicitly configure and activate the host's
shared recording/measurement session, then start the host-managed adapter. Inspect
the effective tap/session rates, native channels, encoding/layout, processing
observations and accepted chunk count. The worker consumes and discards PCM; this
fixture does not record, play, export or upload audio. Tap **Stop** to close capture,
await callback/worker completion, and let the host deactivate its own session.
Backgrounding stops capture and never automatically resumes it.

This app is the sole owner of its audio session. Its explicit cleanup is unsuitable
for copying unchanged into a host that shares the session with playback or another
recorder; such a host must arbitrate its features. Cleanup failure disables Start
until this development app is restarted. Route IDs and arbitrary system error
descriptions are not rendered. [Adapter contract](../../Documentation/IOSCapture.md).

## Automated software checks

```sh
python3 Tools/Capture/ios_host.py --install-runtime
```

The optional flag asks Xcode to download iOS 27.0 only if CoreSimulator does not
already report it available; an existing runtime is reused without downloading.
The script builds unsigned device code, creates its own disposable Simulator, runs
the capture-host, session-interchange and storage tests, then launches with `--self-test`,
validates ten named synthetic capture checks (including lifecycle cancellation and
independent bounded subscriptions), and deletes
only its own device. Xcode 27.0 and Python 3.14.8 are required. The synthetic mode
disables capture controls and persists only its allowlisted synthetic result in
the app's local Documents directory. No microphone permission prompt, shared-session
activation or engine capture runs. CI retains JSON/log summaries, not raw xcresults
or simulator containers. App and Simulator builds do not qualify device signing.

The session test runs the same public-API fixture probe as
[SessionWorkflow](../SessionWorkflow/README.md) on macOS: canonical byte round trips,
exact source/host clocks, statuses/intermediates/gaps, partial/interrupted recovery,
original-PCM replay with a pinned recipe, explicit audio absence and private-copy
cleanup, and calibration/target inspection without activation. Its resources live
only in the test bundle. Two additional shared storage lifecycle tests exercise
real synthetic analysis, audio opt-in, verified import/replacement, sharing copies,
delete and replay. The evidence driver checks all four exact
test names, successful execution, exact counts, no skips and the iOS 27.0 runtime;
compilation alone cannot satisfy this gate.

## Storage and user-controlled sharing

Open **Session storage and sharing** to create an audio-free synthetic session,
optionally include its original generated PCM, inspect a Files import, explicitly
prepare/share a verified copy, replay the first plan, or delete local files. The
screen shows whether audio is present and never activates imported targets. Its
private Application Support directory is excluded from backups; sharing copies
remain there until explicit deletion. This does not record the microphone host's
buffers. See [SessionWorkflow](../SessionWorkflow/README.md) for API ownership,
limits, the equivalent macOS CLI and the shared tests.

## Physical protocol — pending #74

Collect this evidence later on a signed physical iPhone and iPad; it is explicitly
deferred from initial bring-up. Record device/OS/Xcode build, actual input route,
preferred and effective format, session category/mode/options, processing knowns
and unknowns, buffer budget, foreground state and test duration. Obtain consent
before recording any private voice; this baseline fixture discards its audio.

1. Exercise first permission grant, denial, Settings revocation and delayed response
   after Stop/background. Confirm no late startup and repeatable start/stop.
2. Test built-in input and available wired/USB/Bluetooth routes without assuming
   measurement compatibility. Record typed failures and exact actual format.
3. During capture, disconnect/switch inputs, change system configuration, trigger
   an incoming interruption, lock/background/foreground, and perform the supported
   media-services reset journey. Confirm admission closes, a fresh start uses a new
   epoch, loss extent remains unknown when unmeasured, and nothing auto-resumes.
4. Use Instruments Allocations and Time Profiler/signposts on the actual device
   callback. Separate SDK work before delivery from `PreparedCaptureTap.accept`;
   include allocator capability controls, idle/overload worker conditions, callback
   frame-size distributions, duration percentiles/maxima, queue depth/high-water,
   overflow/oversized counts and any gaps. Do not infer allocations from timing or
   count absence as zero without a positive instrumentation control.
5. Repeat sustained foreground runs and report thermal/power/latency context under
   #64. Record duration and all failures; do not claim background support from a
   successful foreground run. Review buffer/session-policy adjustments under #135.

Summaries must distinguish physical execution from fake-controller, Simulator and
compile evidence. Keep private raw traces/audio and route identifiers local; share
only reviewed, consented summaries in #74 and revise support claims as needed.
