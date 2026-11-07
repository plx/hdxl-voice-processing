# Examples

`CoreConsumer` imports only the core product. Run it with
`swift run --package-path Examples/CoreConsumer CoreConsumer`.

[MacOSCaptureHost](../Documentation/MacOSCapture.md) is an independently signed
development capture bundle. [IOSCaptureHost](IOSCaptureHost/README.md) is a minimal
foreground iPhone/iPad app with a synthetic-only Simulator test mode. Hosts own
permission descriptions, consent UX, entitlements, audio sessions and app lifecycle.
The root package produces libraries, not runnable application bundles. Physical
capture validation remains pending #74; the workbench UI is later roadmap work.
