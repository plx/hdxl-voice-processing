import Foundation

/// A reset keeps the observed old interval, discarded pending work, reason and
/// known loss extent. Nil loss is unknown/unreported; it is never zero-filled.
/// Source indices refer to the complete old and new origins in the catalog.
public struct SessionArchiveGap: Sendable, Hashable, Codable {
    public let previousSourceIndex: UInt32
    public let nextSourceIndex: UInt32
    public let observedSource: SourceInterval
    public let dispatchedSourceSamples: Int64
    public let pendingSourceSamplesDiscarded: Int
    public let missingSource: SourceInterval?
    public let reason: ResetReason

    public init(
        previousSourceIndex: UInt32, nextSourceIndex: UInt32, observedSource: SourceInterval,
        dispatchedSourceSamples: Int64, pendingSourceSamplesDiscarded: Int,
        missingSource: SourceInterval?, reason: ResetReason
    ) throws {
        guard previousSourceIndex != nextSourceIndex,
            (0...observedSource.sampleCount).contains(dispatchedSourceSamples),
            pendingSourceSamplesDiscarded >= 0,
            Int64(pendingSourceSamplesDiscarded) == observedSource.sampleCount
                - dispatchedSourceSamples
        else { throw SessionArchiveError.invalidMetadata }
        if let missingSource {
            guard missingSource.epoch == observedSource.epoch,
                missingSource.sampleRate == observedSource.sampleRate,
                missingSource.startSample == observedSource.endSample, missingSource.sampleCount > 0
            else { throw SessionArchiveError.invalidMetadata }
        }
        self.previousSourceIndex = previousSourceIndex
        self.nextSourceIndex = nextSourceIndex
        self.observedSource = observedSource
        self.dispatchedSourceSamples = dispatchedSourceSamples
        self.pendingSourceSamplesDiscarded = pendingSourceSamplesDiscarded
        self.missingSource = missingSource
        self.reason = reason
    }

    public init(
        _ reset: AnalysisScheduleReset, previousSourceIndex: UInt32, nextSourceIndex: UInt32,
        previousSource: SessionArchiveSource, nextSource: SessionArchiveSource
    ) throws {
        guard reset.previousOrigin == previousSource.origin, reset.nextOrigin == nextSource.origin
        else {
            throw SessionArchiveError.invalidMetadata
        }
        try self.init(
            previousSourceIndex: previousSourceIndex, nextSourceIndex: nextSourceIndex,
            observedSource: reset.observedSource,
            dispatchedSourceSamples: reset.dispatchedSourceSamples,
            pendingSourceSamplesDiscarded: reset.pendingSourceSamplesDiscarded,
            missingSource: reset.missingSource, reason: reset.reason)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case previousSourceIndex, nextSourceIndex, observedSource, dispatchedSourceSamples
        case pendingSourceSamplesDiscarded, missingSource, reason
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        guard c.contains(.missingSource) else { throw SessionArchiveError.invalidMetadata }
        try self.init(
            previousSourceIndex: c.decode(UInt32.self, forKey: .previousSourceIndex),
            nextSourceIndex: c.decode(UInt32.self, forKey: .nextSourceIndex),
            observedSource: c.decode(SourceInterval.self, forKey: .observedSource),
            dispatchedSourceSamples: c.decode(Int64.self, forKey: .dispatchedSourceSamples),
            pendingSourceSamplesDiscarded: c.decode(
                Int.self, forKey: .pendingSourceSamplesDiscarded),
            missingSource: c.decodeIfPresent(SourceInterval.self, forKey: .missingSource),
            reason: c.decode(ResetReason.self, forKey: .reason))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(previousSourceIndex, forKey: .previousSourceIndex)
        try c.encode(nextSourceIndex, forKey: .nextSourceIndex)
        try c.encode(observedSource, forKey: .observedSource)
        try c.encode(dispatchedSourceSamples, forKey: .dispatchedSourceSamples)
        try c.encode(pendingSourceSamplesDiscarded, forKey: .pendingSourceSamplesDiscarded)
        try c.encode(missingSource, forKey: .missingSource)
        try c.encode(reason, forKey: .reason)
    }
}

/// A final integrity seal covers the magic and every preceding framed record.
/// It proves internal completeness, not authenticity or fitness of a target.
public struct SessionArchiveSeal: Sendable, Hashable, Codable {
    public let completion: SessionArchiveCompletion
    public let precedingRecordCount: UInt64
    public let precedingByteCount: UInt64
    public let precedingSHA256: CalibrationDigest
    public let measurementCount: UInt64
    public let gapCount: UInt64
    public let catalogEntryCount: Int
    public let mediaReferenceCount: UInt64
    public let embeddedMediaBytes: UInt64

    init(
        completion: SessionArchiveCompletion, precedingRecordCount: UInt64,
        precedingByteCount: UInt64,
        precedingSHA256: CalibrationDigest, measurementCount: UInt64, gapCount: UInt64,
        catalogEntryCount: Int, mediaReferenceCount: UInt64 = 0, embeddedMediaBytes: UInt64 = 0
    ) throws {
        guard precedingRecordCount > 0, precedingByteCount >= 16,
            measurementCount <= precedingRecordCount, gapCount <= precedingRecordCount,
            catalogEntryCount > 0, UInt64(catalogEntryCount) <= precedingRecordCount,
            gapCount <= precedingRecordCount - measurementCount,
            UInt64(catalogEntryCount) <= precedingRecordCount - measurementCount - gapCount,
            mediaReferenceCount <= UInt64(catalogEntryCount),
            embeddedMediaBytes <= precedingByteCount
        else { throw SessionArchiveError.invalidMetadata }
        self.completion = completion
        self.precedingRecordCount = precedingRecordCount
        self.precedingByteCount = precedingByteCount
        self.precedingSHA256 = precedingSHA256
        self.measurementCount = measurementCount
        self.gapCount = gapCount
        self.catalogEntryCount = catalogEntryCount
        self.mediaReferenceCount = mediaReferenceCount
        self.embeddedMediaBytes = embeddedMediaBytes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case completion, precedingRecordCount, precedingByteCount, precedingSHA256
        case measurementCount, gapCount, catalogEntryCount, mediaReferenceCount, embeddedMediaBytes
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            completion: c.decode(SessionArchiveCompletion.self, forKey: .completion),
            precedingRecordCount: c.decode(UInt64.self, forKey: .precedingRecordCount),
            precedingByteCount: c.decode(UInt64.self, forKey: .precedingByteCount),
            precedingSHA256: c.decode(CalibrationDigest.self, forKey: .precedingSHA256),
            measurementCount: c.decode(UInt64.self, forKey: .measurementCount),
            gapCount: c.decode(UInt64.self, forKey: .gapCount),
            catalogEntryCount: c.decode(Int.self, forKey: .catalogEntryCount),
            mediaReferenceCount: c.decode(UInt64.self, forKey: .mediaReferenceCount),
            embeddedMediaBytes: c.decode(UInt64.self, forKey: .embeddedMediaBytes))
    }
}
