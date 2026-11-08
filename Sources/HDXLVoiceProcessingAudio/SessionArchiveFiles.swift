import Darwin
import Foundation
import HDXLVoiceProcessing

public enum SessionArchiveFilePublication: Sendable, Hashable {
    /// Atomically refuse an existing destination, including a symbolic link.
    case create
    /// Replace a regular destination, or create it if absent.
    case replace
}

/// Synchronous worker-only storage. Hosts supply and serialize access to trusted
/// local directories, own retention, and explicitly initiate any sharing. No
/// method logs paths, personal values or audio. Final-component symlinks and
/// nonregular inputs are refused; ancestor directory policy belongs to the host.
public enum SessionArchiveFiles {
    /// Writes a private sibling stage, seals it, flushes and closes it, then
    /// atomically publishes on the same filesystem. Before that rename succeeds,
    /// every failure/cancellation preserves the old destination. No throwing work
    /// follows the commit. This is atomic visibility, not a power-loss durability
    /// guarantee for every filesystem/device. The populate closure must not seal.
    @discardableResult public static func write(
        to destination: URL, publication: SessionArchiveFilePublication = .create,
        header: SessionArchiveHeader, limits: SessionArchiveLimits,
        completion: SessionArchiveCompletion = .completed,
        shouldContinue: @escaping () -> Bool = { true },
        populate: (SessionArchiveWriter) throws -> Void
    ) throws -> SessionArchiveIOStatistics {
        var wasCancelled = false
        do {
            try check(shouldContinue)
            let directory = try SessionFileDirectory(destination.deletingLastPathComponent())
            let name = try SessionFileDirectory.filename(destination)
            let stage = try SessionPrivateStage(parent: directory, filename: "archive.part")
            let output = try stage.createOutput()
            defer { output.closeQuietly() }
            let writer = try SessionArchiveWriter(header: header, limits: limits) { bytes in
                guard shouldContinue() else {
                    wasCancelled = true
                    throw SessionArchiveError.cancelled
                }
                try output.write(bytes)
            }
            try populate(writer)
            try writer.finish(completion)
            try check(shouldContinue)
            try output.flushAndClose()
            try check(shouldContinue)
            try stage.publish(as: name, policy: publication)
            return writer.statistics
        } catch {
            throw wasCancelled
                ? SessionArchiveError.cancelled : safe(error, fallback: .outputFailure)
        }
    }

    /// Explicit host-controlled export of an exact verified archive copy, including
    /// any explicitly permitted embedded audio. The default refuses a header
    /// permitting audio; pass .explicitlyInclude only after the host/user chooses
    /// that policy. The check uses the same pinned input as the copy, so a separate
    /// inspection cannot race an audio-free sharing decision. No destination is
    /// published until the whole container
    /// passes. The host presents the audio policy and obtains the user's sharing
    /// choice; this method itself performs no network or system-share operation.
    @discardableResult public static func copyVerified(
        from source: URL, to destination: URL,
        publication: SessionArchiveFilePublication = .create,
        audioPolicy: SessionArchiveAudioPolicy = .omit,
        limits: SessionArchiveLimits, shouldContinue: @escaping () -> Bool = { true }
    ) throws -> SessionArchiveIOStatistics {
        var wasCancelled = false
        var outputFailed = false
        do {
            try check(shouldContinue)
            let input = try SessionFileInput(source, maximumBytes: limits.maximumArchiveBytes)
            defer { input.closeQuietly() }
            let directory = try SessionFileDirectory(destination.deletingLastPathComponent())
            let name = try SessionFileDirectory.filename(destination)
            let stage = try SessionPrivateStage(parent: directory, filename: "archive.part")
            let output = try stage.createOutput()
            defer { output.closeQuietly() }
            let reader = try SessionArchiveReader(limits: limits) { capacity in
                guard shouldContinue() else {
                    wasCancelled = true
                    throw SessionArchiveError.cancelled
                }
                let bytes = try input.read(capacity)
                do { try output.write(bytes) } catch {
                    outputFailed = true
                    throw error
                }
                return bytes
            }
            guard audioPolicy == .explicitlyInclude || reader.header.audioPolicy == .omit else {
                throw SessionArchiveError.audioNotOptedIn
            }
            while try reader.next() != nil {}
            try check(shouldContinue)
            try output.flushAndClose()
            try check(shouldContinue)
            try stage.publish(as: name, policy: publication)
            return reader.statistics
        } catch {
            if wasCancelled { throw SessionArchiveError.cancelled }
            if outputFailed { throw SessionArchiveError.outputFailure }
            throw safe(error, fallback: .inputFailure)
        }
    }

    /// Fully consumes the file with bounded reads. Events are provisional until
    /// the returned reader has a seal. Audio bytes are verified but never delivered
    /// or persisted by this API. Explicit prefix recovery is inspection-only.
    public static func inspect(
        at url: URL, limits: SessionArchiveLimits,
        recovery: SessionArchiveRecovery = .requireComplete,
        shouldContinue: () -> Bool = { true },
        visit: (SessionArchiveEvent) throws -> Void = { _ in }
    ) throws -> SessionArchiveReader {
        do {
            let input = try SessionFileInput(url, maximumBytes: limits.maximumArchiveBytes)
            defer { input.closeQuietly() }
            let reader = try SessionArchiveReader(limits: limits, recovery: recovery) {
                try input.read($0)
            }
            try check(shouldContinue)
            while let event = try reader.next() {
                try check(shouldContinue)
                try visit(event)
            }
            return reader
        } catch { throw safe(error, fallback: .inputFailure) }
    }

    /// The caller must explicitly supply an embedded reference and original file.
    /// The reader pins a regular file descriptor; the writer verifies its exact
    /// length/digest before it can seal. Mutations producing different bytes fail.
    @discardableResult public static func appendMediaFile(
        at url: URL, reference: SessionArchiveMediaReference, to writer: SessionArchiveWriter,
        shouldContinue: () -> Bool = { true }
    ) throws -> UInt32 {
        do {
            guard reference.inclusion == .embedded else {
                throw SessionArchiveError.audioNotOptedIn
            }
            try check(shouldContinue)
            let input = try SessionFileInput(
                url, maximumBytes: writer.limits.maximumEmbeddedMediaBytes)
            defer { input.closeQuietly() }
            guard input.byteCount == UInt64(reference.media.byteCount) else {
                throw SessionArchiveError.integrityMismatch
            }
            let index = try writer.addMediaReference(reference)
            var copied: UInt64 = 0
            while true {
                try check(shouldContinue)
                let bytes = try input.read(writer.maximumMediaChunkBytes)
                if bytes.isEmpty { break }
                try writer.appendMedia(bytes, to: index)
                copied += UInt64(bytes.count)
            }
            guard copied == input.byteCount else { throw SessionArchiveError.integrityMismatch }
            return index
        } catch { throw safe(error, fallback: .inputFailure) }
    }

    /// Explicitly extracts one embedded original into a private temporary file.
    /// The body runs only after the whole archive and media hashes pass. Partial
    /// or cancelled *sealed sessions* may be inspected/replayed; interrupted files
    /// cannot. The URL is valid only inside the body. Do not mutate, retain or
    /// share that temporary file; explicitly copy it if the user requests export.
    /// Normal return, failure and cancellation remove the private copy.
    public static func withVerifiedMedia<Result>(
        at archiveURL: URL, referenceIndex: UInt32, scratchDirectory: URL,
        limits: SessionArchiveLimits, shouldContinue: () -> Bool = { true },
        body: (SessionArchiveReader, URL) throws -> Result
    ) throws -> Result {
        do {
            try check(shouldContinue)
            let input = try SessionFileInput(archiveURL, maximumBytes: limits.maximumArchiveBytes)
            defer { input.closeQuietly() }
            let parent = try SessionFileDirectory(scratchDirectory)
            let stage = try SessionPrivateStage(parent: parent, filename: "media.audio")
            let output = try stage.createOutput()
            defer { output.closeQuietly() }
            let reader = try SessionArchiveReader(limits: limits, mediaAccess: .deliverBytes) {
                try input.read($0)
            }
            while let event = try reader.next() {
                try check(shouldContinue)
                if case .mediaChunk(let chunk) = event, chunk.referenceIndex == referenceIndex {
                    guard let bytes = chunk.bytes else { throw SessionArchiveError.invalidState }
                    try output.write(bytes)
                }
            }
            guard reader.seal != nil,
                Int(referenceIndex) < reader.statistics.mediaReferenceCount,
                try reader.mediaBytesAreVerified(at: referenceIndex)
            else { throw SessionArchiveError.missingMedia }
            try output.flushAndClose()
            try check(shouldContinue)
            return try withExtendedLifetime(stage) { try body(reader, stage.fileURL) }
        } catch { throw safe(error, fallback: .inputFailure) }
    }

    /// Explicit host-controlled deletion; absence is an error. No directory or
    /// symlink target is deleted. Hosts serialize deletion with export/sharing.
    public static func delete(at url: URL) throws {
        do {
            let parent = try SessionFileDirectory(url.deletingLastPathComponent())
            let name = try SessionFileDirectory.filename(url)
            guard try parent.isRegularFile(name), unlinkat(parent.descriptor, name, 0) == 0 else {
                throw SessionArchiveError.outputFailure
            }
        } catch { throw safe(error, fallback: .outputFailure) }
    }

    /// Crash cleanup is an explicit host decision after confirming no operation
    /// still owns this stage. Only an exactly named package stage and its two
    /// known regular-file names are accepted; never recursively removes contents.
    public static func removeAbandonedStage(at url: URL) throws {
        do {
            let name = try SessionFileDirectory.filename(url)
            guard name.hasPrefix(SessionPrivateStage.prefix),
                UUID(uuidString: String(name.dropFirst(SessionPrivateStage.prefix.count))) != nil
            else { throw SessionArchiveError.invalidConfiguration }
            let parent = try SessionFileDirectory(url.deletingLastPathComponent())
            let stage = try SessionFileDirectory(url)
            for file in ["archive.part", "media.audio"] {
                if try stage.isRegularFile(file) {
                    guard unlinkat(stage.descriptor, file, 0) == 0 else {
                        throw SessionArchiveError.outputFailure
                    }
                }
            }
            guard unlinkat(parent.descriptor, name, AT_REMOVEDIR) == 0 else {
                throw SessionArchiveError.outputFailure
            }
        } catch { throw safe(error, fallback: .outputFailure) }
    }

    private static func check(_ shouldContinue: () -> Bool) throws {
        guard shouldContinue() else { throw SessionArchiveError.cancelled }
    }
    private static func safe(_ error: any Error, fallback: SessionArchiveError)
        -> SessionArchiveError
    {
        (error as? SessionArchiveError) ?? fallback
    }
}

private final class SessionFileDirectory {
    let descriptor: Int32
    let url: URL

    init(_ url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw SessionArchiveError.invalidConfiguration
        }
        descriptor = url.withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw SessionArchiveError.outputFailure }
        self.url = url
    }
    init(parent: SessionFileDirectory, name: String) throws {
        descriptor = openat(
            parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SessionArchiveError.outputFailure }
        url = parent.url.appendingPathComponent(name, isDirectory: true)
    }
    deinit { Darwin.close(descriptor) }

    static func filename(_ url: URL) throws -> String {
        let value = url.lastPathComponent
        guard url.isFileURL, !url.path.utf8.contains(0), !value.isEmpty,
            value != ".", value != "..", !value.contains("/")
        else { throw SessionArchiveError.invalidConfiguration }
        return value
    }
    /// Returns false only for absence. Other file types fail without following links.
    func isRegularFile(_ name: String) throws -> Bool {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw SessionArchiveError.outputFailure }
            return false
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw SessionArchiveError.outputFailure }
        return true
    }
}

private final class SessionPrivateStage {
    static let prefix = ".hdxl-session-"
    let parent: SessionFileDirectory
    let directory: SessionFileDirectory
    let name: String
    let filename: String
    var fileURL: URL { directory.url.appendingPathComponent(filename) }

    init(parent: SessionFileDirectory, filename: String) throws {
        let name = Self.prefix + UUID().uuidString
        guard mkdirat(parent.descriptor, name, 0o700) == 0 else {
            throw SessionArchiveError.outputFailure
        }
        do {
            directory = try SessionFileDirectory(parent: parent, name: name)
        } catch {
            unlinkat(parent.descriptor, name, AT_REMOVEDIR)
            throw error
        }
        self.parent = parent
        self.name = name
        self.filename = filename
    }
    deinit {
        unlinkat(directory.descriptor, filename, 0)
        unlinkat(parent.descriptor, name, AT_REMOVEDIR)
    }
    func createOutput() throws -> SessionFileOutput {
        let descriptor = openat(
            directory.descriptor, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard descriptor >= 0 else { throw SessionArchiveError.outputFailure }
        return SessionFileOutput(descriptor)
    }
    func publish(as destination: String, policy: SessionArchiveFilePublication) throws {
        if policy == .replace { _ = try parent.isRegularFile(destination) }
        let result = renameatx_np(
            directory.descriptor, filename, parent.descriptor, destination,
            policy == .create ? UInt32(RENAME_EXCL) : 0)
        guard result == 0 else { throw SessionArchiveError.outputFailure }
    }
}

private final class SessionFileOutput {
    private var descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { closeQuietly() }
    func closeQuietly() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
    func write(_ bytes: Data) throws {
        guard descriptor >= 0 else { throw SessionArchiveError.outputFailure }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SessionArchiveError.outputFailure }
                offset += count
            }
        }
    }
    func flushAndClose() throws {
        guard descriptor >= 0 else { throw SessionArchiveError.outputFailure }
        var result: Int32
        repeat { result = fsync(descriptor) } while result != 0 && errno == EINTR
        guard result == 0 else { throw SessionArchiveError.outputFailure }
        let closing = descriptor
        descriptor = -1
        guard Darwin.close(closing) == 0 else { throw SessionArchiveError.outputFailure }
    }
}

private final class SessionFileInput {
    private var descriptor: Int32
    let byteCount: UInt64
    init(_ url: URL, maximumBytes: UInt64) throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw SessionArchiveError.invalidConfiguration
        }
        let opened = url.withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard opened >= 0 else { throw SessionArchiveError.inputFailure }
        var info = stat()
        guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            Darwin.close(opened)
            throw SessionArchiveError.inputFailure
        }
        guard UInt64(info.st_size) <= maximumBytes else {
            Darwin.close(opened)
            throw SessionArchiveError.sizeLimitExceeded
        }
        descriptor = opened
        byteCount = UInt64(info.st_size)
    }
    deinit { closeQuietly() }
    func closeQuietly() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
    func read(_ capacity: Int) throws -> Data {
        guard descriptor >= 0, (1...65_536).contains(capacity) else {
            throw SessionArchiveError.inputFailure
        }
        var bytes = Data(count: capacity)
        let count = bytes.withUnsafeMutableBytes { raw in
            var result: Int
            repeat {
                result = Darwin.read(descriptor, raw.baseAddress, capacity)
            } while result < 0 && errno == EINTR
            return result
        }
        guard count >= 0 else { throw SessionArchiveError.inputFailure }
        bytes.count = count
        return bytes
    }
}
