import CryptoKit
import Darwin
import Foundation
import HDXLVoiceProcessing

/// One transient private copy, explicitly requested by the file-analysis API.
/// Decoding never reopens the mutable original. Only this copy's verified bytes
/// are used, even if the original is edited/replaced during or after copying.
final class CalibrationMediaSnapshot {
    let url: URL
    let directory: URL
    let byteCount: Int64
    let maximumChunkBytes: Int

    init(
        take: CalibrationTake, original: URL, scratchDirectory: URL, limits: CalibrationFileLimits,
        shouldContinue: (CalibrationFileCheckpoint) -> Bool
    ) throws {
        guard original.isFileURL, scratchDirectory.isFileURL else {
            throw CalibrationFileFailure.unreadableMedia
        }
        let descriptor = original.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            throw errno == ENOENT ? CalibrationFileFailure.missingMedia : .unreadableMedia
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CalibrationFileFailure.unreadableMedia }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw CalibrationFileFailure.notRegularFile
        }
        guard info.st_size <= limits.maximumMediaBytes else {
            throw CalibrationFileFailure.mediaTooLarge
        }
        guard info.st_size == take.media.byteCount else {
            throw CalibrationFileFailure.audioLengthMismatch
        }
        directory = scratchDirectory.appendingPathComponent(
            "calibration-\(UUID())", isDirectory: true)
        // Generic extension avoids retaining a sensitive source filename. AVAudioFile
        // identifies supported containers from their headers, not this extension.
        url = directory.appendingPathComponent("media.audio", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            guard
                FileManager.default.createFile(
                    atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CalibrationFileFailure.snapshotFailed }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw CalibrationFileFailure.snapshotFailed
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            var hash = SHA256()
            var count: Int64 = 0
            var peak = 0
            while true {
                guard
                    shouldContinue(
                        CalibrationFileCheckpoint(
                            takeID: take.id, stage: .snapshot, copiedBytes: count,
                            nextSourceSample: take.source.startSample))
                else { throw CalibrationFileFailure.cancelled }
                let bytes: Data
                do {
                    bytes =
                        try input.read(upToCount: CalibrationFileLimits.snapshotChunkCapacity)
                        ?? Data()
                } catch { throw CalibrationFileFailure.unreadableMedia }
                if bytes.isEmpty { break }
                guard Int64(bytes.count) <= limits.maximumMediaBytes - count else {
                    throw CalibrationFileFailure.mediaTooLarge
                }
                guard Int64(bytes.count) <= take.media.byteCount - count else {
                    throw CalibrationFileFailure.audioLengthMismatch
                }
                count += Int64(bytes.count)
                peak = max(peak, bytes.count)
                hash.update(data: bytes)
                try output.write(contentsOf: bytes)
            }
            guard count == take.media.byteCount else {
                throw CalibrationFileFailure.audioLengthMismatch
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == take.media.content.sha256 else {
                throw CalibrationFileFailure.audioDigestMismatch
            }
            // Closing the writer before decoding also detects a reported close failure.
            try output.close()
            byteCount = count
            maximumChunkBytes = peak
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw (error as? CalibrationFileFailure) ?? .snapshotFailed
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
