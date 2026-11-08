import Darwin
import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingAudio

func sessionFileTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "session-test-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

func sessionFileTestHeader(audio: Bool = false, notes: String = "") throws -> SessionArchiveHeader {
    try SessionArchiveHeader(
        id: UUID(), producer: VersionedIdentifier(name: "synthetic-test", version: 1),
        audioPolicy: audio ? .explicitlyInclude : .omit, notes: notes)
}

func sessionFileTestMedia(_ bytes: Data, embedded: Bool = true) throws
    -> SessionArchiveMediaReference
{
    try SessionArchiveMediaReference(
        media: CalibrationMediaReference(
            referenceIdentifier: "synthetic-original", originalRecordingID: UUID(),
            content: CalibrationDigest(bytes: bytes), byteCount: Int64(bytes.count)),
        decoder: CalibrationDecoderProvenance(
            identifier: "synthetic-container", runtime: "synthetic-test",
            storage: ["container": .text("synthetic")],
            decodedPCM: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float32),
            fileSampleCount: 1), inclusion: embedded ? .embedded : .omitted,
        provenance: VersionedIdentifier(name: "synthetic-file", version: 1))
}

private func sessionFileNames(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

private func sessionMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
}

@Test func sessionFilesPublishCreateReplaceDeleteAndKeepStagesPrivate() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("chosen-session.hvps")
    let first = try sessionFileTestHeader()
    let limits = try SessionArchiveLimits()
    let statistics = try SessionArchiveFiles.write(to: destination, header: first, limits: limits) {
        _ in
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let stage = directory.appendingPathComponent(
            try #require(sessionFileNames(directory).first))
        #expect(try sessionMode(stage) == 0o700)
        #expect(try sessionMode(stage.appendingPathComponent("archive.part")) == 0o600)
    }
    #expect(statistics.framedRecords == 2)
    #expect(try sessionFileNames(directory) == ["chosen-session.hvps"])
    #expect(try sessionMode(destination) == 0o600)
    let read = try SessionArchiveFiles.inspect(at: destination, limits: limits)
    #expect(read.header == first && read.seal?.completion == .completed)
    let old = try Data(contentsOf: destination)
    #expect(throws: SessionArchiveError.outputFailure) {
        try SessionArchiveFiles.write(
            to: destination, header: sessionFileTestHeader(), limits: limits
        ) { _ in }
    }
    #expect(try Data(contentsOf: destination) == old)
    let second = try sessionFileTestHeader(notes: "Explicitly unfinished acquisition")
    try SessionArchiveFiles.write(
        to: destination, publication: .replace, header: second, limits: limits,
        completion: .partial
    ) { _ in }
    let replaced = try SessionArchiveFiles.inspect(at: destination, limits: limits)
    #expect(replaced.header == second && replaced.seal?.completion == .partial)
    try SessionArchiveFiles.delete(at: destination)
    #expect(try sessionFileNames(directory).isEmpty)
    #expect(throws: SessionArchiveError.outputFailure) {
        try SessionArchiveFiles.delete(at: destination)
    }
}

@Test func sessionFilesFailureAndCancellationPreservePreviousDestination() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("previous.hvps")
    let old = Data("previous destination".utf8)
    try old.write(to: destination)
    let limits = try SessionArchiveLimits()
    let header = try sessionFileTestHeader()
    #expect(throws: SessionArchiveError.outputFailure) {
        try SessionArchiveFiles.write(
            to: destination, publication: .replace, header: header, limits: limits
        ) { _ in
            throw NSError(domain: "personal-value-and-private-path", code: 1)
        }
    }
    #expect(try Data(contentsOf: destination) == old)
    #expect(throws: SessionArchiveError.invalidState) {
        try SessionArchiveFiles.write(
            to: destination, publication: .replace, header: header, limits: limits
        ) {
            try $0.finish()
        }
    }
    #expect(try Data(contentsOf: destination) == old)
    var calls = 0
    #expect(throws: SessionArchiveError.cancelled) {
        try SessionArchiveFiles.write(
            to: destination, publication: .replace, header: header, limits: limits,
            shouldContinue: {
                calls += 1
                return calls < 4
            }, populate: { _ in })
    }
    #expect(calls == 4)
    #expect(try Data(contentsOf: destination) == old)
    // Observe a complete staged container, then cancel at the final publication
    // checkpoint. Even an already sealed/flushed replacement must leave the old
    // destination intact when the host withdraws permission before rename.
    var sealedChecks = 0
    #expect(throws: SessionArchiveError.cancelled) {
        try SessionArchiveFiles.write(
            to: destination, publication: .replace, header: header, limits: limits,
            shouldContinue: {
                if let names = try? sessionFileNames(directory),
                    let name = names.first(where: { $0.hasPrefix(".hdxl-session-") }),
                    let staged = try? SessionArchiveFiles.inspect(
                        at: directory.appendingPathComponent(name).appendingPathComponent(
                            "archive.part"),
                        limits: limits), staged.seal != nil
                {
                    sealedChecks += 1
                }
                return sealedChecks < 2
            }, populate: { _ in })
    }
    #expect(sealedChecks == 2)
    #expect(try Data(contentsOf: destination) == old)
    #expect(throws: SessionArchiveError.catalogLimitExceeded) {
        try SessionArchiveFiles.write(
            to: destination, publication: .replace,
            header: sessionFileTestHeader(notes: String(repeating: "x", count: 2000)),
            limits: SessionArchiveLimits(maximumRecordBytes: 1024)
        ) { _ in }
    }
    #expect(try Data(contentsOf: destination) == old)
    #expect(try sessionFileNames(directory) == ["previous.hvps"])
}

@Test func sessionFilesRefuseLinksDirectoriesPipesAndOversizedInputs() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("original")
    let link = directory.appendingPathComponent("link")
    let fifo = directory.appendingPathComponent("pipe")
    let data = Data(repeating: 31, count: 4096)
    try data.write(to: original)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let limits = try SessionArchiveLimits()
    for url in [link, directory, fifo] {
        #expect(throws: SessionArchiveError.inputFailure) {
            try SessionArchiveFiles.inspect(at: url, limits: limits)
        }
        #expect(throws: SessionArchiveError.outputFailure) {
            try SessionArchiveFiles.delete(at: url)
        }
        #expect(throws: SessionArchiveError.outputFailure) {
            try SessionArchiveFiles.write(
                to: url, publication: .replace, header: sessionFileTestHeader(), limits: limits
            ) { _ in }
        }
    }
    #expect(try Data(contentsOf: original) == data)
    let bound = try SessionArchiveLimits(
        maximumArchiveBytes: 1024, maximumRecordBytes: 512, maximumCatalogBytes: 512,
        maximumEmbeddedMediaBytes: 0)
    #expect(throws: SessionArchiveError.sizeLimitExceeded) {
        try SessionArchiveFiles.inspect(at: original, limits: bound)
    }
    let directoryLink = directory.appendingPathComponent("directory-link")
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
    #expect(throws: SessionArchiveError.outputFailure) {
        try SessionArchiveFiles.write(
            to: directoryLink.appendingPathComponent("unsafe.hvps"),
            header: sessionFileTestHeader(), limits: limits
        ) { _ in }
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("unsafe.hvps").path))
}

@Test func sessionFilesInterruptedPrefixIsInspectableAndCleanupIsExplicit() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stage = directory.appendingPathComponent(".hdxl-session-\(UUID())")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    let file = stage.appendingPathComponent("archive.part")
    var prefix = Data()
    _ = try SessionArchiveWriter(header: sessionFileTestHeader(), limits: SessionArchiveLimits()) {
        prefix.append($0)
    }
    try prefix.write(to: file)
    #expect(throws: SessionArchiveError.truncated) {
        try SessionArchiveFiles.inspect(at: file, limits: SessionArchiveLimits())
    }
    let recovered = try SessionArchiveFiles.inspect(
        at: file, limits: SessionArchiveLimits(), recovery: .inspectCompletePrefix)
    #expect(recovered.isIncomplete && recovered.seal == nil)
    #expect(FileManager.default.fileExists(atPath: stage.path))
    try SessionArchiveFiles.removeAbandonedStage(at: stage)
    #expect(try sessionFileNames(directory).isEmpty)
    #expect(throws: SessionArchiveError.invalidConfiguration) {
        try SessionArchiveFiles.removeAbandonedStage(at: directory)
    }
    let unexpected = directory.appendingPathComponent(".hdxl-session-\(UUID())")
    try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: false)
    try Data("unowned".utf8).write(to: unexpected.appendingPathComponent("other"))
    #expect(throws: SessionArchiveError.outputFailure) {
        try SessionArchiveFiles.removeAbandonedStage(at: unexpected)
    }
    #expect(try sessionFileNames(unexpected) == ["other"])
}

@Test func sessionFilesEmbeddedMediaRequiresWholeSealAndAlwaysCleansPrivateCopy() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("audio.hvps")
    let original = directory.appendingPathComponent("original")
    let audio = Data((0..<70_003).map { UInt8($0 % 251) })
    try audio.write(to: original)
    let limits = try SessionArchiveLimits(ioChunkCapacity: 256)
    let reference = try sessionFileTestMedia(audio)
    try SessionArchiveFiles.write(
        to: archive, header: sessionFileTestHeader(audio: true), limits: limits
    ) {
        try SessionArchiveFiles.appendMediaFile(at: original, reference: reference, to: $0)
        let other = try sessionFileTestMedia(Data("second-original".utf8))
        let index = try $0.addMediaReference(other)
        try $0.appendMedia(Data("second-original".utf8), to: index)
    }
    var chunks = 0
    let inspected = try SessionArchiveFiles.inspect(
        at: archive, limits: limits,
        visit: { event in
            if case .mediaChunk(let chunk) = event {
                chunks += 1
                #expect(chunk.bytes == nil)
            }
        })
    #expect(inspected.seal != nil && chunks == 3)
    var temporary: URL?
    let returned = try SessionArchiveFiles.withVerifiedMedia(
        at: archive, referenceIndex: 0, scratchDirectory: directory, limits: limits
    ) { reader, url throws -> UInt64 in
        temporary = url
        #expect(reader.seal != nil)
        #expect(try Data(contentsOf: url) == audio)
        #expect(try sessionMode(url) == 0o600)
        #expect(try sessionMode(url.deletingLastPathComponent()) == 0o700)
        return reader.statistics.embeddedMediaBytes
    }
    #expect(returned == UInt64(audio.count + 15))
    #expect(!FileManager.default.fileExists(atPath: try #require(temporary).path))
    #expect(throws: SessionArchiveError.inputFailure) {
        try SessionArchiveFiles.withVerifiedMedia(
            at: archive, referenceIndex: 0, scratchDirectory: directory, limits: limits
        ) { _, url in
            temporary = url
            throw NSError(domain: "private-details", code: 1)
        }
    }
    #expect(!FileManager.default.fileExists(atPath: try #require(temporary).path))
    var reads = 0
    #expect(throws: SessionArchiveError.cancelled) {
        try SessionArchiveFiles.withVerifiedMedia(
            at: archive, referenceIndex: 0, scratchDirectory: directory, limits: limits,
            shouldContinue: {
                reads += 1
                return reads < 5
            }, body: { _, _ in Issue.record("Cancelled extraction must not deliver a file") })
    }
    #expect(try sessionFileNames(directory) == ["audio.hvps", "original"])
    let complete = try Data(contentsOf: archive)
    for damaged in [Data(complete.dropLast()), complete + Data([0])] {
        try damaged.write(to: archive)
        #expect(throws: (any Error).self) {
            try SessionArchiveFiles.withVerifiedMedia(
                at: archive, referenceIndex: 0, scratchDirectory: directory, limits: limits
            ) { _, _ in Issue.record("Unverified container must not deliver a file") }
        }
        #expect(try sessionFileNames(directory) == ["audio.hvps", "original"])
    }
}

@Test func sessionFilesMissingMediaAndChangedOriginalFailWithoutPublishing() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("audio-free.hvps")
    let original = directory.appendingPathComponent("original")
    let limits = try SessionArchiveLimits()
    let audio = Data("abc".utf8)
    try SessionArchiveFiles.write(to: archive, header: sessionFileTestHeader(), limits: limits) {
        try $0.addMediaReference(sessionFileTestMedia(audio, embedded: false))
    }
    let before = try Data(contentsOf: archive)
    for index: UInt32 in [0, 1] {
        #expect(throws: SessionArchiveError.missingMedia) {
            try SessionArchiveFiles.withVerifiedMedia(
                at: archive, referenceIndex: index, scratchDirectory: directory, limits: limits
            ) { _, _ in Issue.record("Missing media must remain missing") }
        }
    }
    for changed in [Data("xy".utf8), Data("xyz".utf8)] {
        try changed.write(to: original)
        #expect(throws: SessionArchiveError.integrityMismatch) {
            try SessionArchiveFiles.write(
                to: archive, publication: .replace,
                header: sessionFileTestHeader(audio: true), limits: limits
            ) { writer in
                try SessionArchiveFiles.appendMediaFile(
                    at: original, reference: sessionFileTestMedia(audio), to: writer)
            }
        }
        #expect(try Data(contentsOf: archive) == before)
    }
    #expect(try sessionFileNames(directory) == ["audio-free.hvps", "original"])
}

@Test func sessionFilesShareCopyPreservesExactBytesAndRejectsUnverifiedReplacement() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.hvps")
    let destination = directory.appendingPathComponent("explicit-share-copy.hvps")
    let limits = try SessionArchiveLimits(ioChunkCapacity: 256)
    let media = Data((0..<70_003).map { UInt8($0 % 251) })
    try SessionArchiveFiles.write(
        to: source, header: sessionFileTestHeader(audio: true), limits: limits,
        completion: .cancelled
    ) { writer in
        try writer.addMediaReference(sessionFileTestMedia(media))
        try writer.appendMedia(Data(media.prefix(65_536)), to: 0)
        try writer.appendMedia(Data(media.dropFirst(65_536)), to: 0)
    }
    let original = try Data(contentsOf: source)
    #expect(throws: SessionArchiveError.audioNotOptedIn) {
        try SessionArchiveFiles.copyVerified(from: source, to: destination, limits: limits)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(
        try !FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains(where: { $0.hasPrefix(".hdxl-session-") }))
    let copied = try SessionArchiveFiles.copyVerified(
        from: source, to: destination, audioPolicy: .explicitlyInclude, limits: limits)
    #expect(try Data(contentsOf: destination) == original)
    #expect(try sessionMode(destination) == 0o600)
    #expect(copied.embeddedMediaBytes == UInt64(media.count) && copied.maximumIOChunkBytes <= 256)
    #expect(
        try SessionArchiveFiles.inspect(at: destination, limits: limits).seal?.completion
            == .cancelled)
    #expect(throws: SessionArchiveError.outputFailure) {
        try SessionArchiveFiles.copyVerified(
            from: source, to: destination, audioPolicy: .explicitlyInclude, limits: limits)
    }
    var calls = 0
    #expect(throws: SessionArchiveError.cancelled) {
        try SessionArchiveFiles.copyVerified(
            from: source, to: destination, publication: .replace, audioPolicy: .explicitlyInclude,
            limits: limits,
            shouldContinue: {
                calls += 1
                return calls < 10
            })
    }
    #expect(try Data(contentsOf: destination) == original)
    for damaged in [Data(original.dropLast()), original + Data([0])] {
        try damaged.write(to: source)
        #expect(throws: (any Error).self) {
            try SessionArchiveFiles.copyVerified(
                from: source, to: destination, publication: .replace,
                audioPolicy: .explicitlyInclude, limits: limits)
        }
        #expect(try Data(contentsOf: destination) == original)
    }
    #expect(try sessionFileNames(directory) == ["explicit-share-copy.hvps", "source.hvps"])
}
