# Platform capabilities and host-owned capture

Contract introduced by [#20](https://github.com/plx/hdxl-voice-processing/issues/20).
The package supplies reusable code; the application supplies its identity, permission
UX, signing, configuration and lifecycle. Importing any product, constructing a
`CaptureRequest`, `SystemMicrophoneAuthorization` or `CapturePreflight` does not
query permission, create an engine, activate a session, start capture or persist audio.

## Support and evidence matrix

The baseline is [ADR 0001](Architecture/0001-package-boundaries.md) and
[`Configuration/build.json`](../Configuration/build.json): Xcode 27.0 (27A266a),
Swift 6.4 in Swift 6 mode, minimum macOS 27.0 / iOS 27.0. Installed SDK declarations
do not qualify an entire product or a microphone route. No older-OS compatibility
is promised. macOS here means native macOS; Mac Catalyst is not qualified.

| Capability | macOS 27 | iOS 27 / iPadOS 27 | watchOS 27 (provisional) |
| --- | --- | --- | --- |
| DSP-only processing | Core implemented; native software tests | Core cross-compiled for device and Simulator | Unqualified; subset decision in #60 |
| File decoding | Audio product implemented with native fixture tests | Audio product cross-compiled; device decoding evidence pending | SDK APIs are insufficient to claim support; #60 |
| Live capture | [Native adapter](MacOSCapture.md), fake-engine tests and synthetic callback profiling; physical validation pending | [Foreground adapter](IOSCapture.md), policy tests, native builds and synthetic host execution; physical validation pending | Unsupported by the current package; evaluate in #60 |
| Shared-session configuration | Unsupported; native macOS has no AVAudioSession path | Host-managed or explicitly delegated operation under a cooperative host lease; see [iOS contract](IOSCapture.md) | SDK has session APIs; package integration unqualified |
| Playback | Application-owned; no package playback implementation | Application-owned; no package playback implementation | Unqualified |
| Visualization | Optional target compiles; UI implementation remains roadmap work | Optional target cross-compiles; UI implementation remains roadmap work | Unqualified |
| Background execution | Host controls process lifetime; no capture deadline or continuous-runtime guarantee | Foreground baseline; background audio needs host declarations, policy and later evidence | Unqualified; no continuous-recording promise |

| Evidence level | What is established | What remains unproven |
| --- | --- | --- |
| SDK inspection | Xcode 27 lists macOS, iOS, iOS Simulator, watchOS and Watch Simulator 27 SDKs; current permission APIs compile on selected targets | Package support, entitlement correctness and hardware behavior |
| Native macOS software execution | Core/file/transport tests, fake capture providers, consumer graph/link checks; Debug, Release, ASan and TSan lanes; native-buffer callback profiling and signed host synthetic error probe | Physical microphone-host journeys, SDK/device callback delivery and route behavior |
| iOS device build | All three products plus an independent core consumer compile with the declared 27.0 minimum, without signing | Execution or physical recording |
| iOS Simulator software evidence | Product/consumer compilation for both architectures; iOS 27 development host synthetic test and app-launch probe | Native microphone signal path, real interruptions/routes and a physical iPhone/iPad signal path |
| Physical devices | **Pending physical validation** under owner-approved #74 | Permission journeys, routes, processing, background operation, latency, energy and sustained capture |
| Watch | SDK availability only; no package build/execution qualification here | #60 must publish an explicit supported subset or deferral |

Per-PR CI receipts identify actual compiler, SDK, runtime, revision and test results.
A Swift Testing runner's own build-target banner is not the deployment minimum of
the package. See [CI evidence](ContinuousIntegration.md) for collection. Update this
matrix as later roadmap work earns each claim; do not promote an SDK symbol,
simulator build or fake provider into device evidence.

## Application configuration and permission

Both supported hosts provide a meaningful `NSMicrophoneUsageDescription` in their
**app** Info.plist. A SwiftPM resource bundle cannot supply the executable's privacy
usage string. Missing required configuration can terminate the host when it requests
access. Keep host fixtures outside `Sources/`; #28/#29 introduce those apps,
with #68 extending their user interface. [Apple usage-string reference](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription),
[macOS capture authorization](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos).

On macOS, enable the entitlements that match the host's signing/security model:
App Sandbox Audio Input uses `com.apple.security.device.microphone`; Hardened
Runtime Audio Input uses `com.apple.security.device.audio-input`. An app using both
needs both corresponding settings. Entitlements do not replace user authorization.
Check the final signed app, not only the source plist. [Sandbox microphone entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone),
[Hardened Runtime audio input](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input).

`SystemMicrophoneAuthorization.microphoneAuthorization()` is a read-only query:
native macOS uses `AVCaptureDevice.authorizationStatus(for: .audio)`; iOS uses
`AVAudioApplication.shared.recordPermission`. Denial, restriction, undetermined
and unavailable states remain distinct. Unknown future system enum cases fail
closed as unavailable. Unqualified destinations return unavailable. The library
does not expose a prompt method. The host can request permission from an explicit
user action using `AVCaptureDevice.requestAccess(for: .audio)` on macOS or
`AVAudioApplication.requestRecordPermission()` on iOS. [Apple capture permission guidance](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media),
[AVAudioApplication](https://developer.apple.com/documentation/avfaudio/avaudioapplication).

This example belongs in the host, called by its record/enable-microphone action.
Do not call it on module loading, view initialization or automatic recovery:

```swift
import HDXLVoiceProcessingAudio
#if os(macOS)
import AVFoundation
#elseif os(iOS) && !targetEnvironment(macCatalyst)
import AVFAudio
#endif

@MainActor
func requestMicrophoneFromUserAction() async -> MicrophoneAuthorization {
    let provider = SystemMicrophoneAuthorization()
    let status = provider.microphoneAuthorization()
    guard status == .undetermined else { return status }
    #if os(macOS)
    _ = await AVCaptureDevice.requestAccess(for: .audio)
    #elseif os(iOS) && !targetEnvironment(macCatalyst)
    _ = await AVAudioApplication.requestRecordPermission()
    #endif
    return provider.microphoneAuthorization()
}
```

A late permission response must not start an operation the user already stopped.
The adapter/coordinator owns a generation check (#28/#29/#43). Permission remains
revocable; preflight success is not a cached authorization lease. There are no
automated system permission prompts in the test suite.

## Read-only preflight and ownership agreement

`CapturePreflight` accepts three main-actor providers. `CaptureCapabilityProviding`
reports runtime availability and whether an input is observable; this must be
based on the actual host/adapter, not a static platform-name guess.
`MicrophoneAuthorizationProviding` checks permission. `CaptureConfigurationNegotiating`
examines the complete request against the host's policy/current configuration and
either accepts it or reports a typed conflict. All provider methods are read-only
by contract. The host must not implement a query by starting capture or prompting.

`check(_:)` checks live capture, requested background execution and delegated
session capability, then permission, input availability and configuration agreement.
It stops at the first failure. It never requests permission, applies configuration,
retries, changes the requested policy or produces a measurement. The future adapter
must separately implement start/stop and revalidate state immediately before use.
No concrete live capability provider is shipped before the adapters in #28/#29.

| Outcome | Meaning / host response |
| --- | --- |
| `unsupportedCapability` | The requested capability is not implemented/supported on this destination |
| `unavailableCapability` | A supported operation is temporarily unavailable |
| `unqualifiedCapability` | Evidence/support policy does not qualify this operation, e.g. provisional Watch or unverified background operation |
| `permissionUndetermined` | Host may offer an explicit permission action; no implicit prompt |
| `permissionDenied` / `permissionRestricted` | Explain the unavailable feature; do not silently retry or invent PCM |
| `authorizationUnavailable` | System cannot supply a known authorization state |
| `inputUnavailable` / `inputUnknown` | Missing input versus inability to establish input availability |
| `configurationConflict` | Session in use/inactive, incompatible format/processing, delegation required or unsupported configuration |
| `invalidConfiguration` | Malformed constructed request/metadata |

These are `CaptureIntegrationError` values in the Audio product. Core's
`ContractError`, `MeasurementOutcome`, `PCMFormat`, channel-selection and epoch
contracts from #15 remain capture-independent. Permission failure is not a zero
measurement or a reason to weaken the numerical profile.

The default `CaptureSessionOwnership.hostManaged` forbids the adapter from changing,
activating **or deactivating** the shared iOS session, including during stop/failure.
The host must supply an active, compatible session or receive a conflict. Native
macOS uses this ownership value without requiring shared-session capability;
delegating a nonexistent native macOS session is unsupported. Its implementation
does not import or reference AVAudioSession.

Explicit `.delegated(CaptureSessionDelegation(...))` permits negotiation of session
configuration; activation and deactivation are separately permitted by two required
booleans. No implicit exclusive ownership follows. #29 adds concrete iOS session
settings and applies only an accepted request; #43 coordinates changes/teardown.
An adapter must not undo a host change by blindly restoring a stale snapshot.
The host forwards lifecycle decisions (stop, interruption/resumption, route change,
media-service reset, foreground/background), and chooses whether capture may resume.
Apple's shared session is app-wide; its default behavior is not recording-capable.
[AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession).

## Acquisition provenance

`CaptureRequest` retains optional preferred format, explicit selected channel or
arithmetic mean, processing request, session ownership and execution intent.
`CaptureConfigurationObservation` adds the actual format, `StreamEpoch`, input/route
identity and processing observations after configuration. A valid hardware format
may differ from the preference; both remain visible. A selected channel must exist
in the effective format. Construction is descriptive, not proof that a measurement
policy is satisfied; adapters reject unsupported/conflicting effective conditions.

Engine voice processing, gain control, noise suppression, echo cancellation and
session mode each carry `.unknown` or an actual observation. Observing disabled
engine voice processing does not infer that other stages are disabled. Apple's
measurement mode reduces some system processing; it does not certify a raw signal.
Record only properties actually available to the adapter. [Measurement mode](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement).

Unknown device/route identity is explicit. Observed strings are nonempty, exclude
NUL and are bounded to 1024 UTF-8 bytes. No metadata here is automatically persisted
or encoded; stable device identifiers can be private. Later export code must use
explicit consent/redaction policy. Format, route, channel selection, processing or
analysis changes require a new configuration epoch; the coordinator in #43 will
publish the boundary before measurements under the new conditions.

## Verification and deferred work

`CaptureIntegrationTests` use injected providers to cover initialization without
queries; all permission states; unavailable/unknown input; unsupported/unqualified
capabilities; foreground/background; all activation/deactivation grants; host-managed
session use; conflicts; changed permission between checks; requested/effective format
differences; unknown processing; channel and metadata validation. They open no device,
request no permission and configure no session. Product builds compile the native
permission bridges; core graph/link and network-denied consumer checks verify its
independence from capture/UI products.

Run the six local lanes in [CONTRIBUTING](../CONTRIBUTING.md). Physical host evidence
is explicitly pending [#74](https://github.com/plx/hdxl-voice-processing/issues/74).
Follow-up [#130](https://github.com/plx/hdxl-voice-processing/issues/130) records the
preflight, delegation, error-layering and metadata decisions for owner review.

The [macOS capture adapter](MacOSCapture.md) implements this boundary using native input taps, explicit ownership, and bounded PCM handoff.
