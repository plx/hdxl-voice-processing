import Foundation
import Testing

@testable import HDXLVoiceProcessing

func sessionAudioHeader() throws -> SessionArchiveHeader {
    let value = try sessionTestHeader()
    return try SessionArchiveHeader(
        id: value.id, producer: value.producer, audioPolicy: .explicitlyInclude)
}

func sessionTestMedia(
    _ bytes: Data, inclusion: SessionArchiveMediaInclusion = .embedded,
    mappings: [SessionArchiveMediaMapping] = [], id: Int = 5803
) throws -> SessionArchiveMediaReference {
    // Arbitrary bytes test framing/integrity only. Actual PCM containers and the
    // decoder receipt are verified separately by Audio adapter integration tests.
    try SessionArchiveMediaReference(
        media: CalibrationMediaReference(
            referenceIdentifier: "synthetic-media-\(id)",
            originalRecordingID: calibrationTestID(id), content: CalibrationDigest(bytes: bytes),
            byteCount: Int64(bytes.count)),
        decoder: CalibrationDecoderProvenance(
            identifier: "synthetic-format-contract", runtime: "synthetic-test",
            storage: ["container": .text("synthetic")],
            decodedPCM: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
            fileSampleCount: 128), inclusion: inclusion,
        provenance: VersionedIdentifier(name: "synthetic-original-file", version: 1),
        mappings: mappings)
}

private func sessionMediaReader(
    _ bytes: Data, access: SessionArchiveMediaAccess = .verifyOnly,
    limits: SessionArchiveLimits? = nil, recovery: SessionArchiveRecovery = .requireComplete
) throws -> SessionArchiveReader {
    var offset = 0
    return try SessionArchiveReader(
        limits: limits ?? SessionArchiveLimits(ioChunkCapacity: 256), recovery: recovery,
        mediaAccess: access
    ) { n in
        let data = Data(bytes.dropFirst(offset).prefix(min(n, 17)))
        offset += data.count
        return data
    }
}

private func sessionMediaDrain(_ reader: SessionArchiveReader) throws {
    while try reader.next() != nil {}
}

private func sessionRawMediaArchive(
    _ reference: SessionArchiveMediaReference,
    chunks: [(UInt32, UInt64, Data)], header: SessionArchiveHeader? = nil
) throws -> Data {
    var bytes = Data()
    let wire = try SessionArchiveWireWriter(limits: SessionArchiveLimits()) { bytes.append($0) }
    try wire.append(.header, payload: canonicalContractJSON(header ?? sessionAudioHeader()))
    try wire.append(.mediaReference, payload: canonicalContractJSON(reference))
    var embeddedBytes: UInt64 = 0
    for (index, offset, data) in chunks {
        var payload = Data()
        SessionArchiveWire.append(index, to: &payload)
        SessionArchiveWire.append(offset, to: &payload)
        payload.append(data)
        embeddedBytes += UInt64(data.count)
        try wire.append(.mediaChunk, payload: payload)
    }
    let seal = try SessionArchiveSeal(
        completion: .completed, precedingRecordCount: wire.recordCount,
        precedingByteCount: wire.byteCount,
        precedingSHA256: CalibrationDigest(sha256: wire.prefixSHA256),
        measurementCount: 0, gapCount: 0, catalogEntryCount: 2, mediaReferenceCount: 1,
        embeddedMediaBytes: embeddedBytes)
    try wire.append(.footer, payload: canonicalContractJSON(seal))
    return bytes
}

@Test func sessionMediaLargeChunksVerifyWithSmallIOAndRequireExplicitByteDelivery() throws {
    let original = Data((0..<70_003).map { UInt8($0 % 251) })
    let reference = try sessionTestMedia(original)
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionAudioHeader(), limits: SessionArchiveLimits(ioChunkCapacity: 256)
    ) { bytes.append($0) }
    try writer.addMediaReference(reference)
    #expect(writer.maximumMediaChunkBytes == 65_536)
    try writer.appendMedia(Data(original.prefix(65_536)), to: 0)
    try writer.appendMedia(Data(original.dropFirst(65_536)), to: 0)
    try writer.finish()
    for access in [SessionArchiveMediaAccess.verifyOnly, .deliverBytes] {
        let reader = try sessionMediaReader(bytes, access: access)
        var delivered = Data()
        var total = 0
        var chunks = 0
        while let event = try reader.next() {
            if case .mediaChunk(let chunk) = event {
                #expect(chunk.referenceIndex == 0 && chunk.offset == UInt64(total))
                total += chunk.byteCount
                chunks += 1
                if access == .verifyOnly {
                    #expect(chunk.bytes == nil)
                } else {
                    delivered.append(try #require(chunk.bytes))
                }
            }
        }
        #expect(total == original.count && chunks == 2)
        #expect(access == .verifyOnly ? delivered.isEmpty : delivered == original)
        #expect(try reader.mediaReference(at: 0) == reference)
        #expect(reader.mediaReferenceIndex(matching: reference.media) == 0)
        #expect(try reader.mediaBytesAreVerified(at: 0))
        #expect(reader.seal?.embeddedMediaBytes == UInt64(original.count))
        #expect(reader.seal?.mediaReferenceCount == 1)
        #expect(reader.statistics.maximumRecordPayloadBytes == 65_536 + 12)
        #expect(reader.statistics.maximumIOChunkBytes <= 17)
    }
    #expect(writer.statistics.maximumIOChunkBytes <= 256)
}

@Test func sessionMediaOmissionRetainsReferencesWithoutImplicitAudio() throws {
    let original = Data("abc".utf8)
    #expect(
        CalibrationDigest(bytes: original).sha256
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionTestHeader(), limits: SessionArchiveLimits()
    ) { bytes.append($0) }
    let before = bytes
    #expect(throws: SessionArchiveError.audioNotOptedIn) {
        try writer.addMediaReference(sessionTestMedia(original))
    }
    #expect(bytes == before)
    let omitted = try sessionTestMedia(original, inclusion: .omitted)
    try writer.addMediaReference(omitted)
    #expect(throws: SessionArchiveError.audioNotOptedIn) { try writer.appendMedia(original, to: 0) }
    try writer.finish()
    let reader = try sessionMediaReader(bytes, access: .deliverBytes)
    var chunks = 0
    while let event = try reader.next() { if case .mediaChunk = event { chunks += 1 } }
    #expect(chunks == 0 && reader.header.audioPolicy == .omit)
    #expect(try reader.mediaReference(at: 0).inclusion == .omitted)
    #expect(try !reader.mediaBytesAreVerified(at: 0))
    #expect(reader.seal?.embeddedMediaBytes == 0)
}

@Test func sessionMediaFinalChunkDigestFailureAndMissingBytesDoNotCommit() throws {
    let original = Data("abc".utf8)
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionAudioHeader(), limits: SessionArchiveLimits()
    ) { bytes.append($0) }
    try writer.addMediaReference(sessionTestMedia(original))
    try writer.appendMedia(Data("ab".utf8), to: 0)
    let before = bytes
    #expect(throws: SessionArchiveError.missingMedia) { try writer.finish() }
    #expect(throws: SessionArchiveError.integrityMismatch) {
        try writer.appendMedia(Data("x".utf8), to: 0)
    }
    #expect(bytes == before && writer.statistics.embeddedMediaBytes == 2)
    try writer.appendMedia(Data("c".utf8), to: 0)
    #expect(throws: SessionArchiveError.outOfOrder) {
        try writer.appendMedia(Data("c".utf8), to: 0)
    }
    try writer.finish()
    let reader = try sessionMediaReader(bytes)
    try sessionMediaDrain(reader)
    #expect(reader.seal?.embeddedMediaBytes == 3)
}

@Test func sessionMediaInputRejectsValidlyFramedButMissingCorruptOrReorderedPayload() throws {
    let original = Data("abc".utf8)
    let reference = try sessionTestMedia(original)
    let cases: [([(UInt32, UInt64, Data)], SessionArchiveError)] = [
        ([], .missingMedia),
        ([(0, 0, Data("abx".utf8))], .integrityMismatch),
        ([(0, 1, original)], .outOfOrder),
        ([(1, 0, original)], .outOfOrder),
        ([(0, 0, Data())], .sizeLimitExceeded),
        ([(0, 0, Data("ab".utf8)), (0, 0, Data("ab".utf8))], .outOfOrder),
        ([(0, 0, original), (0, 3, Data("d".utf8))], .outOfOrder),
    ]
    for (chunks, expected) in cases {
        let bytes = try sessionRawMediaArchive(reference, chunks: chunks)
        let reader = try sessionMediaReader(bytes, recovery: .inspectCompletePrefix)
        #expect(throws: expected) { try sessionMediaDrain(reader) }
        #expect(reader.seal == nil && !reader.isIncomplete)
    }
    let noOptIn = try sessionRawMediaArchive(
        reference, chunks: [(0, 0, original)], header: sessionTestHeader())
    #expect(throws: SessionArchiveError.audioNotOptedIn) {
        try sessionMediaDrain(sessionMediaReader(noOptIn))
    }
}

@Test func sessionMediaBudgetsAreAggregateAndCheckedBeforeAcceptingReferences() throws {
    let first = Data(repeating: 1, count: 60)
    let second = Data(repeating: 2, count: 41)
    var bytes = Data()
    let limits = try SessionArchiveLimits(maximumEmbeddedMediaBytes: 100)
    let writer = try SessionArchiveWriter(header: sessionAudioHeader(), limits: limits) {
        bytes.append($0)
    }
    try writer.addMediaReference(sessionTestMedia(first))
    let before = bytes
    #expect(throws: SessionArchiveError.sizeLimitExceeded) {
        try writer.addMediaReference(sessionTestMedia(second, id: 5804))
    }
    #expect(bytes == before && writer.statistics.mediaReferenceCount == 1)
    #expect(throws: SessionArchiveError.duplicateIdentity) {
        try writer.addMediaReference(sessionTestMedia(first))
    }
    try writer.appendMedia(first, to: 0)
    try writer.finish()
    let reader = try sessionMediaReader(
        bytes, limits: SessionArchiveLimits(maximumEmbeddedMediaBytes: 0))
    #expect(throws: SessionArchiveError.sizeLimitExceeded) { try sessionMediaDrain(reader) }
}

@Test func sessionMediaMappingsPreserveLargeClocksAndRejectOverlapAndOutOfFileRanges() throws {
    let origin = try sessionTestSource(start: (1 << 54) + 7)
    let interval = try SourceInterval(
        epoch: origin.origin.source.epoch, startSample: origin.origin.source.startSample,
        sampleCount: 128, sampleRate: 16000)
    let mapping = try SessionArchiveMediaMapping(
        sourceIndex: 0, source: interval, fileStartSample: 0)
    let original = Data("abc".utf8)
    let reference = try sessionTestMedia(original, mappings: [mapping])
    #expect(reference.mappings[0].source.startSample == (1 << 54) + 7)
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try sessionTestMedia(original, mappings: [mapping, mapping])
    }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try sessionTestMedia(
            original,
            mappings: [
                SessionArchiveMediaMapping(sourceIndex: 0, source: interval, fileStartSample: 1)
            ])
    }
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionAudioHeader(), limits: SessionArchiveLimits()
    ) { bytes.append($0) }
    #expect(throws: SessionArchiveError.outOfOrder) { try writer.addMediaReference(reference) }
    try writer.addSource(origin)
    try writer.addMediaReference(reference)
    try writer.appendMedia(original, to: 0)
    try writer.finish()
    let reader = try sessionMediaReader(bytes)
    try sessionMediaDrain(reader)
    #expect(try reader.mediaReference(at: 0) == reference)
}
