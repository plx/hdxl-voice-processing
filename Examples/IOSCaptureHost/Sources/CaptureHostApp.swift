import HDXLVoiceProcessingAudio
import SwiftUI

@main struct CaptureHostApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CaptureHostModel()
    private let synthetic = CommandLine.arguments.contains("--self-test")

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section("Microphone") {
                        Text(model.status).accessibilityIdentifier("capture-status")
                        Button("Start capture") { model.start() }
                            .disabled(model.isBusy || model.sessionNeedsAttention || synthetic)
                        Button("Stop", role: .cancel) { model.stop() }
                            .disabled(!model.isBusy || synthetic)
                        LabeledContent("Accepted chunks", value: "\(model.acceptedChunks)")
                    }
                    if let observation = model.observation {
                        Section("Effective settings") {
                            let format = observation.capture.effectiveFormat
                            LabeledContent("Tap sample rate", value: "\(format.sampleRate) Hz")
                            LabeledContent("Native channels", value: "\(format.channelCount)")
                            LabeledContent("Sample encoding", value: format.encoding.rawValue)
                            LabeledContent("Buffer layout", value: format.layout.rawValue)
                            LabeledContent(
                                "Session sample rate",
                                value: "\(observation.audioSession.sampleRate) Hz")
                            LabeledContent(
                                "I/O buffer",
                                value: "\(observation.audioSession.ioBufferDuration) s")
                            LabeledContent("Session mode", value: observation.audioSession.mode)
                            LabeledContent(
                                "Engine voice processing",
                                value: state(observation.capture.processing.engineVoiceProcessing))
                            LabeledContent(
                                "Session echo-cancelled input",
                                value: state(observation.audioSession.echoCancelledInputEnabled))
                            Text(
                                "Other route and device processing is unknown. Measurement mode does not prove raw audio."
                            )
                        }
                    }
                    Section("Development host") {
                        NavigationLink("Session storage and sharing") { SessionStorageView() }
                            .disabled(synthetic)
                            .accessibilityIdentifier("session-storage-navigation")
                        Text(
                            "Foreground capture only. Stop or background the app to end capture. Microphone audio is never saved or uploaded by this host."
                        )
                        Text(
                            "Device route and timing measurements remain pending physical validation."
                        )
                    }
                }
                .navigationTitle("Capture Check")
            }
            .task { if synthetic { await model.runSelfTest() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.stop(background: true) }
            }
        }
    }

    private func state(_ observation: CaptureObservation<Bool>) -> String {
        switch observation {
        case .unknown: "Unknown"
        case .observed(let value): value ? "Enabled" : "Disabled"
        }
    }
}
