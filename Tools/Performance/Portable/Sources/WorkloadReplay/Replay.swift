import CryptoKit
import Foundation
import HDXLVoiceProcessing

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct Manifest: Decodable {
    let schemaVersion: Int
    let algorithm: String
    let workloads: [Workload]
}

private struct Segment: Decodable {
    let startSample: Int
    let sampleCount: Int
}

private struct Workload: Decodable {
    let id: String
    let pcmSHA256: String
    let sampleCount: Int
    let sampleRate: Int
    let channelLayout: String
    let encoding: String
    let segments: [Segment]
    let profile: YINConfiguration
    let profileSHA256: String
    let windowSamples: Int
    let availabilityPolicy: String
    let expected: FrameCounts
}

public struct FrameCounts: Codable, Equatable, Sendable {
    public private(set) var processed = 0
    public private(set) var available = 0
    public private(set) var unavailable = 0
    public private(set) var byStatus = [
        "voiced": 0, "uncertain": 0, "unvoiced": 0, "unavailable": 0,
    ]

    fileprivate mutating func observe(_ output: BorrowedYINAnalysisOutput) {
        processed += 1
        if output.raw.result.observation != nil {
            available += 1
        } else {
            unavailable += 1
        }
        byStatus[output.raw.result.status.rawValue, default: 0] += 1
    }
}

public struct WorkloadResult: Encodable, Sendable {
    public let id: String
    public let pcmSHA256: String
    public let profileSHA256: String
    public let counts: FrameCounts
}

public struct ReplayReport: Encodable, Sendable {
    public let manifestSHA256: String
    public let maximumChunkSamples: Int
    public let workloads: [WorkloadResult]
}

public enum WorkloadError: Error {
    case invalidManifest
    case invalidWorkload(String)
    case coverageMismatch(String)
}

private func run<T: BinaryFloatingPoint & Sendable>(
    _ row: Workload, _ pcm: [T], chunkSize: Int
) throws -> FrameCounts {
    var counts = FrameCounts()
    var previousEnd = 0
    for segment in row.segments {
        guard segment.startSample >= previousEnd, segment.startSample <= pcm.count,
            segment.sampleCount > 0, segment.sampleCount <= pcm.count - segment.startSample
        else { throw WorkloadError.invalidWorkload(row.id) }
        let end = segment.startSample + segment.sampleCount
        let epoch = StreamEpoch(streamID: UUID())
        let worker = try PreparedYINAnalyzer<T>(
            profile: YINProfile(estimator: row.profile), epoch: epoch,
            startSample: Int64(segment.startSample))
        try pcm.withUnsafeBufferPointer { buffer in
            var start = segment.startSample
            while start < end {
                let n = min(chunkSize, end - start)
                try worker.process(
                    UnsafeBufferPointer(rebasing: buffer[start..<(start + n)]),
                    interval: SourceInterval(
                        epoch: epoch, startSample: Int64(start), sampleCount: Int64(n),
                        sampleRate: Double(row.sampleRate))
                ) { counts.observe($0) }
                start += n
            }
        }
        try worker.finish { counts.observe($0) }
        previousEnd = end
    }
    return counts
}

private func samples<T: BinaryFloatingPoint>(_ type: T.Type, from data: Data) -> [T] {
    var values = [T](repeating: 0, count: data.count / MemoryLayout<T>.stride)
    _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    return values
}

/// Verify the same file bundle on a Mac, Simulator, or device. The returned counts
/// characterize estimator eligibility. This preflight includes I/O and never measures time.
public func replayWorkloads(at directory: URL, maximumChunkSamples: Int) throws -> ReplayReport {
    let bytes = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
    guard manifest.schemaVersion == 1, manifest.algorithm == "rawYIN",
        maximumChunkSamples > 0, !manifest.workloads.isEmpty,
        Set(manifest.workloads.map(\.id)).count == manifest.workloads.count
    else { throw WorkloadError.invalidManifest }
    let results = try manifest.workloads.map { row in
        let width = row.profile.inputPrecision == .float32 ? 4 : 8
        guard row.pcmSHA256.utf8.count == 64,
            row.pcmSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            row.sampleCount > 0, !row.segments.isEmpty, row.channelLayout == "mono",
            row.encoding == row.profile.inputPrecision.rawValue + "LE",
            row.sampleRate == row.profile.sampleRate,
            row.windowSamples == row.profile.requiredSampleCount,
            row.availabilityPolicy == "voicedOrUncertain",
            try row.profile.identity().sha256 == row.profileSHA256
        else { throw WorkloadError.invalidWorkload(row.id) }
        let pcm = try Data(contentsOf: directory.appendingPathComponent(row.pcmSHA256 + ".pcm"))
        guard pcm.count.isMultiple(of: width), pcm.count / width == row.sampleCount,
            digest(pcm) == row.pcmSHA256
        else { throw WorkloadError.invalidWorkload(row.id) }
        let counts =
            try width == 4
            ? run(row, samples(Float.self, from: pcm), chunkSize: maximumChunkSamples)
            : run(row, samples(Double.self, from: pcm), chunkSize: maximumChunkSamples)
        guard counts == row.expected else { throw WorkloadError.coverageMismatch(row.id) }
        return WorkloadResult(
            id: row.id, pcmSHA256: row.pcmSHA256, profileSHA256: row.profileSHA256, counts: counts)
    }
    return ReplayReport(
        manifestSHA256: digest(bytes), maximumChunkSamples: maximumChunkSamples, workloads: results)
}
