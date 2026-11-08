import CryptoKit
import Foundation

public enum SessionArchiveMediaInclusion: String, Sendable, Hashable, Codable {
    case omitted, embedded
}

/// Import always verifies media integrity. Delivering the bytes themselves is a
/// separate explicit host choice; the default exposes only chunk counts/offsets.
public enum SessionArchiveMediaAccess: Sendable, Hashable {
    case verifyOnly, deliverBytes
}

/// A contiguous acquired interval maps to an exact interval in the original
/// file. Separate mappings preserve dropped input; no gap is filled with PCM.
public struct SessionArchiveMediaMapping: Sendable, Hashable, Codable {
    public let sourceIndex: UInt32
    public let source: SourceInterval
    public let fileStartSample: Int64

    public init(sourceIndex: UInt32, source: SourceInterval, fileStartSample: Int64) throws {
        guard source.sampleCount > 0, fileStartSample >= 0,
            !fileStartSample.addingReportingOverflow(source.sampleCount).overflow
        else { throw SessionArchiveError.invalidMetadata }
        self.sourceIndex = sourceIndex
        self.source = source
        self.fileStartSample = fileStartSample
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceIndex, source, fileStartSample
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            sourceIndex: c.decode(UInt32.self, forKey: .sourceIndex),
            source: c.decode(SourceInterval.self, forKey: .source),
            fileStartSample: c.decode(Int64.self, forKey: .fileStartSample))
    }
}

/// Original file bytes, including their container, are identified by the media
/// digest. The decoder receipt retains storage format, requested PCM format,
/// original frame count and exporter runtime. The Audio adapter verifies actual
/// decoder format before replay; these imported claims alone are not proof.
/// Omission is explicit and retains the reference without embedding audio.
public struct SessionArchiveMediaReference: Sendable, Hashable, Codable {
    public let media: CalibrationMediaReference
    public let decoder: CalibrationDecoderProvenance
    public let inclusion: SessionArchiveMediaInclusion
    public let provenance: VersionedIdentifier
    public let mappings: [SessionArchiveMediaMapping]
    public let notes: String

    public init(
        media: CalibrationMediaReference, decoder: CalibrationDecoderProvenance,
        inclusion: SessionArchiveMediaInclusion, provenance: VersionedIdentifier,
        mappings: [SessionArchiveMediaMapping] = [], notes: String = ""
    ) throws {
        guard media.byteCount > 0, mappings.count <= 4096 else {
            throw SessionArchiveError.invalidMetadata
        }
        let notes = notes.precomposedStringWithCanonicalMapping
        guard notes.utf8.count <= 4096 else { throw SessionArchiveError.sizeLimitExceeded }
        var ends: [UInt32: Int64] = [:]
        // Canonical source-index/start order also makes overlapping mappings
        // unambiguous without a quadratic scan of a potentially long catalog.
        let sorted = mappings.sorted {
            ($0.sourceIndex, $0.source.startSample) < ($1.sourceIndex, $1.source.startSample)
        }
        for mapping in sorted {
            guard mapping.source.sampleRate == decoder.decodedPCM.sampleRate,
                mapping.fileStartSample <= decoder.fileSampleCount,
                mapping.source.sampleCount <= decoder.fileSampleCount - mapping.fileStartSample,
                mapping.source.startSample >= ends[mapping.sourceIndex, default: 0]
            else { throw SessionArchiveError.invalidMetadata }
            ends[mapping.sourceIndex] = mapping.source.endSample
        }
        self.media = media
        self.decoder = decoder
        self.inclusion = inclusion
        self.provenance = provenance
        self.mappings = sorted
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case media, decoder, inclusion, provenance, mappings, notes
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.contractContainer(keyedBy: CodingKeys.self)
        try self.init(
            media: c.decode(CalibrationMediaReference.self, forKey: .media),
            decoder: c.decode(CalibrationDecoderProvenance.self, forKey: .decoder),
            inclusion: c.decode(SessionArchiveMediaInclusion.self, forKey: .inclusion),
            provenance: c.decode(VersionedIdentifier.self, forKey: .provenance),
            mappings: c.decode([SessionArchiveMediaMapping].self, forKey: .mappings),
            notes: c.decode(String.self, forKey: .notes))
    }
}

/// Bytes are nil unless the reader was explicitly configured to deliver audio.
/// Delivered chunks remain provisional until that reader verifies the final seal;
/// extraction must use private staging and discard it on any failure.
public struct SessionArchiveMediaChunk: Sendable, Hashable {
    public let referenceIndex: UInt32
    public let offset: UInt64
    public let byteCount: Int
    public let bytes: Data?
}

struct SessionArchiveMediaProgress {
    var hash = SHA256()
    var byteCount: UInt64 = 0
    var isVerified = false
}

/// Only bounded reference metadata and incremental hash state are retained.
/// Preparing one chunk copies one SHA256 state, never the entire reference table.
struct SessionArchiveMediaState {
    private(set) var references: [SessionArchiveMediaReference] = []
    private var indices: [CalibrationMediaReference: UInt32] = [:]
    private var progress: [SessionArchiveMediaProgress] = []
    private(set) var declaredEmbeddedBytes: UInt64 = 0
    private(set) var acceptedEmbeddedBytes: UInt64 = 0

    mutating func add(
        _ reference: SessionArchiveMediaReference, header: SessionArchiveHeader,
        catalog: SessionArchiveCatalog
    ) throws -> UInt32 {
        guard indices[reference.media] == nil else { throw SessionArchiveError.duplicateIdentity }
        let embedded = reference.inclusion == .embedded ? UInt64(reference.media.byteCount) : 0
        if reference.inclusion == .embedded {
            guard header.audioPolicy == .explicitlyInclude else {
                throw SessionArchiveError.audioNotOptedIn
            }
            guard embedded <= catalog.limits.maximumEmbeddedMediaBytes - declaredEmbeddedBytes
            else { throw SessionArchiveError.sizeLimitExceeded }
        }
        for mapping in reference.mappings {
            guard Int(mapping.sourceIndex) < catalog.sources.count else {
                throw SessionArchiveError.outOfOrder
            }
            let origin = catalog.sources[Int(mapping.sourceIndex)].origin.source
            guard mapping.source.epoch == origin.epoch,
                mapping.source.sampleRate == origin.sampleRate,
                mapping.source.startSample >= origin.startSample
            else { throw SessionArchiveError.invalidMetadata }
        }
        let index = UInt32(references.count)
        references.append(reference)
        indices[reference.media] = index
        progress.append(SessionArchiveMediaProgress())
        declaredEmbeddedBytes += embedded
        return index
    }

    func index(matching reference: CalibrationMediaReference) -> UInt32? { indices[reference] }

    func reference(at index: UInt32) throws -> SessionArchiveMediaReference {
        guard Int(index) < references.count else { throw SessionArchiveError.outOfOrder }
        return references[Int(index)]
    }

    func currentProgress(at index: UInt32) throws -> SessionArchiveMediaProgress {
        guard Int(index) < progress.count else { throw SessionArchiveError.outOfOrder }
        return progress[Int(index)]
    }

    func prepareChunk(index: UInt32, offset: UInt64, bytes: Data, limits: SessionArchiveLimits)
        throws -> SessionArchiveMediaProgress
    {
        let reference = try reference(at: index)
        guard reference.inclusion == .embedded else { throw SessionArchiveError.audioNotOptedIn }
        guard !bytes.isEmpty, bytes.count <= min(65_536, limits.maximumRecordBytes - 12) else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        var next = try currentProgress(at: index)
        guard !next.isVerified, offset == next.byteCount else {
            throw SessionArchiveError.outOfOrder
        }
        let length = UInt64(reference.media.byteCount)
        guard UInt64(bytes.count) <= length - next.byteCount else {
            throw SessionArchiveError.sizeLimitExceeded
        }
        next.hash.update(data: bytes)
        next.byteCount += UInt64(bytes.count)
        if next.byteCount == length {
            guard SessionArchiveWire.digest(next.hash) == reference.media.content.sha256 else {
                throw SessionArchiveError.integrityMismatch
            }
            next.isVerified = true
        }
        return next
    }

    mutating func acceptChunk(index: UInt32, progress next: SessionArchiveMediaProgress) {
        acceptedEmbeddedBytes += next.byteCount - progress[Int(index)].byteCount
        progress[Int(index)] = next
    }

    func validateComplete() throws {
        for index in references.indices where references[index].inclusion == .embedded {
            guard progress[index].isVerified else { throw SessionArchiveError.missingMedia }
        }
        guard acceptedEmbeddedBytes == declaredEmbeddedBytes else {
            throw SessionArchiveError.missingMedia
        }
    }
}
