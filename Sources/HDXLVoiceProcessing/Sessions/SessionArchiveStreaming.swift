import Foundation

/// IO and format bounds, not a claim about process resident memory. Encoded
/// catalog bytes bound retained metadata input; decoded objects, hashing,
/// Foundation and allocator overhead are additional. No timeline history is kept.
public struct SessionArchiveIOStatistics: Sendable, Hashable {
    public let bytesProcessed: UInt64
    public let framedRecords: UInt64
    public let measurementRecords: UInt64
    public let gapRecords: UInt64
    public let catalogEntries: Int
    public let encodedCatalogBytes: Int
    public let maximumRecordPayloadBytes: Int
    public let maximumIOChunkBytes: Int
    public let mediaReferenceCount: Int
    public let embeddedMediaBytes: UInt64
}

/// Records are yielded synchronously and individually. Only a verified seal
/// followed by EOF establishes complete-container integrity. Earlier records may
/// be inspected provisionally; no event activates a personal target.
public enum SessionArchiveEvent: Sendable, Hashable {
    case profile(index: UInt32, SessionArchiveProfile)
    case source(index: UInt32, SessionArchiveSource)
    case series(index: UInt32, SessionArchiveSeries)
    case measurement(seriesIndex: UInt32, SessionArchiveMeasurement)
    case gap(SessionArchiveGap)
    case calibrationDataset(index: UInt32, CalibrationDataset)
    case calibrationSplit(index: UInt32, SessionArchiveCalibrationSplit)
    case calibrationAnalysis(index: UInt32, SessionArchiveCalibrationAnalysis)
    case target(index: UInt32, SessionArchiveTarget)
    case mediaReference(index: UInt32, SessionArchiveMediaReference)
    case mediaChunk(SessionArchiveMediaChunk)
    case replayPlan(index: UInt32, SessionArchiveReplayPlan)
    case seal(SessionArchiveSeal)
    case incomplete
}

/// Single-owner, synchronous worker/control-path export. This object allocates
/// and performs IO through the supplied sink; never use it in a capture callback.
/// The host owns sink lifetime, storage, cancellation and any user-controlled sharing.
/// A sink failure is terminal; validation errors before writing are recoverable.
/// Do not reenter an operation from the sink or call from multiple tasks.
public final class SessionArchiveWriter {
    public let header: SessionArchiveHeader
    public let limits: SessionArchiveLimits
    public private(set) var seal: SessionArchiveSeal?
    private let wire: SessionArchiveWireWriter
    private var catalog: SessionArchiveCatalog
    private var calibration = SessionArchiveCalibrationState()
    private var media = SessionArchiveMediaState()
    private var replay = SessionArchiveReplayState()
    private var measurementCount: UInt64 = 0
    private var gapCount: UInt64 = 0
    private var failed = false
    private var busy = false

    public init(
        header: SessionArchiveHeader, limits: SessionArchiveLimits,
        sink: @escaping (Data) throws -> Void
    ) throws {
        let bytes = try canonicalContractJSON(header)
        var catalog = SessionArchiveCatalog(limits: limits)
        try catalog.reserveMetadata(payloadBytes: bytes.count)
        self.header = header
        self.limits = limits
        self.catalog = catalog
        wire = try SessionArchiveWireWriter(limits: limits, sink: sink)
        try wire.append(.header, payload: bytes)
    }

    public var statistics: SessionArchiveIOStatistics {
        SessionArchiveIOStatistics(
            bytesProcessed: wire.byteCount, framedRecords: wire.recordCount,
            measurementRecords: measurementCount, gapRecords: gapCount,
            catalogEntries: catalog.entryCount,
            encodedCatalogBytes: catalog.retainedMetadataBytes,
            maximumRecordPayloadBytes: wire.maximumBufferedRecordBytes,
            maximumIOChunkBytes: wire.maximumWriteChunkBytes,
            mediaReferenceCount: media.references.count,
            embeddedMediaBytes: media.acceptedEmbeddedBytes)
    }

    @discardableResult public func addProfile(_ profile: SessionArchiveProfile) throws -> UInt32 {
        try operation {
            let bytes = try canonicalContractJSON(profile)
            var next = catalog
            let index = try next.add(profile, payloadBytes: bytes.count)
            try wire.append(.profile, payload: bytes)
            catalog = next
            return index
        }
    }

    @discardableResult public func addSource(_ source: SessionArchiveSource) throws -> UInt32 {
        try operation {
            let bytes = try canonicalContractJSON(source)
            var next = catalog
            let index = try next.add(source, payloadBytes: bytes.count)
            try wire.append(.source, payload: bytes)
            catalog = next
            return index
        }
    }

    @discardableResult public func addSeries(_ series: SessionArchiveSeries) throws -> UInt32 {
        try operation {
            let bytes = try canonicalContractJSON(series)
            var next = catalog
            let index = try next.add(series, payloadBytes: bytes.count)
            try wire.append(.series, payload: bytes)
            catalog = next
            return index
        }
    }

    public func append(_ measurement: SessionArchiveMeasurement, to seriesIndex: UInt32) throws {
        try operation { try appendMeasurement(measurement, to: seriesIndex) }
    }

    /// Validates the complete scheduler export against catalog origin and mask
    /// before factoring that metadata out of the scalar record.
    public func append(_ export: ScheduledMeasurementExport, to seriesIndex: UInt32) throws {
        try operation {
            let (series, _, source) = try catalog.context(for: seriesIndex)
            try appendMeasurement(
                SessionArchiveMeasurement(export, source: source, series: series), to: seriesIndex)
        }
    }

    public func append(_ gap: SessionArchiveGap) throws {
        try operation {
            try catalog.validate(gap)
            let bytes = try canonicalContractJSON(gap)
            try wire.append(.gap, payload: bytes)
            catalog.accepted(gap)
            gapCount += 1
        }
    }

    @discardableResult public func addCalibrationDataset(_ dataset: CalibrationDataset) throws
        -> UInt32
    {
        try addCalibration(
            .calibrationDataset, value: dataset,
            maximumBytes: CalibrationRecordLimits.maximumDatasetBytes
        ) {
            try $0.add(dataset, payloadBytes: $1)
        }
    }
    @discardableResult public func addCalibrationSplit(_ split: SessionArchiveCalibrationSplit)
        throws -> UInt32
    {
        try addCalibration(.calibrationSplit, value: split, maximumBytes: 1024 * 1024) { state, _ in
            try state.add(split)
        }
    }
    @discardableResult public func addCalibrationAnalysis(
        _ analysis: SessionArchiveCalibrationAnalysis
    ) throws -> UInt32 {
        try addCalibration(
            .calibrationAnalysis, value: analysis,
            maximumBytes: CalibrationAnalysisRecord.maximumEncodedBytes + 1024
        ) {
            state, _ in try state.add(analysis)
        }
    }
    @discardableResult public func addTarget(_ target: SessionArchiveTarget) throws -> UInt32 {
        try addCalibration(
            .target, value: target, maximumBytes: SessionArchiveTarget.maximumEncodedBytes
        ) {
            state, _ in try state.add(target)
        }
    }

    public var maximumMediaChunkBytes: Int { min(65_536, limits.maximumRecordBytes - 12) }

    @discardableResult public func addMediaReference(_ reference: SessionArchiveMediaReference)
        throws -> UInt32
    {
        try operation {
            let bytes = try canonicalContractJSON(reference)
            var nextCatalog = catalog
            try nextCatalog.reserveMetadata(payloadBytes: bytes.count)
            var nextMedia = media
            let index = try nextMedia.add(reference, header: header, catalog: nextCatalog)
            try wire.append(.mediaReference, payload: bytes)
            catalog = nextCatalog
            media = nextMedia
            return index
        }
    }

    /// Original bytes only, in contiguous offset order for this reference. The
    /// final chunk must complete the declared digest before it can be written.
    /// A bad final chunk is rejected before output and can be retried correctly.
    public func appendMedia(_ bytes: Data, to referenceIndex: UInt32) throws {
        try operation {
            let offset = try media.currentProgress(at: referenceIndex).byteCount
            let next = try media.prepareChunk(
                index: referenceIndex, offset: offset, bytes: bytes, limits: limits)
            var encoder = SessionArchiveBinaryEncoder(limit: limits.maximumRecordBytes)
            try encoder.integer(referenceIndex)
            try encoder.integer(offset)
            try encoder.bytes(bytes)
            try wire.append(.mediaChunk, payload: encoder.data)
            media.acceptChunk(index: referenceIndex, progress: next)
        }
    }

    @discardableResult public func addReplayPlan(_ plan: SessionArchiveReplayPlan) throws -> UInt32
    {
        try operation {
            let bytes = try canonicalContractJSON(plan)
            var nextCatalog = catalog
            try nextCatalog.reserveMetadata(payloadBytes: bytes.count)
            var nextReplay = replay
            let index = try nextReplay.add(plan, catalog: nextCatalog, media: media)
            try wire.append(.replayPlan, payload: bytes)
            catalog = nextCatalog
            replay = nextReplay
            return index
        }
    }

    private func addCalibration<Value: Encodable>(
        _ kind: SessionArchiveRecordKind, value: Value, maximumBytes: Int,
        register: (inout SessionArchiveCalibrationState, Int) throws -> UInt32
    ) throws -> UInt32 {
        try operation {
            let bytes = try canonicalContractJSON(value)
            guard bytes.count <= maximumBytes else { throw SessionArchiveError.sizeLimitExceeded }
            var nextCatalog = catalog
            try nextCatalog.reserveMetadata(payloadBytes: bytes.count)
            var nextCalibration = calibration
            let index = try register(&nextCalibration, bytes.count)
            try wire.append(kind, payload: bytes)
            catalog = nextCatalog
            calibration = nextCalibration
            return index
        }
    }

    /// Seals the records already exported. `.partial` and `.cancelled` describe a
    /// completed container with an explicitly unfinished acquisition; interruption
    /// before this method succeeds is instead an unsealed file.
    @discardableResult public func finish(_ completion: SessionArchiveCompletion = .completed)
        throws -> SessionArchiveSeal
    {
        try operation {
            try media.validateComplete()
            let value = try SessionArchiveSeal(
                completion: completion, precedingRecordCount: wire.recordCount,
                precedingByteCount: wire.byteCount,
                precedingSHA256: CalibrationDigest(sha256: wire.prefixSHA256),
                measurementCount: measurementCount, gapCount: gapCount,
                catalogEntryCount: catalog.entryCount,
                mediaReferenceCount: UInt64(media.references.count),
                embeddedMediaBytes: media.acceptedEmbeddedBytes)
            try wire.append(.footer, payload: canonicalContractJSON(value))
            seal = value
            return value
        }
    }

    private func appendMeasurement(_ measurement: SessionArchiveMeasurement, to index: UInt32)
        throws
    {
        let bytes = try SessionArchiveScalarWire.encode(
            measurement, seriesIndex: index, catalog: catalog)
        try wire.append(.measurement, payload: bytes)
        catalog.accepted(measurement, seriesIndex: index)
        measurementCount += 1
    }

    private func operation<Value>(_ body: () throws -> Value) throws -> Value {
        guard !failed, !busy, seal == nil else { throw SessionArchiveError.invalidState }
        busy = true
        defer { busy = false }
        do { return try body() } catch {
            let code = sessionArchiveError(error, fallback: .invalidMetadata)
            if code == .outputFailure { failed = true }
            throw code
        }
    }
}

/// Single-owner finite-input reader. Each request is at most ioChunkCapacity;
/// input must return no more than requested, and empty Data means final EOF.
/// A growing file or network stream needs a host adapter that distinguishes
/// temporary starvation from final EOF. Reads allocate and belong on a worker.
public final class SessionArchiveReader {
    public let header: SessionArchiveHeader
    public let limits: SessionArchiveLimits
    public let recovery: SessionArchiveRecovery
    public let mediaAccess: SessionArchiveMediaAccess
    public private(set) var seal: SessionArchiveSeal?
    public private(set) var isIncomplete = false
    private let wire: SessionArchiveWireReader
    private var catalog: SessionArchiveCatalog
    private var calibration = SessionArchiveCalibrationState()
    private var media = SessionArchiveMediaState()
    private var replay = SessionArchiveReplayState()
    private var measurementCount: UInt64 = 0
    private var gapCount: UInt64 = 0
    private var failed = false
    private var busy = false

    public init(
        limits: SessionArchiveLimits, recovery: SessionArchiveRecovery = .requireComplete,
        mediaAccess: SessionArchiveMediaAccess = .verifyOnly,
        input: @escaping (Int) throws -> Data
    ) throws {
        self.limits = limits
        self.recovery = recovery
        self.mediaAccess = mediaAccess
        wire = try SessionArchiveWireReader(limits: limits, input: input)
        guard let record = try wire.next() else { throw SessionArchiveError.truncated }
        guard record.kind == .header else { throw SessionArchiveError.outOfOrder }
        header = try decodeSessionMetadata(SessionArchiveHeader.self, from: record.payload)
        catalog = SessionArchiveCatalog(limits: limits)
        try catalog.reserveMetadata(payloadBytes: record.payload.count)
    }

    public var statistics: SessionArchiveIOStatistics {
        SessionArchiveIOStatistics(
            bytesProcessed: wire.byteCount, framedRecords: wire.recordCount,
            measurementRecords: measurementCount, gapRecords: gapCount,
            catalogEntries: catalog.entryCount,
            encodedCatalogBytes: catalog.retainedMetadataBytes,
            maximumRecordPayloadBytes: wire.maximumBufferedRecordBytes,
            maximumIOChunkBytes: wire.maximumReadChunkBytes,
            mediaReferenceCount: media.references.count,
            embeddedMediaBytes: media.acceptedEmbeddedBytes)
    }

    public func profile(at index: UInt32) throws -> SessionArchiveProfile {
        guard Int(index) < catalog.profiles.count else { throw SessionArchiveError.invalidMetadata }
        return catalog.profiles[Int(index)].recipe
    }
    public func source(at index: UInt32) throws -> SessionArchiveSource {
        guard Int(index) < catalog.sources.count else { throw SessionArchiveError.invalidMetadata }
        return catalog.sources[Int(index)]
    }
    public func series(at index: UInt32) throws -> SessionArchiveSeries {
        guard Int(index) < catalog.series.count else { throw SessionArchiveError.invalidMetadata }
        return catalog.series[Int(index)]
    }

    public func calibrationDataset(at index: UInt32) throws -> CalibrationDataset {
        try calibration.dataset(at: index)
    }
    public func calibrationSplit(at index: UInt32) throws -> SessionArchiveCalibrationSplit {
        guard Int(index) < calibration.splits.count else {
            throw SessionArchiveError.invalidMetadata
        }
        return calibration.splits[Int(index)]
    }
    public func calibrationAnalysis(at index: UInt32) throws -> SessionArchiveCalibrationAnalysis {
        guard Int(index) < calibration.analyses.count else {
            throw SessionArchiveError.invalidMetadata
        }
        return calibration.analyses[Int(index)]
    }
    public func target(at index: UInt32) throws -> SessionArchiveTarget {
        guard Int(index) < calibration.targets.count else {
            throw SessionArchiveError.invalidMetadata
        }
        return calibration.targets[Int(index)]
    }

    public func mediaReference(at index: UInt32) throws -> SessionArchiveMediaReference {
        try media.reference(at: index)
    }
    /// Nil means no separately declared archive reference, including audio-free
    /// calibration datasets that retain their original opaque media references.
    public func mediaReferenceIndex(matching reference: CalibrationMediaReference) -> UInt32? {
        media.index(matching: reference)
    }
    /// Byte integrity alone is provisional until the complete archive seal passes.
    public func mediaBytesAreVerified(at index: UInt32) throws -> Bool {
        try media.currentProgress(at: index).isVerified
    }

    public func replayPlan(at index: UInt32) throws -> SessionArchiveReplayPlan {
        try replay.plan(at: index)
    }
    /// Nil means the archive has no complete replay recipe for this series.
    public func replayPlanIndex(for seriesIndex: UInt32) -> UInt32? {
        replay.index(for: seriesIndex)
    }

    /// Explicit host decision after fully reading a completed container. Obtain
    /// verifiedEvaluation by fitting/evaluating freshly verified inputs and
    /// reference artifacts under the current profile. Imported summaries or
    /// validation claims alone cannot establish that verification. This returns
    /// only the already activated model from that separate evaluation; it never
    /// creates an activated model from serialized fields.
    public func activateTarget(
        at index: UInt32, currentProfile: AnalysisScheduleProfile,
        verifiedEvaluation: PersonalTargetEvaluation
    ) throws -> ActivatedPersonalTarget {
        guard !failed, !busy, !isIncomplete, seal?.completion == .completed else {
            throw SessionArchiveError.activationRefused
        }
        let imported = try target(at: index)
        guard try imported.compatibility(with: currentProfile) == .requiresVerifiedEvaluation,
            verifiedEvaluation.reasons.isEmpty, let model = verifiedEvaluation.activated,
            model.candidate == imported.candidate,
            model.evaluationIdentity == verifiedEvaluation.evaluationIdentity,
            imported.claimedEvaluationIdentity == nil
                || imported.claimedEvaluationIdentity == model.evaluationIdentity
        else { throw SessionArchiveError.activationRefused }
        return model
    }

    public func next() throws -> SessionArchiveEvent? {
        guard !failed, !busy else { throw SessionArchiveError.invalidState }
        if seal != nil || isIncomplete { return nil }
        busy = true
        defer { busy = false }
        do {
            guard let record = try wire.next() else { throw SessionArchiveError.truncated }
            switch record.kind {
            case .header: throw SessionArchiveError.outOfOrder
            case .profile:
                try catalog.checkBudget(payloadBytes: record.payload.count)
                let value = try decodeSessionMetadata(
                    SessionArchiveProfile.self, from: record.payload)
                let index = try catalog.add(value, payloadBytes: record.payload.count)
                return .profile(index: index, value)
            case .source:
                try catalog.checkBudget(payloadBytes: record.payload.count)
                let value = try decodeSessionMetadata(
                    SessionArchiveSource.self, from: record.payload)
                let index = try catalog.add(value, payloadBytes: record.payload.count)
                return .source(index: index, value)
            case .series:
                try catalog.checkBudget(payloadBytes: record.payload.count)
                let value = try decodeSessionMetadata(
                    SessionArchiveSeries.self, from: record.payload)
                let index = try catalog.add(value, payloadBytes: record.payload.count)
                return .series(index: index, value)
            case .measurement:
                let (index, value) = try SessionArchiveScalarWire.decode(
                    record.payload, catalog: catalog)
                catalog.accepted(value, seriesIndex: index)
                measurementCount += 1
                return .measurement(seriesIndex: index, value)
            case .gap:
                let value = try decodeSessionMetadata(SessionArchiveGap.self, from: record.payload)
                try catalog.validate(value)
                catalog.accepted(value)
                gapCount += 1
                return .gap(value)
            case .footer:
                let value = try decodeSessionMetadata(SessionArchiveSeal.self, from: record.payload)
                let precedingBytes =
                    wire.byteCount - UInt64(SessionArchiveWire.headerBytes + record.payload.count)
                guard value.precedingRecordCount == record.ordinal,
                    value.precedingByteCount == precedingBytes,
                    value.precedingSHA256.sha256 == record.precedingSHA256,
                    value.measurementCount == measurementCount, value.gapCount == gapCount,
                    value.catalogEntryCount == catalog.entryCount,
                    value.mediaReferenceCount == UInt64(media.references.count),
                    value.embeddedMediaBytes == media.acceptedEmbeddedBytes
                else { throw SessionArchiveError.integrityMismatch }
                try media.validateComplete()
                do {
                    guard try wire.next() == nil else { throw SessionArchiveError.outOfOrder }
                } catch SessionArchiveError.truncated {
                    // A valid seal followed by any partial record is trailing
                    // garbage, not an interrupted unsealed session prefix.
                    throw SessionArchiveError.malformedRecord
                }
                seal = value
                return .seal(value)
            case .calibrationDataset:
                try checkCalibrationRecord(
                    record, maximumBytes: CalibrationRecordLimits.maximumDatasetBytes)
                let value = try decodeSessionMetadata(CalibrationDataset.self, from: record.payload)
                let index = try calibration.add(value, payloadBytes: record.payload.count)
                try catalog.reserveMetadata(payloadBytes: record.payload.count)
                return .calibrationDataset(index: index, value)
            case .calibrationSplit:
                try checkCalibrationRecord(record, maximumBytes: 1024 * 1024)
                let value = try decodeSessionMetadata(
                    SessionArchiveCalibrationSplit.self, from: record.payload)
                let index = try calibration.add(value)
                try catalog.reserveMetadata(payloadBytes: record.payload.count)
                return .calibrationSplit(index: index, value)
            case .calibrationAnalysis:
                try checkCalibrationRecord(
                    record, maximumBytes: CalibrationAnalysisRecord.maximumEncodedBytes + 1024)
                let value = try decodeSessionMetadata(
                    SessionArchiveCalibrationAnalysis.self, from: record.payload)
                let index = try calibration.add(value)
                try catalog.reserveMetadata(payloadBytes: record.payload.count)
                return .calibrationAnalysis(index: index, value)
            case .target:
                try checkCalibrationRecord(
                    record, maximumBytes: SessionArchiveTarget.maximumEncodedBytes)
                let value = try decodeSessionMetadata(
                    SessionArchiveTarget.self, from: record.payload)
                let index = try calibration.add(value)
                try catalog.reserveMetadata(payloadBytes: record.payload.count)
                return .target(index: index, value)
            case .replayPlan:
                try catalog.checkBudget(payloadBytes: record.payload.count)
                let value = try decodeSessionMetadata(
                    SessionArchiveReplayPlan.self, from: record.payload)
                let index = try replay.add(value, catalog: catalog, media: media)
                try catalog.reserveMetadata(payloadBytes: record.payload.count)
                return .replayPlan(index: index, value)
            case .mediaReference:
                try catalog.checkBudget(payloadBytes: record.payload.count)
                let value = try decodeSessionMetadata(
                    SessionArchiveMediaReference.self, from: record.payload)
                let index = try media.add(value, header: header, catalog: catalog)
                try catalog.reserveMetadata(payloadBytes: record.payload.count)
                return .mediaReference(index: index, value)
            case .mediaChunk:
                guard record.payload.count >= 13,
                    record.payload.count <= 12 + min(65_536, limits.maximumRecordBytes - 12)
                else {
                    throw SessionArchiveError.sizeLimitExceeded
                }
                var decoder = SessionArchiveBinaryDecoder(data: record.payload)
                let index = try decoder.unsigned(UInt32.self)
                let offset = try decoder.unsigned(UInt64.self)
                let bytes = Data(record.payload.dropFirst(12))
                let next = try media.prepareChunk(
                    index: index, offset: offset, bytes: bytes, limits: limits)
                media.acceptChunk(index: index, progress: next)
                return .mediaChunk(
                    SessionArchiveMediaChunk(
                        referenceIndex: index, offset: offset,
                        byteCount: bytes.count, bytes: mediaAccess == .deliverBytes ? bytes : nil))
            }
        } catch {
            let code = sessionArchiveError(error, fallback: .malformedRecord)
            if code == .truncated, recovery == .inspectCompletePrefix {
                isIncomplete = true
                return .incomplete
            }
            failed = true
            throw code
        }
    }

    private func checkCalibrationRecord(_ record: SessionArchiveWireRecord, maximumBytes: Int)
        throws
    {
        guard record.payload.count <= maximumBytes else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        try catalog.checkBudget(payloadBytes: record.payload.count)
    }
}

func sessionArchiveError(_ error: any Error, fallback: SessionArchiveError) -> SessionArchiveError {
    if let code = error as? SessionArchiveError { return code }
    if case ContractError.unsupportedSchemaVersion = error { return .unsupportedVersion }
    if case ContractError.invalidUnit = error { return .incompatibleUnit }
    return fallback
}
