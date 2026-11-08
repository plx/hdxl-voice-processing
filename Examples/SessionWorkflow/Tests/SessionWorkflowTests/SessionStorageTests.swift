import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio
import XCTest

#if canImport(SessionWorkflowSupport)
    import SessionWorkflowSupport
#else
    @testable import IOSCaptureHost
#endif

/// The identical public-host lifecycle assertions run on macOS and iOS Simulator.
final class SessionStorageTests: XCTestCase {
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(
            "storage-tests-\(UUID())")
        try FileManager.default.createDirectory(
            at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return result
    }

    func testSyntheticStorageSharingAndOriginalPCMReplay() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("session.hvps")
        let share = root.appendingPathComponent("share.hvps")
        let audioFree = try StoredSessionWorkflow.createSynthetic(at: archive, scratch: root)
        XCTAssertEqual(audioFree.audioPolicy, "omit")
        XCTAssertEqual(audioFree.embeddedAudioBytes, 0)
        XCTAssertEqual(audioFree.completion, "completed")
        XCTAssertEqual(audioFree.replayPlans, 1)
        XCTAssertEqual(audioFree.targetsForInspection, 0)
        XCTAssertGreaterThanOrEqual(audioFree.measurements, 98)
        XCTAssertThrowsError(try StoredSessionWorkflow.replay(at: archive, scratch: root)) {
            XCTAssertEqual($0 as? SessionArchiveError, .missingMedia)
        }
        try StoredSessionWorkflow.shareCopy(from: archive, to: share)
        XCTAssertEqual(try Data(contentsOf: share), try Data(contentsOf: archive))
        try StoredSessionWorkflow.delete(at: share)

        let withAudio = try StoredSessionWorkflow.createSynthetic(
            at: archive, scratch: root, includeAudio: true, publication: .replace)
        XCTAssertEqual(withAudio.audioPolicy, "explicitlyInclude")
        XCTAssertEqual(withAudio.embeddedAudioBytes, 32_044)
        XCTAssertEqual(withAudio.measurements, audioFree.measurements)
        XCTAssertThrowsError(try StoredSessionWorkflow.shareCopy(from: archive, to: share)) {
            XCTAssertEqual($0 as? SessionArchiveError, .audioNotOptedIn)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.path))
        try StoredSessionWorkflow.shareCopy(from: archive, to: share, includeAudio: true)
        XCTAssertEqual(try Data(contentsOf: share), try Data(contentsOf: archive))
        XCTAssertEqual(
            try StoredSessionWorkflow.replay(at: archive, scratch: root), withAudio.measurements)

        // This small synthetic sample may be retained for exact replay comparison;
        // the general APIs and long-session benchmark consume one event at a time.
        var stored: [SessionArchiveMeasurement] = []
        let reader = try SessionArchiveFiles.inspect(
            at: archive, limits: StoredSessionWorkflow.limits(),
            visit: {
                if case .measurement(_, let value) = $0 { stored.append(value) }
            })
        var replayed: [SessionArchiveMeasurement] = []
        let source = try reader.source(at: 0)
        let series = try reader.series(at: 0)
        _ = try SessionArchiveAudioReplay.run(
            at: archive, planIndex: 0, scratchDirectory: root,
            archiveLimits: StoredSessionWorkflow.limits(),
            replayLimits: SessionArchiveReplayLimits(
                decodedChunkCapacity: 1024, sourceTileCapacity: 256)
        ) { replayed.append(try SessionArchiveMeasurement($0, source: source, series: series)) }
        XCTAssertEqual(stored, replayed)
        var available = 0
        for value in stored {
            if case .available(let scalar) = value.result.outcome {
                XCTAssertEqual(scalar.value, 0.25)
                available += 1
            }
        }
        XCTAssertEqual(available, 98)
        try StoredSessionWorkflow.delete(at: archive)
        XCTAssertEqual(try StoredSessionWorkflow.inspect(at: share), withAudio)
        try StoredSessionWorkflow.delete(at: share)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testImportReplacementRefusesCorruptionAndPreservesPriorSession() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("session.hvps")
        let input = root.appendingPathComponent("chosen-import.hvps")
        _ = try StoredSessionWorkflow.createSynthetic(at: archive, scratch: root)
        let original = try Data(contentsOf: archive)
        let inputSummary = try StoredSessionWorkflow.createSynthetic(
            at: input, scratch: root, includeAudio: true)
        let incoming = try Data(contentsOf: input)
        try Data(incoming.dropLast()).write(to: input)
        XCTAssertThrowsError(try StoredSessionWorkflow.importArchive(from: input, to: archive))
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertThrowsError(try StoredSessionWorkflow.createSynthetic(at: archive, scratch: root))
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertThrowsError(
            try StoredSessionWorkflow.createSynthetic(
                at: archive, scratch: root, publication: .replace, shouldContinue: { false })
        ) {
            XCTAssertEqual($0 as? SessionArchiveError, .cancelled)
        }
        XCTAssertEqual(try Data(contentsOf: archive), original)
        try incoming.write(to: input)
        XCTAssertEqual(
            try StoredSessionWorkflow.importArchive(from: input, to: archive), inputSummary)
        XCTAssertEqual(try Data(contentsOf: archive), incoming)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["chosen-import.hvps", "session.hvps"])
    }
}
