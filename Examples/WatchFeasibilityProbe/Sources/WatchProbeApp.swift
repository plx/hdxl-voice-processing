import AVFAudio
import SwiftUI

@main
struct WatchProbeApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var probe = WatchProbe()

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack {
                    Text(probe.message)
                    if let warning = probe.cleanupWarning { Text(warning) }
                    if let error = probe.evidenceError { Text(error) }
                    Button("Replay fixture") { probe.replay() }.disabled(probe.busy)
                    Button("Record segment") { probe.requestOrRecord() }.disabled(probe.busy)
                    if probe.recording { Button("Stop") { probe.stop() } }
                }
            }
            .onChange(of: phase, initial: true) { _, newPhase in probe.scene(newPhase) }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: AVAudioSession.didBecomeInactiveNotification)
            ) { _ in
                probe.sessionInactive()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            ) { _ in
                probe.routeChange()
            }
        }
    }
}
