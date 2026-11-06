# ADR 0001: Package, toolchain, and ownership boundaries

Status: accepted for initial bring-up, 2026-11-04. Roadmap: #14.

The owner requested current-generation deployment only. Use Swift tools 6.4,
Swift 6 language mode, Xcode 27.0 build 27A266a, macOS 27.0 and iOS 27.0 SDKs,
and minimum macOS/iOS 27.0. `Configuration/build.json` is the machine-readable
record. These choices match the installed stable toolchain, avoid an unnecessary
back-deployment commitment, and enable strict concurrency by default. CI will
select Xcode explicitly and verify both the host OS and SDKs in #19. A runner
with only macOS 26 may cross-compile but cannot qualify execution of a package
whose minimum deployment is macOS 27. Runner selection remains pending that check.

The products and permitted dependencies are:

| Product | Depends on | Responsibility |
| --- | --- | --- |
| HDXLVoiceProcessing | Swift/system numerical frameworks only | PCM values, profiles, deterministic DSP |
| HDXLVoiceProcessingAudio | Core and Apple audio frameworks | Capture adapters, scheduling, lifecycle |
| HDXLVoiceProcessingVisualization | Core and SwiftUI | Optional views of immutable results |

There are no external runtime dependencies. Core does not import SwiftUI,
AVFAudio, or AVFoundation. Visualization does not own or depend on capture.
Framework imports are confined to the corresponding optional targets.
The initial concrete core value is a validated `PCMFormat`; result/profile and
processor contracts follow in #15. Module imports have no side effects.

`Sources/` contains products; `Tests/` contains correctness tests. `Examples/`
contains independent consumers and eventually real host apps. `Tools/` owns
development-only verification/reference utilities. `Benchmarks/` will be a
separate package in #17; its compiler/dependency requirements do not flow into
runtime clients. `Documentation/` holds architecture, provenance, and evidence.

Public values crossing tasks are immutable and `Sendable`. Future mutable DSP
state has one serialized owner, with buffers and reset semantics specified in
#15. Capture callbacks perform bounded transfer only; analysis, allocation-heavy
conversion, diagnostics, and UI work execute outside them. SwiftUI state belongs
to the main actor. No unchecked concurrency conformance is needed at bootstrap.

The library is not an app bundle. Hosts own microphone usage descriptions,
authorization UX, sandbox entitlements when needed, audio-session activation,
interruptions, route policy, and lifecycle. Importing a product does none of this.

watchOS is pending #60; an omitted manifest platform entry does not prevent
SwiftPM from attempting other destinations, and does not promise support.
If added, watchOS will use the owner's 27-generation minimum policy. Linux,
Windows, tvOS, and visionOS are unqualified. Physical-device evidence is deferred
by the owner to #74; build/simulator evidence cannot establish capture or energy
behavior. Public release authorization remains a separate final decision.

The [#20 platform and host contract](../HostCaptureIntegration.md) now separates
SDK availability, implemented capabilities, cross-compilation, software execution
and pending physical evidence. It preserves these minimums and product boundaries.
Capture preflight, typed capture errors, authorization queries and session ownership
live in Audio. Core measurement failures do not acquire microphone-policy meanings.

Sources checked: [Apple Xcode SDK/compiler matrix](https://developer.apple.com/xcode/system-requirements),
[SwiftPM manifest reference](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html),
and [GitHub runner images](https://github.com/actions/runner-images).
