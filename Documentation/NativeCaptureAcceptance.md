# Native capture acceptance

Use the small capture hosts to qualify a specific input route on macOS 27 or iOS 27. Record software correctness, physical functional acceptance and sustained performance as separate results. The initial release has **pending physical validation** for every route and profile. The device-lab owner collects those trials under [#74](https://github.com/plx/hdxl-voice-processing/issues/74). [Resource qualification](https://github.com/plx/hdxl-voice-processing/issues/64) owns sustained headroom, energy and support-tier decisions.

## Software gates

The capture maintainer runs these commands from the repository root with the pinned Xcode and Python in `Configuration/build.json`. A failed command, missing named test, invalid receipt, unreported loss or stale epoch fails the corresponding gate. CI retains the JSON and logs with the tested revision. [CI environment and destinations](ContinuousIntegration.md)

| Gate | Command or scheme | Required observation |
| --- | --- | --- |
| File, synthetic input and runtime | `python3 Tools/ci.py debug`, then `python3 Tools/Capture/acceptance.py .build/ci-artifacts/debug` | `native-acceptance.json` names the executed tests and hashes the XML. Covers decoder chunk sizes, both PCM precisions/layouts, loss, source clocks, late permission, cancellation, stale workers, restart, queue bounds and slow subscribers. |
| macOS host and repeated recovery | `python3 Tools/Capture/host.py`, `python3 Tools/Capture/lifecycle.py`, `python3 Tools/Capture/delivery.py` | Signed development host runs its synthetic tests. Check lifecycle retirement, clean completion, reset and worker/publication timing distributions. Strict overflow and display coalescing have separate counts. |
| iOS host | `python3 Tools/Capture/ios_host.py --install-runtime`; `python3 Tools/Performance/verify_portable.py --output .build/ios-capture-host-evidence/workload-parity.json` | `IOSCaptureHost` builds for device and runs synthetic tests on iOS 27 Simulator. Portable workloads match macOS. |
| Callback invariants | `python3 Tools/Transport/audit_callback.py`; run each of `Tools/Transport/benchmark.py` and `Tools/Capture/benchmark.py` with `timing` and then `allocation` | Inspect the optimized tap/handoff on all four target slices. The permitted calls exclude library locks, synchronous dispatch, per-buffer tasks and logging. Measured heap maxima must be zero and allocator/ARC controls must fire. Retain the assembly and separate allocation/timing histograms. |
| Integrated load and memory | Build with `python3 Tools/Streaming/build.py .build/streaming`; run the seven benchmark groups and Instruments probe in the [replay protocol](Evidence/streaming-replay.md) | Report offered, accepted, dropped and drained work, reconstructed scientific results, post-gap warmup, acoustic result ages, peak queue occupancy and sustained RSS. Label instrumented timing. A valid measurement can expose a performance failure. |

The shared Debug job checks the test index on every PR. Dedicated capture, iOS host, transport and streaming jobs publish the other receipts. The deterministic replay includes silence, voiced and clipped input, variable callback sizes, deliberate overruns, strict/slow/paused consumers and multiple analyzers. The stress group runs two full analyzers concurrently at 48 kHz with 256-frame callbacks, providing controlled competing CPU work. Run its single-analyzer counterpart with `full 48000 256 paced disabled 2 7 single` and a fresh output filename. The portable raw-YIN inventory supplies low-F0 and noise/silence cases. The [whole-file algorithm benchmarks](Evidence/voice-algorithm-benchmarks.md) cover the offline suite. Compare identical accepted source regions when assessing numerical agreement. [Streaming measurements](https://github.com/plx/hdxl-voice-processing/issues/56#issuecomment-7138604622) · [Portable workloads](../Configuration/portable-workloads-v1.json)

## Physical routes and ownership

| Device or route | Bring-up status | Device-lab coverage |
| --- | --- | --- |
| Native Mac, built-in microphone | Pending physical validation | Required baseline on a Mac with built-in input. Record model and actual format. |
| Foreground iPhone, built-in microphone | Pending physical validation | Required baseline on a signed device with an active host-owned session. |
| iPad, wired headset, USB or Bluetooth input | Untested | Optional separate records for each available route. A missing accessory is deferred. Report actual processing and format on each route. |
| Watch | Unqualified | Scope belongs to [#60](https://github.com/plx/hdxl-voice-processing/issues/60). |
| Mac Catalyst and continuous iOS background recording | Outside the capture baseline | Backgrounding the foreground host should stop it. Native macOS has no shared audio-session interruption scenario. |

The device-lab operator runs the cases below, records private observations and attaches reviewed summaries to #74. The capture maintainer reproduces functional failures. The release maintainer updates route/profile claims only after the relevant trials and the applicable [scoped performance budget](BenchmarkProtocol.md) have been reviewed. Device absence, an unobservable required step or a missing budget leaves the corresponding gate open.

## Run a physical case

Build the release revision being tested. Write private evidence outside the repository. Use stable development signing and the same bundle identity for the permission sequence. Keep microphone content, stable hardware identifiers and personal file paths out of shared results.

On macOS build the signed fixture with `bash Tools/build-macos-capture-host.sh`. From a user action, run the permission request, then the capture check. The latter drains native PCM in memory, records counters and fresh epoch IDs, samples process CPU time, resident memory, thermal state and actual queue depth off the tap, and performs all repetitions on the same capture owner. It writes a new destination and preserves a failed or interrupted trial. Check the JSON status after the app exits.

```sh
app=.build/macos-capture-host/MacOSCaptureHost.app
open -W -n "$app" --args --request-permission
open -W -n "$app" --args --capture-check /absolute/private/restart.json --seconds 2 --runs 10
```

On iPhone use the shared `IOSCaptureHost` scheme with your development team and a physical iPhone. Choose Start and Stop explicitly. Record the final effective format, epoch, accepted/drained chunks, consumed/dropped frames and peak/capacity display after Stop. Choose **Share resource samples** after Stop to save the bounded JSON readings to the private trial bundle before the next Start. A gap or cleanup error ends the run. To exercise a controlled file independently, use the deterministic file gate above. For a consented private Mac recording the fixture also provides `--record`. [iOS host actions](../Examples/IOSCaptureHost/README.md) · [Mac authorization and recording](MacOSCapture.md)

| Case ID | Operator action and passing evidence |
| --- | --- |
| `permission-denied` | Begin with an undetermined permission state for the test identity. Deny the explicit prompt, attempt Start, and stop. Observe a reported denial, zero capture epochs and no retry or new prompt on Stop. Repeat after revocation in Settings. Record restrictions separately where available. |
| `first-grant` | From a fresh permission state grant the explicit request, start built-in input and stop. No capture starts at launch. Record the effective format, one or more delivered blocks and completed teardown. |
| `pending-permission-stop` | On iPhone background or stop the host during a pending request, then answer the prompt. Record the late answer, zero capture epochs and absence of session activation or automatic restart. |
| `stop-restart` | Start, stop and explicitly start again on the same host. Record at least two completed epochs per trial. Repeat to cover ten short cycles. Compare distinct epoch IDs, closed old admission and absence of old results. Record each epoch. |
| `route-change` | Begin capture, switch or disconnect the selected input, and record loss or an unknown discontinuity. Observe closed admission for the old configuration. Explicitly start the new route, record both actual formats and fresh epochs. Defer the case when the transition cannot be exercised. |
| `interruption` | On iPhone interrupt a running session with a real system event. Include foreground/background and lock transitions as separate repetitions. Confirm old admission closes and nothing resumes until an explicit host action. Record both epochs and any unmeasurable loss extent. |
| `sustained-foreground` | Capture at least 120 seconds per functional trial. Repeat quiet input, speech with unvoiced spans, low-F0 voicing, and a safely supplied clipped test signal. Repeat with a named CPU contention workload and a slow observer where the host provides analysis. Keep an idle/capture-only control. Record start, middle and end resource samples, raw latency observations and all losses. #64 owns longer cooldown/repeated live-analysis runs for CPPS, core and full profiles. |

The fixtures implement capture-only trials. The streaming probe supplies synthetic integrated analysis. Use the device analysis host from #64 when recording physical result age or profile headroom. A desktop or Simulator result gives no iPhone or Watch approval. For cold starts, permission failures, interruptions, external routes and missing sensors, retain what was observed and identify what remains unmeasured. [Apple media authorization](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos) · [Apple performance measurement](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance)

## Trial record and outcome

```sh
python3 Tools/Capture/device_trial.py prepare Mac built-in stop-restart /absolute/private/trial.json
python3 Tools/Capture/device_trial.py evaluate /absolute/private/trial.json
```

`prepare` writes an unmeasured form. `evaluate` prints a receipt and returns 0 for a functional pass, 1 for failure and 2 for deferred evidence. On an actual device set `execution` to `physical`, clear `deferredReason` to JSON `null`, and fill in the following fields. Keep the original form and linked observations beside the receipt.

- **Run identity.** Record UTC time, Git SHA, device model/architecture, OS version/build, Xcode build, Debug/Release, operation, profile ID/version, diagnostics, acquisition schedule ID and actual elapsed seconds. For capture-only use `capture-only` as the profile ID and the fixture version for its version. Record the route class, profiler/debugger, power source, low-power state if known, battery/charging state, workload, contention, temperature/cooldown conditions and requested format in the run context. Use the same profile/schedule identity for #25 and #64.
- **Observations.** Fill each named scenario check with `true`, `false` or `null` for unobserved. Add observed faults to `failures`. Keep each route or permission repetition in a separate form. Use sanitized operator notes to record requested versus actual routes, event order, session ownership and reset behavior.
- **Native evidence.** Each `evidence` item specifies `kind`, bundle-relative `file` and its `sha256`. Use `mac-capture-check` to import epochs from the signed fixture’s JSON and leave the form’s `epochs` empty. For sustained capture use one continuous run with `--seconds 120 --runs 1`. The evaluator imports its resource samples. Enter actual total elapsed seconds including setup and drain, rounded up to cover the last sample. Use `operator-notes` or `instrument-export` for other observations. On iPhone enter each completed epoch's `epoch`, `sampleRate`, `channels`, `encoding`, `layout`, `queueSlots`, `maximumFramesPerChunk`, `queueHighWater`, `acceptedChunks`, `drainedChunks`, `consumedFrames`, `droppedFrames`, `knownGapFrames`, `unknownGaps`, `invalidChunks` and `producerContractViolated`. A successfully completed iPhone host drain rejected any gap; for a failed drain retain the observed failure and partial evidence. Denial and cancellation of a pending permission request have no epochs.
- **Distributions.** Each `resourceSamples` row identifies its epoch, `elapsedSeconds` from trial start, cumulative `processCPUSeconds`, `residentBytes`, `queueDepthSlots` and `thermalState` (nominal/fair/serious/critical/unavailable). On iPhone paste the host’s shared JSON array into `resourceSamples`. The hosts sample at approximately one-second intervals, progressively thin longer histories and retain a final reading. Unavailable values are omitted. Preserve them as missing. Record timestamps in increasing order. The tool derives CPU seconds per wall second between samples and summarizes RSS and queue depth. Use an instrumented run with entry and return timestamps to populate `callbackDurationNS`. A sampled profiler stack cannot establish elapsed callback time. Processing and acoustic window end to subscriber observation each have their own nanosecond series in `latencies`. Exclude unavailable measurements by leaving the corresponding series empty. For energy supply the actual tool's unit and samples or an explicit unavailable reason. Separate idle, capture-only, replay, live, instrumented and clean timing in distinct records. Preserve the original sample history for drift analysis.

Compare offered, accepted, consumed and lost work. Any unexplained loss, stale results, failed cleanup, exceeded capacity or false scenario check fails the trial. Nominal capture must be lossless. Controlled route/interruption boundaries permit explicit loss and unknown extents. A complete functional receipt only qualifies that recorded scenario. Physical profile sustainability requires repeated matched controls, measured headroom, stable memory, attributed CPU/energy and a reviewed per-device budget from #64.
