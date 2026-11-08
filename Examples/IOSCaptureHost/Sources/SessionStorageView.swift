import Foundation
import HDXLVoiceProcessing
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// This screen owns one private archive and explicit sharing copies. It never
/// consumes the microphone host's buffers or starts audio-session activity.
struct SessionStorageView: View {
    @State private var model = SessionStorageModel()
    @State private var includeAudio = false
    @State private var importing = false

    var body: some View {
        Form {
            Section("Saved session") {
                Text(model.status).accessibilityIdentifier("session-storage-status")
                if let summary = model.inspection {
                    LabeledContent("Measurements", value: "\(summary.measurements)")
                    LabeledContent("Completion", value: summary.completion)
                    LabeledContent("Embedded audio", value: "\(summary.embeddedAudioBytes) bytes")
                    LabeledContent(
                        "Targets for inspection", value: "\(summary.targetsForInspection)")
                    Text("Imported targets remain inactive.")
                }
                Button("Inspect saved session") { model.inspect() }
                    .accessibilityIdentifier("session-inspect")
                Button("Import and replace saved session…") { importing = true }
                    .accessibilityIdentifier("session-import")
                Text(
                    "Imports may contain audio. Their complete contents are verified before replacing the saved session."
                )
            }
            Section("Synthetic example") {
                Toggle("Include original synthetic audio", isOn: $includeAudio)
                    .accessibilityIdentifier("session-include-audio")
                Button("Create or replace synthetic session") {
                    model.create(includeAudio: includeAudio)
                }
                .accessibilityIdentifier("session-create")
                Text(
                    "Analyzes a one-second generated signal. Microphone capture is separate and is never saved here."
                )
                Button("Reanalyze first stored plan") { model.replay() }
                    .disabled(
                        model.inspection?.replayPlans == nil || model.inspection?.replayPlans == 0
                    )
                    .accessibilityIdentifier("session-replay")
            }
            Section("Sharing") {
                if let summary = model.inspection {
                    Text(
                        summary.audioPolicy == "omit"
                            ? "This archive omits audio. Measurements, labels and notes can still be personal."
                            : "This archive permits audio and contains \(summary.embeddedAudioBytes) embedded bytes. Sharing includes its complete contents."
                    )
                    Button(
                        summary.audioPolicy == "omit"
                            ? "Prepare sharing copy" : "Prepare sharing copy including audio"
                    ) {
                        model.prepareShare(includeAudio: summary.audioPolicy != "omit")
                    }
                    .accessibilityIdentifier("session-prepare-share")
                }
                if let url = model.shareURL {
                    ShareLink("Share prepared archive…", item: url)
                        .accessibilityIdentifier("session-share")
                }
                Text("Choose a recipient using the system share sheet. No automatic upload occurs.")
            }
            Section("Local storage") {
                Button("Delete saved session and local sharing copies", role: .destructive) {
                    model.delete()
                }
                .accessibilityIdentifier("session-delete")
                Text("Deletion cannot remove copies already sent to another app or recipient.")
            }
        }
        .disabled(model.isBusy)
        .overlay { if model.isBusy { ProgressView("Working…") } }
        .navigationTitle("Session Storage")
        .task { model.inspect() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { model.importArchive(url) }
        }
    }
}

@MainActor @Observable private final class SessionStorageModel {
    private(set) var status = "No session loaded."
    private(set) var isBusy = false
    private(set) var inspection: StoredSessionWorkflow.Inspection?
    private(set) var shareURL: URL?

    private enum Outcome: Sendable {
        case inspected(StoredSessionWorkflow.Inspection?)
        case shared(URL)
        case replayed(UInt64)
        case deleted
    }

    func inspect() {
        perform { root in
            let url = Self.archive(root)
            return .inspected(
                FileManager.default.fileExists(atPath: url.path)
                    ? try StoredSessionWorkflow.inspect(at: url) : nil)
        }
    }

    func create(includeAudio: Bool) {
        perform { root in
            .inspected(
                try StoredSessionWorkflow.createSynthetic(
                    at: Self.archive(root), scratch: root, includeAudio: includeAudio,
                    publication: .replace))
        }
    }

    func importArchive(_ source: URL) {
        perform { root in
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            return .inspected(
                try StoredSessionWorkflow.importArchive(from: source, to: Self.archive(root)))
        }
    }

    func prepareShare(includeAudio: Bool) {
        perform { root in
            let copy = root.appendingPathComponent("share-\(UUID()).hvps")
            try StoredSessionWorkflow.shareCopy(
                from: Self.archive(root), to: copy, includeAudio: includeAudio)
            return .shared(copy)
        }
    }

    func replay() {
        perform { root in
            .replayed(try StoredSessionWorkflow.replay(at: Self.archive(root), scratch: root))
        }
    }

    func delete() {
        perform { root in
            for url in try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
            {
                let name = url.lastPathComponent
                let shareID =
                    name.hasPrefix("share-") && name.hasSuffix(".hvps")
                    ? UUID(uuidString: String(name.dropFirst(6).dropLast(5))) : nil
                if name == "session.hvps" || shareID != nil {
                    try StoredSessionWorkflow.delete(at: url)
                }
            }
            return .deleted
        }
    }

    nonisolated private static func archive(_ root: URL) -> URL {
        root.appendingPathComponent("session.hvps")
    }

    /// One operation at a time; filesystem/decoder work stays off the main actor.
    /// The task retains its owner until completion, even if navigation changes.
    private func perform(_ work: @escaping @Sendable (URL) throws -> Outcome) {
        guard !isBusy else { return }
        isBusy = true
        shareURL = nil
        status = "Working…"
        Task {
            defer { isBusy = false }
            do {
                let outcome = try await Task.detached(priority: .utility) {
                    var root = URL.applicationSupportDirectory.appendingPathComponent(
                        "SessionExample", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: root, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try root.setResourceValues(values)
                    return try work(root)
                }.value
                switch outcome {
                case .inspected(let summary):
                    inspection = summary
                    status =
                        summary == nil
                        ? "No saved session." : "Verified session available for inspection."
                case .shared(let url):
                    shareURL = url
                    status = "Sharing copy ready. Choose Share to send it."
                case .replayed(let count): status = "Reanalysis completed: \(count) measurements."
                case .deleted:
                    inspection = nil
                    status = "Local session and sharing copies deleted."
                }
            } catch {
                inspection = nil
                if (error as? SessionArchiveError) == .missingMedia {
                    status =
                        "Original audio is unavailable for this plan. Inspect to reload the saved session."
                } else {
                    status =
                        "Operation failed: \(StoredSessionWorkflow.failureCode(error)). Inspect to reload saved state."
                }
            }
        }
    }
}

#Preview { NavigationStack { SessionStorageView() } }
