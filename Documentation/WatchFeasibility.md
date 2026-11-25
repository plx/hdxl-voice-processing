# watchOS 27 feasibility

**Needs hardware for a release claim.** The initial candidate is a user-initiated foreground segment with one level reading after recording. The standalone [probe](../Examples/WatchFeasibilityProbe) uses the production Core analyzer. For #68, keep the developer probe as the compact prototype and omit a consumer Watch workbench. A future decision can expand the scope after #64 and #74. The Mac and iPhone release paths proceed independently.

| Capability | Initial decision | Evidence and boundary |
| --- | --- | --- |
| Deterministic buffer DSP | Supported in the developer probe | Core builds for the watch destination. The reproducible Simulator run processes mono Float32 with a known RMS result. Other algorithms have no Watch workload qualification. |
| File analysis | Conditional | The probe reads one private, mono PCM segment, at most four seconds and 4–192 kHz. The known one-second CAF fixture exercises the same file/worker path. General file import and the Audio product's decoder are outside this selection. |
| Session activation and microphone | Untested on physical Watch | Explicit permission, record category, measurement mode and foreground activation. The recorder requests three seconds of mono PCM. A denied or unusable route ends the trial. Physical evidence remains pending #74. |
| Live metrics | Unsupported in MVP | The recorder writes a bounded segment. Work starts after stopping. CPPS, pitch, full-suite live analysis and continuous coaching require separate functional and resource evidence. |
| Result delivery | Conditional | Off-main analysis publishes one final result on the main actor. The receipt includes file frames, windows, profile digest, last-window value/status and time from the manual stop request or completion callback entry to the result becoming ready. |
| Compact display | Supported for the developer fixture | Replay, Record, Stop, a final digital level or a no-data state. No personal target, score or live timeline. |
| Wrist down, background, always-on | Unsupported for capture in this probe | On loss of active scene the probe stops and discards the interrupted recording. There is no automatic restart, background mode, extended runtime, workout, or location session. |
| iPhone connectivity | Untested | A standalone watch-only bundle. No WatchConnectivity product, companion dependency or transfer contract. |

## Reproduce the software evidence

Use Xcode 27 with both watch SDKs and Swift 6.4. The project and package select a 27.0 watch deployment floor independently of iOS. The checked-in scheme links only `HDXLVoiceProcessing`. AVFAudio and SwiftUI belong to the probe. The reusable products never import the probe. The root manifest's watch minimum constrains compilation and grants no additional runtime qualification.

```sh
python3 Tools/Watch/probe.py --output .build/watch-evidence/build.json
python3 Tools/Watch/probe.py --replay --install-runtime --output .build/watch-evidence/result.json
```

The first command builds generic Watch Device and Simulator destinations and checks their built plists, SDK, minimum OS, Watch device family and microphone description. The second also boots a new watchOS 27.0 Simulator, places a synthetic leftover in its private temporary folder, checks launch cleanup, runs synthetic replay, checks 16,000 frames, ten disjoint windows and −6.0206 dBFS RMS, and deletes its simulator. Use `--replay` alone with an installed runtime. Failed replay artifacts retain allowlisted state and counts. The runtime download is optional for compile-only probes. CI selects Xcode 27.0 build 27A266a. The receipt identifies the actual Xcode build, source revision, architectures, SDKs and Simulator runtime build.

The independent watch SDK headers declare `AVAudioApplication.requestRecordPermission` from watchOS 10, record category, measurement mode, activation and actual session rate from watchOS 2, and the session-inactive notification from watchOS 27. The iOS preferred sample rate and preferred I/O duration setters are unavailable on watchOS. The probe reads back the effective session format and mode. The file records its own format after conversion to mono. Hardware processing, gain and hidden signal conditioning remain unknown. [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession) · [AVAudioRecorder](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)

A lowered wrist can leave an app frontmost and inactive. Crown dismissal can move it directly toward background and suspension. Background audio has its own declared purpose and configuration. This practice fixture requests foreground capture only. A force-quit can prevent final callbacks. [Frontmost app state](https://developer.apple.com/documentation/watchkit/taking-advantage-of-frontmost-app-state) · [Background sessions](https://developer.apple.com/documentation/watchkit/enabling-background-sessions)

## Physical handoff for #74 and #64

No physical Watch trial was available for this decision. Sign the shared `WatchFeasibilityProbe` scheme in Xcode with your development team and select a watchOS 27+ Watch. Record the tested Git SHA, Watch model and size, exact OS/build, route, battery/charging, low-power and debugger state. Use separate private directories for each attempt. Save `Documents/watch-trial.json` from the app data container before the next attempt overwrites it. A failed session release leaves a warning and a retry button. Save the failed trial, retry release and record the outcome before starting another trial. The terminal receipt is frozen. Record observations that the OS does not expose, including wrist/crown actions and whether the UI showed the result. A route-configuration change invalidates the recording even if its input port type and rate are unchanged. Share redacted metadata only. The separate launch receipt in `Documents/watch-launch.json` records recovery of the preceding private file. Each trial records its preflight cleanup separately and marks the current file pending before recorder creation. A cleanup failure is a terminal error that remains visible until deletion succeeds. The temporary recording is removed after analysis or cancellation and a leftover from a force-quit is removed on next launch.

| Trial | Evidence to collect |
| --- | --- |
| Fresh permission and denial | Launch and replay before prompting. Tap Record, deny, tap again. Save the denied status and check that capture did not start. Repeat with permission granted. Granting permission requires a fresh Record tap. |
| Three-second run and early Stop | With a known active route, tap Record, speak briefly, and wait for completion. Repeat with Stop before the first complete window and after one full window. Save frames, file rate, session rate/mode, number of complete windows, result or missing reason, and latency from the labeled origin to result readiness. |
| Wrist down, Digital Crown, foreground return | Use a separate recording for each action. Lower the wrist or navigate away during the three seconds. Record observed scene transitions, whether recording ended, and whether explicitly tapping Record works after return. Never infer an event from its absence in the receipt. |
| Interruption and available route change | Interrupt or disconnect/change the active input during capture. Save the receipt, actual route before/after and action timing. Verify the interrupted segment was discarded and a new explicit trial uses the effective route. Mark inaccessible routes or interruptions untested. |
| Termination | Force-quit during capture. Preserve the previous receipt before another trial, relaunch, check for temporary-file cleanup and an idle UI. Record absence of a terminal event as an incomplete run. |
| Resource follow-up | Repeat each supported short segment after cooldown. File frames and analysis window counts can expose incomplete coverage, but AVAudioRecorder provides no hardware drop counter or source timestamps. Record drops as unobservable and measure them independently before any live qualification. #64 owns sustained latency, CPU, memory, energy/thermal and practical session duration. |

If a Watch cannot activate the session or record usable PCM, retain synthetic buffer/file replay as the candidate and document the failing route and status. If post-recording delivery succeeds, measure it under #64 before promoting a profile. Update this matrix and #68's UI scope with the resulting evidence. [Device follow-up #74](https://github.com/plx/hdxl-voice-processing/issues/74) · [Resource qualification #64](https://github.com/plx/hdxl-voice-processing/issues/64)
