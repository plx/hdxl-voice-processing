import AVFAudio
import Darwin
import Foundation
import SwiftUI

struct WatchTrial: Encodable {
    struct Event: Codable {
        let name: String
        let elapsedSeconds: Double
    }
    struct Input: Codable, Equatable {
        let sessionRate: Double
        let sessionChannels: Int
        let ioBufferSeconds: Double
        let category: String
        let mode: String
        let ports: [String]

        init(_ session: AVAudioSession) {
            sessionRate = session.sampleRate
            sessionChannels = session.inputNumberOfChannels
            ioBufferSeconds = session.ioBufferDuration
            category = session.category.rawValue
            mode = session.mode.rawValue
            ports = session.currentRoute.inputs.map { $0.portType.rawValue }
        }
    }

    let schemaVersion = 1
    let id = UUID()
    let started = Date()
    let source: String
    let environment: String
    let machine: String
    let system: String
    var status = "started"
    var events = [Event]()
    var input: Input?
    var result: SegmentLevel?
    struct Timing: Encodable {
        let origin: String
        let resultReadySeconds: Double
    }
    var timing: Timing?
    var preflightFileCleanup: String?
    var privateFileCleanup: String?
    var sessionRelease: String?
    // File capture exposes neither hardware frame timestamps nor callback/drop counters.
    let captureDrops = "unobservable"
    init(source: String) {
        self.source = source
        #if targetEnvironment(simulator)
            environment = "watchOS Simulator"
        #else
            environment = "watchOS device"
        #endif
        var hardware = utsname()
        if uname(&hardware) == 0 {
            machine = withUnsafeBytes(of: &hardware.machine) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        } else {
            machine = "unknown"
        }
        system = ProcessInfo.processInfo.operatingSystemVersionString
    }
}

@MainActor
final class WatchProbe: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var message = "Ready"
    @Published private(set) var busy = false
    @Published private(set) var recording = false
    @Published private(set) var evidenceError: String?
    @Published private(set) var cleanupWarning: String?
    @Published private(set) var needsSessionRelease = false
    private let session = AVAudioSession.sharedInstance()
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
        "HDXLWatchSegment.caf")
    private var recorder: AVAudioRecorder?
    private var pendingActivation: UUID?
    // Compare private port identity only in memory. The receipt stores anonymous port types.
    private var inputIDs = [String]()
    private var trial: WatchTrial?
    private var origin = 0.0
    private var sessionActive = false
    private var isForeground = false
    private var hasRunFixture = false
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        // A force-quit has no reliable callback. Discard the last partial private segment on launch.
        struct LaunchRecovery: Encodable {
            let observedAt: Date
            let privateFileCleanup: String
        }
        write(
            LaunchRecovery(observedAt: Date(), privateFileCleanup: removeRecording()),
            to: "watch-launch.json")
    }

    func scene(_ phase: ScenePhase) {
        isForeground = phase == .active
        event("scene-\(String(describing: phase))")
        if !isForeground {
            pendingActivation = nil
            if recording { finishCapture("capture-cancelled-on-scene-change") }
        }
        if isForeground, !hasRunFixture,
            ProcessInfo.processInfo.arguments.contains("--synthetic-replay")
        {
            hasRunFixture = true
            replay()
        }
    }
    func replay() {
        guard !busy, isForeground else { return }
        guard begin("synthetic-file") else { return }
        analyze(url: nil, boundary: nil)
    }
    func requestOrRecord() {
        guard !busy, isForeground else { return }
        guard begin("microphone-file") else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            event("permission-requested")
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                end(granted ? "granted-tap-record" : "permission-denied")
            }
        case .granted:
            guard let id = trial?.id else { return }
            pendingActivation = id
            Task { await startCapture(id) }
        case .denied: end("permission-denied")
        @unknown default: end("permission-unknown")
        }
    }
    private func startCapture(_ id: UUID) async {
        guard isForeground, pendingActivation == id, trial?.id == id else {
            end("activation-cancelled")
            return
        }
        do {
            try session.setCategory(.record, mode: .measurement)
            event("activation-requested")
            guard try await session.activate(options: []) else {
                pendingActivation = nil
                end("activation-refused")
                return
            }
            sessionActive = true
            guard isForeground, pendingActivation == id, trial?.id == id else {
                finishCapture("activation-cancelled")
                return
            }
            pendingActivation = nil
            let input = WatchTrial.Input(session)
            guard input.ioBufferSeconds.isFinite, input.ioBufferSeconds >= 0,
                input.sessionRate.isFinite, (4_000...192_000).contains(input.sessionRate),
                input.sessionChannels > 0, !input.ports.isEmpty
            else {
                finishCapture("no-usable-input")
                return
            }
            trial?.input = input
            inputIDs = session.currentRoute.inputs.map(\.uid)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: input.sessionRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ]
            trial?.privateFileCleanup = "pending"
            event("preparing-recording")
            let device = try AVAudioRecorder(url: scratch, settings: settings)
            recorder = device
            device.delegate = self
            guard device.record(forDuration: 3) else {
                finishCapture("recorder-refused")
                return
            }
            recording = true
            message = "Recording up to 3 seconds"
            event("recording")
            timeout = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                finishCapture("completion-timeout")
            }
        } catch {
            finishCapture("capture-setup-failed")
        }
    }
    func stop() {
        guard recording else { return }
        finishCapture(
            "user-stop", boundary: ("manual-stop-request", ProcessInfo.processInfo.systemUptime))
    }
    func routeChange(_ notification: Notification) {
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?
            .uintValue
        guard recording,
            reason == AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue
                || WatchTrial.Input(session) != trial?.input
                || session.currentRoute.inputs.map(\.uid) != inputIDs
        else { return }
        finishCapture("route-changed")
    }
    func sessionInactive(_ notification: Notification) {
        let context =
            notification.userInfo?[AVAudioSession.deactivationContextKey]
            as? AVAudioSession.DeactivationContext
        guard context?.source != .app else { return }
        pendingActivation = nil
        guard recording else { return }
        finishCapture("session-inactive")
    }
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
        let callbackTime = ProcessInfo.processInfo.systemUptime
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == id else { return }
            self.finishCapture(
                flag ? "duration-ended" : "recorder-failed",
                boundary: flag ? ("completion-callback-entry", callbackTime) : nil)
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder, error: (any Error)?
    ) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == id else { return }
            self.finishCapture("recorder-encode-failed")
        }
    }
    private typealias StopBoundary = (name: String, uptime: Double)
    private func finishCapture(_ reason: String, boundary: StopBoundary? = nil) {
        pendingActivation = nil
        inputIDs.removeAll()
        timeout?.cancel()
        timeout = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        recording = false
        releaseSession()
        if let boundary {
            event(reason)
            analyze(url: scratch, boundary: boundary)
        } else if discardCurrentFile() {
            end(reason)
        } else {
            event(reason)
            end("private-file-cleanup-failed")
        }
    }
    private func analyze(url: URL?, boundary: StopBoundary?) {
        message = "Analyzing segment"
        event("analysis-started")
        Task {
            do {
                let result = try await Task.detached {
                    if let url { return try SegmentLevel.read(url) }
                    return try SegmentLevel.replay()
                }.value
                trial?.result = result
                if let boundary {
                    trial?.timing = .init(
                        origin: boundary.name,
                        resultReadySeconds: ProcessInfo.processInfo.systemUptime - boundary.uptime)
                }
                if url != nil, !discardCurrentFile() {
                    end("private-file-cleanup-failed")
                    return
                }
                end(needsSessionRelease ? "published-release-pending" : "published")
                if let value = result.lastWindow?.finiteDecibels {
                    message = String(format: "%.1f dBFS", value)
                } else {
                    message = result.lastWindow?.status.rawValue ?? "No complete window"
                }
            } catch {
                event("analysis-error")
                end(
                    url == nil || discardCurrentFile()
                        ? "analysis-failed" : "private-file-cleanup-failed")
            }
        }
    }
    func retryRelease() {
        guard !busy, needsSessionRelease else { return }
        releaseSession()
        if !needsSessionRelease { message = "Audio session released" }
    }
    private func releaseSession() {
        guard sessionActive else { return }
        do {
            try session.setActive(false)
            sessionActive = false
            needsSessionRelease = false
            trial?.sessionRelease = "released"
        } catch {
            needsSessionRelease = true
            trial?.sessionRelease = "failed"
            event("deactivation-failed")
        }
    }
    private func begin(_ source: String) -> Bool {
        guard !needsSessionRelease else { return false }
        trial = WatchTrial(source: source)
        origin = ProcessInfo.processInfo.systemUptime
        busy = true
        evidenceError = nil
        let cleanup = removeRecording()
        trial?.preflightFileCleanup = cleanup
        event("started")
        guard cleanup != "failed" else {
            end("private-file-cleanup-failed")
            return false
        }
        return true
    }
    private func end(_ status: String) {
        trial?.status = status
        busy = false
        message = status
        event(status)
        trial = nil
    }
    private func discardCurrentFile() -> Bool {
        guard trial?.privateFileCleanup == "pending" else { return true }
        let outcome = removeRecording()
        trial?.privateFileCleanup = outcome
        return outcome != "failed"
    }
    private func removeRecording() -> String {
        do {
            try FileManager.default.removeItem(at: scratch)
            cleanupWarning = nil
            return "removed"
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            cleanupWarning = nil
            return "absent"
        } catch {
            cleanupWarning = "Could not delete the private recording"
            return "failed"
        }
    }
    private func event(_ name: String) {
        guard var current = trial else { return }
        if current.events.count >= 64 { current.events.removeFirst() }
        current.events.append(
            .init(name: name, elapsedSeconds: ProcessInfo.processInfo.systemUptime - origin))
        trial = current
        write(current, to: "watch-trial.json")
    }
    private func write(_ value: some Encodable, to filename: String) {
        do {
            let folder = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(
                to: folder.appendingPathComponent(filename), options: .atomic)
        } catch { evidenceError = "Could not save the trial receipt" }
    }
}
