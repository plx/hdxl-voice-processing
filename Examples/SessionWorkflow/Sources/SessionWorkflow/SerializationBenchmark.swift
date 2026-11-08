import Darwin
import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

/// macOS-only evidence command. Inputs are constructed scalar contracts, not
/// measurements computed by DSP. Each invocation handles one phase/length in a
/// fresh process; it never retains the timeline. Disk IO and record construction
/// (write) or meaning checks (read) are included in the measured worker duration.
enum SerializationBenchmark {
    struct Report: Encodable {
        let schemaVersion = 1
        let status = "passed"
        let syntheticOnly = true
        let dspOrCaptureExecuted = false
        let phase: String
        let frames: Int
        let sourceDurationSeconds: Double
        let seconds: Double
        let peakResidentBytes: Int64
        let archiveBytes: UInt64
        let framedRecords: UInt64
        let measurementRecords: UInt64
        let catalogEntries: Int
        let encodedCatalogBytes: Int
        let maximumRecordPayloadBytes: Int
        let maximumIOChunkBytes: Int
        let embeddedMediaBytes: UInt64
        let available: Int
        let unavailable: Int
        let lastTimestamp: Int64
        let profileSHA256: String
    }

    static func command(_ args: [String]) throws -> Bool {
        guard let command = args.first,
            ["--serialization-write", "--serialization-read"].contains(command)
        else { return false }
        guard args.count == 7, args[1] == "--frames", args[3] == "--archive", args[5] == "--output",
            let frames = Int(args[2]), (1...2_160_000).contains(frames)
        else { throw SessionArchiveError.invalidConfiguration }
        let archive = URL(fileURLWithPath: args[4])
        let recipe = try Fixture()
        let phase = command == "--serialization-write" ? "write" : "read"
        let clock = ContinuousClock()
        let begin = clock.now
        let statistics: SessionArchiveIOStatistics
        if phase == "write" {
            statistics = try recipe.write(frames: frames, at: archive)
        } else {
            statistics = try recipe.read(frames: frames, at: archive)
        }
        let duration = begin.duration(to: clock.now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0, usage.ru_maxrss > 0 else {
            throw SessionArchiveError.invalidState
        }
        let unavailable = (frames + 256) / 257
        let report = Report(
            phase: phase, frames: frames, sourceDurationSeconds: Double(frames) / 100,
            seconds: seconds, peakResidentBytes: Int64(usage.ru_maxrss),
            archiveBytes: statistics.bytesProcessed, framedRecords: statistics.framedRecords,
            measurementRecords: statistics.measurementRecords,
            catalogEntries: statistics.catalogEntries,
            encodedCatalogBytes: statistics.encodedCatalogBytes,
            maximumRecordPayloadBytes: statistics.maximumRecordPayloadBytes,
            maximumIOChunkBytes: statistics.maximumIOChunkBytes,
            embeddedMediaBytes: statistics.embeddedMediaBytes,
            available: frames - unavailable, unavailable: unavailable,
            lastTimestamp: Fixture.start + Int64(frames - 1) * 160 + 200,
            profileSHA256: recipe.identity.sha256)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(report).write(
            to: URL(fileURLWithPath: args[6]), options: .withoutOverwriting)
        print("Synthetic serialization \(phase) completed: \(frames) records.")
        return true
    }

    private struct Fixture {
        static let start: Int64 = (1 << 54) + 53
        let configuration: LevelConfiguration
        let identity: ProfileIdentity
        let measurement: MeasurementDescriptor
        let epoch: StreamEpoch
        let source: SessionArchiveSource
        let header: SessionArchiveHeader
        let limits: SessionArchiveLimits
        let available: MeasurementOutcome

        init() throws {
            configuration = try LevelConfiguration(
                sampleRate: 16_000, inputPrecision: .float64, windowLength: 400, hopLength: 160,
                accumulation: .compensatedSliding, weighting: .none)
            identity = try configuration.identity()
            measurement = try MeasurementDescriptor(
                kind: .rms, unit: .normalizedAmplitude, algorithm: identity.identifier)
            epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000005801")!)
            source = try SessionArchiveSource(
                origin: AnalysisScheduleOrigin(
                    source: SourceInterval(
                        epoch: epoch, startSample: Self.start, sampleCount: 0, sampleRate: 16_000),
                    continuityEpoch: StreamEpoch(
                        streamID: UUID(uuidString: "00000000-0000-0000-0000-000000005802")!)),
                acquisition: SessionAcquisitionMetadata(
                    conditions: CalibrationRecordingConditions()))
            header = try SessionArchiveHeader(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000005803")!,
                producer: VersionedIdentifier(
                    name: "synthetic-serialization-benchmark", version: 1),
                notes: "Constructed scalar contracts only; no DSP, capture or personal data.")
            limits = try SessionArchiveLimits(
                maximumArchiveBytes: 1024 * 1024 * 1024, maximumRecordBytes: 4096,
                maximumCatalogBytes: 65_536, maximumCatalogEntries: 8,
                maximumRecords: 2_160_010, maximumEmbeddedMediaBytes: 0,
                maximumIntermediateScalars: 0, ioChunkCapacity: 4096)
            available = .available(try ScalarEstimate(value: 0.25, confidence: 0.75))
        }

        func record(_ index: Int) throws -> SessionArchiveMeasurement {
            let start = Self.start + Int64(index) * 160
            let interval = try SourceInterval(
                epoch: epoch, startSample: start, sampleCount: 400, sampleRate: 16_000)
            return try SessionArchiveMeasurement(
                timestamp: SessionArchiveTimestamp(sourceSample: start + 200),
                result: MeasurementResult(
                    measurement: measurement, profile: identity,
                    timing: AnalysisTiming(
                        source: interval, includedSampleCount: 400,
                        sourceStartSeconds: Double(index) / 100,
                        hostStartNanoseconds: UInt64(index) * 10_000_000,
                        completedHostNanoseconds: UInt64(index) * 10_000_000 + 25_000_000),
                    outcome: index % 257 == 0 ? .unavailable(.lowConfidence) : available))
        }

        func write(frames: Int, at url: URL) throws -> SessionArchiveIOStatistics {
            try SessionArchiveFiles.write(to: url, header: header, limits: limits) { writer in
                try writer.addProfile(.levels(configuration))
                try writer.addSource(source)
                let series = try writer.addSeries(
                    SessionArchiveSeries(
                        profileIndex: 0, sourceIndex: 0, measurement: measurement,
                        clock: .sourceSamples))
                for index in 0..<frames { try writer.append(record(index), to: series) }
            }
        }

        func read(frames: Int, at url: URL) throws -> SessionArchiveIOStatistics {
            var count = 0
            let reader = try SessionArchiveFiles.inspect(
                at: url, limits: limits,
                visit: { event in
                    if case .measurement(let index, let value) = event {
                        guard count < frames, index == 0, value == (try record(count)) else {
                            throw SessionArchiveError.integrityMismatch
                        }
                        count += 1
                    }
                })
            guard reader.header == header, count == frames, reader.seal?.completion == .completed,
                reader.statistics.catalogEntries == 4, reader.statistics.gapRecords == 0,
                reader.statistics.mediaReferenceCount == 0,
                try reader.profile(at: 0) == .levels(configuration),
                try reader.source(at: 0) == source
            else { throw SessionArchiveError.integrityMismatch }
            return reader.statistics
        }
    }
}
