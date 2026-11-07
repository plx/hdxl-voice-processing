#if os(iOS) && !targetEnvironment(macCatalyst)
    import HDXLVoiceProcessing

    /// Foreground iOS/iPadOS capture. Construction performs no permission query,
    /// shared-session operation, or engine construction. The host owns prompting,
    /// application configuration, session coordination and background transitions.
    @MainActor public final class IOSMicrophoneCapture {
        private let controller: IOSCaptureController
        public var session: IOSCaptureSession? { controller.session }

        public init(onEvent: @escaping @MainActor (IOSCaptureEvent) -> Void = { _ in }) {
            controller = IOSCaptureController(
                authorization: SystemMicrophoneAuthorization(),
                makeBackend: { SystemIOSCaptureBackend() }, onEvent: onEvent)
        }

        /// Call from a user action before awaiting the host's permission request.
        /// A later stop/background transition invalidates this single-use intent.
        public func prepareStart() -> IOSCaptureStartIntent { controller.prepareStart() }

        /// Host-managed mode requires an already active, recording-capable session.
        /// A delegated inactive session may be configured/activated only under its
        /// explicit grants. The host must keep its lease valid until finish returns,
        /// or invalidate it and await finish before changing/reusing the session.
        @discardableResult public func start(
            intent: IOSCaptureStartIntent, request: CaptureRequest, buffering: CaptureBuffering,
            lease: IOSCaptureHostLease, calibration: CaptureCalibrationContext? = nil
        ) async throws -> IOSCaptureSession {
            try await controller.start(
                intent: intent, request: request, buffering: buffering,
                lease: lease, calibration: calibration)
        }

        /// Closes admission and cancels pending startup. A stopped event is not a
        /// successful recording receipt: await finish and also finish the worker.
        public func stop() { controller.stop() }

        /// Waits for delayed activation, callback references, terminal failures,
        /// and any permitted session deactivation. Does not drain the worker.
        public func finish() async throws { try await controller.finish() }

        /// The host forwards its foreground-to-background transition. No background
        /// capture entitlement or automatic resumption is assumed by this adapter.
        public func enteredBackground() { controller.enteredBackground() }

        /// Optional immediate control-plane inspection; a control timer also polls.
        public func poll() { controller.poll() }
    }
#endif
