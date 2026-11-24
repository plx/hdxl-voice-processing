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
    var recorderStopToResultReadySeconds: Double?
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
    private let session = AVAudioSession.sharedInstance()
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
        "HDXLWatchSegment.caf")
    private var recorder: AVAudioRecorder?
    private var trial: WatchTrial?
    private var origin = 0.0
    private var sessionActive = false
    private var isForeground = false
    private var hasRunFixture = false
    private var timeout: Task<Void, Never>?

    override init() {
        super.init()
        // A force-quit has no reliable callback. Discard the last partial private segment on launch.
        removeRecording()
    }

    func scene(_ phase: ScenePhase) {
        isForeground = phase == .active
        event("scene-\(String(describing: phase))")
        if !isForeground, recording { finishCapture("scene-inactive", analyze: false) }
        if isForeground, !hasRunFixture,
            ProcessInfo.processInfo.arguments.contains("--synthetic-replay")
        {
            hasRunFixture = true
            replay()
        }
    }
    func replay() {
        guard !busy, isForeground else { return }
        begin("synthetic-file")
        analyze(url: nil, stopTime: nil)
    }
    func requestOrRecord() {
        guard !busy, isForeground else { return }
        begin("microphone-file")
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            event("permission-requested")
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                end(granted ? "granted-tap-record" : "permission-denied")
            }
        case .granted: startCapture()
        case .denied: end("permission-denied")
        @unknown default: end("permission-unknown")
        }
    }
    private func startCapture() {
        guard removeRecording() else {
            end("private-file-cleanup-failed")
            return
        }
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            sessionActive = true
            let input = WatchTrial.Input(session)
            trial?.input = input
            guard input.sessionRate.isFinite, (4_000...192_000).contains(input.sessionRate),
                input.sessionChannels > 0, !input.ports.isEmpty
            else {
                finishCapture("no-usable-input", analyze: false)
                return
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: input.sessionRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ]
            let device = try AVAudioRecorder(url: scratch, settings: settings)
            recorder = device
            device.delegate = self
            guard device.record(forDuration: 3) else {
                finishCapture("recorder-refused", analyze: false)
                return
            }
            recording = true
            message = "Recording up to 3 seconds"
            event("recording")
            timeout = Task {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                finishCapture("completion-timeout", analyze: false)
            }
        } catch {
            finishCapture("capture-setup-failed", analyze: false)
        }
    }
    func stop() {
        guard recording else { return }
        finishCapture("user-stop", analyze: true)
    }
    func routeChange() {
        guard recording, WatchTrial.Input(session) != trial?.input else { return }
        finishCapture("route-changed", analyze: false)
    }
    func sessionInactive() {
        guard recording else { return }
        finishCapture("session-inactive", analyze: false)
    }
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == id else { return }
            self.finishCapture(flag ? "duration-ended" : "recorder-failed", analyze: flag)
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder, error: (any Error)?
    ) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == id else { return }
            self.finishCapture("recorder-encode-failed", analyze: false)
        }
    }
    private func finishCapture(_ reason: String, analyze shouldAnalyze: Bool) {
        let stopTime = ProcessInfo.processInfo.systemUptime
        timeout?.cancel()
        timeout = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        recording = false
        event(reason)
        if sessionActive {
            do {
                try session.setActive(false)
                sessionActive = false
            } catch { event("deactivation-failed") }
        }
        if shouldAnalyze {
            analyze(url: scratch, stopTime: stopTime)
        } else {
            removeRecording()
            end(reason)
        }
    }
    private func analyze(url: URL?, stopTime: Double?) {
        message = "Analyzing segment"
        event("analysis-started")
        Task {
            do {
                let result = try await Task.detached {
                    if let url { return try SegmentLevel.read(url) }
                    return try SegmentLevel.replay()
                }.value
                trial?.result = result
                if let stopTime {
                    trial?.recorderStopToResultReadySeconds =
                        ProcessInfo.processInfo.systemUptime - stopTime
                }
                if url != nil { removeRecording() }
                end("published")
                if let value = result.lastWindow?.finiteDecibels {
                    message = String(format: "%.1f dBFS", value)
                } else {
                    message = result.lastWindow?.status.rawValue ?? "No complete window"
                }
            } catch {
                if url != nil { removeRecording() }
                end("analysis-failed")
            }
        }
    }
    private func begin(_ source: String) {
        trial = WatchTrial(source: source)
        origin = ProcessInfo.processInfo.systemUptime
        busy = true
        evidenceError = nil
        event("started")
    }
    private func end(_ status: String) {
        trial?.status = status
        busy = false
        message = status
        event(status)
    }
    @discardableResult
    private func removeRecording() -> Bool {
        guard FileManager.default.fileExists(atPath: scratch.path) else { return true }
        do {
            try FileManager.default.removeItem(at: scratch)
            return true
        } catch {
            evidenceError = "Could not delete the private recording"
            return false
        }
    }
    private func event(_ name: String) {
        guard var current = trial else { return }
        if current.events.count >= 64 { current.events.removeFirst() }
        current.events.append(
            .init(name: name, elapsedSeconds: ProcessInfo.processInfo.systemUptime - origin))
        trial = current
        do {
            let folder = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(current).write(
                to: folder.appendingPathComponent("watch-trial.json"), options: .atomic)
        } catch { evidenceError = "Could not save the trial receipt" }
    }
}
