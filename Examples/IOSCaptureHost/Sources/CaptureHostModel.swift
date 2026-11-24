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
    private(set) var drained: HostPCMConsumer.Counts?
    private(set) var transport: PCMTransferSnapshot?
    private(set) var queueCapacity = 0
    private(set) var maximumFramesPerChunk: UInt32 = 0
    private(set) var durationNS: UInt64?
    @ObservationIgnored private var startedNS: UInt64?
    private(set) var boundary: String?
    private(set) var resourceReport: String?
    @ObservationIgnored private var history = CaptureResourceHistory()
    private(set) var sessionNeedsAttention = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var counters: Task<Void, Never>?
    @ObservationIgnored private lazy var capture = IOSMicrophoneCapture { [weak self] event in
        self?.receive(event)
    }

    func start() {
        guard !isBusy, !sessionNeedsAttention else { return }
        isBusy = true
        resourceReport = nil
        startedNS = nil
        durationNS = nil
        boundary = nil
        drained = nil
        transport = nil
        queueCapacity = 0
        maximumFramesPerChunk = 0
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
        var worker: Task<HostPCMConsumer.Counts, any Error>?
        var transfer: PCMTransfer?
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
            transfer = session.transfer
            let task = Task.detached { [capture] in
                try await HostPCMConsumer.drain(session.transfer) { await capture.stop() }
            }
            worker = task
            drained = try await task.value
        } catch let failure as HostPCMConsumer.GapFailure {
            drained = failure.counts
            problem = failure
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
        if let transfer {
            transport = transfer.snapshot()
            history.observe(transfer, finishing: true)
            if let data = try? JSONEncoder().encode(history.readings) {
                resourceReport = String(decoding: data, as: UTF8.self)
            }
        }
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
            : problem.map(HostErrorReport.message)
                ?? "Stopped. Consumed \(drained?.frames ?? 0) sample frames."
        isBusy = false
        operation = nil
    }

    private func receive(_ event: IOSCaptureEvent) {
        switch event {
        case .started(let session):
            let now = DispatchTime.now().uptimeNanoseconds
            startedNS = now
            history = CaptureResourceHistory(startNS: now)
            history.observe(session.transfer)
            observation = session.observation
            queueCapacity = session.transfer.configuration.slotCount
            maximumFramesPerChunk = session.transfer.configuration.maximumFramesPerChunk
            status = "Capturing in the foreground."
            counters = Task {
                while !Task.isCancelled {
                    history.observe(session.transfer)
                    transport = session.transfer.snapshot()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        case .stopped:
            if let startedNS, durationNS == nil {
                durationNS = DispatchTime.now().uptimeNanoseconds - startedNS
            }
        case .configurationChanged(_, let change, let discontinuity):
            if let startedNS, durationNS == nil {
                durationNS = DispatchTime.now().uptimeNanoseconds - startedNS
            }
            let name: String
            switch change {
            case .route: name = "Route change"
            case .systemInterruption: name = "System interruption"
            case .enteredBackground: name = "Entered background"
            case .mediaServicesLost: name = "Media services lost"
            case .mediaServicesReset: name = "Media services reset"
            default: name = "Configuration change"
            }
            if let discontinuity {
                let extent =
                    discontinuity.missingSource.map { "\($0.sampleCount) missing source frames" }
                    ?? "unknown loss extent"
                boundary = "\(name), \(discontinuity.reason.rawValue), \(extent)"
            } else {
                boundary = "\(name), no source boundary observed"
            }
            status = "Capture conditions changed. Stopping…"
        case .calibrationInvalidated:
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
