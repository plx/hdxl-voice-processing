import AVFAudio
import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio
import Observation

/// This development app is the sole owner of its shared audio session. A host
/// with playback/other recording must coordinate those features before granting
/// a lease. Nothing here starts from view construction or app foregrounding.
@MainActor @Observable final class CaptureHostModel {
    private(set) var status = "Ready. Audio stays in memory and is discarded."
    private(set) var isBusy = false
    private(set) var observation: IOSCaptureObservation?
    private(set) var frames: UInt64 = 0
    private(set) var acceptedChunks: UInt64 = 0
    private(set) var sessionNeedsAttention = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var counters: Task<Void, Never>?
    @ObservationIgnored private lazy var capture = IOSMicrophoneCapture { [weak self] event in
        self?.receive(event)
    }

    func start() {
        guard !isBusy, !sessionNeedsAttention else { return }
        isBusy = true
        frames = 0
        acceptedChunks = 0
        observation = nil
        status = "Preparing microphone…"
        let intent = capture.prepareStart()
        operation = Task { await run(intent: intent) }
    }

    func stop(background: Bool = false) {
        guard isBusy else { return }
        if background { capture.enteredBackground() } else { capture.stop() }
        operation?.cancel()
        status = "Stopping…"
    }

    private func run(intent: IOSCaptureStartIntent) async {
        var attemptedActivation = false
        var worker: Task<UInt64, any Error>?
        var problem: (any Error)?
        do {
            if SystemMicrophoneAuthorization().microphoneAuthorization() == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
            }
            try Task.checkCancellation()
            guard SystemMicrophoneAuthorization().microphoneAuthorization() == .authorized else {
                throw CaptureIntegrationError.permissionDenied
            }
            // Host-owned configuration and activation are explicit. The adapter's
            // hostManaged path validates these settings without mutating them.
            let shared = AVAudioSession.sharedInstance()
            try shared.setCategory(.record, mode: .measurement, options: [])
            attemptedActivation = true
            guard try await shared.activate() else { throw HostProbeError.failed }
            try Task.checkCancellation()
            let session = try await capture.start(
                intent: intent,
                request: CaptureRequest(
                    channelSelection: .arithmeticMean, processing: .measurement),
                buffering: CaptureBuffering(), lease: IOSCaptureHostLease(activity: .active))
            let task = Task.detached { try await HostPCMConsumer.drain(session.transfer) }
            worker = task
            frames = try await task.value
        } catch {
            problem = error
        }
        capture.stop()
        // Finish is required even after a worker failure or Stop. It catches
        // faults published by an in-flight callback after admission was closed.
        do { try await capture.finish() } catch {
            if problem == nil || problem is CancellationError { problem = error }
        }
        if let worker {
            worker.cancel()
            _ = await worker.result
        }
        counters?.cancel()
        counters = nil
        if attemptedActivation {
            // This host owns the whole shared session, including failed startup.
            // A multi-feature host must instead arbitrate its own deactivation.
            do {
                let cleanup = Task { @MainActor in
                    try await AVAudioSession.sharedInstance().deactivate()
                }
                guard try await cleanup.value else {
                    throw HostProbeError.failed
                }
            } catch {
                sessionNeedsAttention = true
                problem = error
            }
        }
        status =
            sessionNeedsAttention
            ? "Audio session cleanup failed. Restart this development app before capturing again."
            : problem.map(HostErrorReport.message) ?? "Stopped. Consumed \(frames) sample frames."
        isBusy = false
        operation = nil
    }

    private func receive(_ event: IOSCaptureEvent) {
        switch event {
        case .started(let session):
            observation = session.observation
            status = "Capturing in the foreground."
            counters = Task {
                while !Task.isCancelled {
                    acceptedChunks = session.transfer.snapshot().acceptedChunks
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        case .configurationChanged, .calibrationInvalidated:
            status = "Capture conditions changed. Stopping…"
        case .failed(let failure): status = HostErrorReport.message(for: failure)
        case .resumptionRecommended:
            // A recommendation is never a command to restart capture.
            break
        default: break
        }
    }

    func runSelfTest() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await HostSelfTest.run()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            // Only synthetic, allowlisted results are persisted by this mode.
            let url = URL.documentsDirectory.appending(path: "synthetic-self-test.json")
            try data.write(to: url, options: .atomic)
            status =
                "Synthetic self-test passed: \(result.checks.count) checks. No microphone access."
        } catch { status = "Synthetic self-test failed." }
    }
}
