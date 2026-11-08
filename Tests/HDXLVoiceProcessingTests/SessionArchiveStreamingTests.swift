import Foundation
import Testing

@testable import HDXLVoiceProcessing

func sessionTestHeader() throws -> SessionArchiveHeader {
    try SessionArchiveHeader(
        id: calibrationTestID(5802),
        producer: VersionedIdentifier(name: "synthetic-session-fixture", version: 1),
        createdAtUnixSeconds: 1_700_000_000, notes: "Synthetic fixture; no participant data")
}

private func sessionStreamingReader(
    _ bytes: Data, limits: SessionArchiveLimits? = nil,
    recovery: SessionArchiveRecovery = .requireComplete, chunk: Int = 31
) throws -> SessionArchiveReader {
    var offset = 0
    return try SessionArchiveReader(limits: limits ?? SessionArchiveLimits(), recovery: recovery) {
        requested in
        let count = min(requested, chunk, bytes.count - offset)
        defer { offset += count }
        return Data(bytes.dropFirst(offset).prefix(count))
    }
}

private func sessionTestArchive(
    count: Int = 2, completion: SessionArchiveCompletion = .completed, seal: Bool = true
) throws
    -> (Data, SessionArchiveIOStatistics)
{
    let catalog = try sessionTestCatalog(start: 0)
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionTestHeader(), limits: SessionArchiveLimits(ioChunkCapacity: 256)
    ) { bytes.append($0) }
    #expect(try writer.addProfile(catalog.profiles[0].recipe) == 0)
    #expect(try writer.addSource(catalog.sources[0]) == 0)
    #expect(try writer.addSeries(catalog.series[0]) == 0)
    for index in 0..<count {
        try writer.append(sessionTestMeasurement(catalog: catalog, start: Int64(index)), to: 0)
    }
    if seal { try writer.finish(completion) }
    return (bytes, writer.statistics)
}

private func sessionDrain(_ reader: SessionArchiveReader) throws -> [SessionArchiveEvent] {
    var events: [SessionArchiveEvent] = []
    while let event = try reader.next() { events.append(event) }
    return events
}

@Test func sessionStreamingRoundTripsCompletePartialAndCancelledContainers() throws {
    for completion in [SessionArchiveCompletion.completed, .partial, .cancelled] {
        let (bytes, written) = try sessionTestArchive(completion: completion)
        let reader = try sessionStreamingReader(bytes, chunk: 1)
        #expect(reader.header == (try sessionTestHeader()))
        #expect(reader.header.audioPolicy == .omit && reader.seal == nil)
        let events = try sessionDrain(reader)
        #expect(events.count == 6)
        #expect(reader.seal?.completion == completion && !reader.isIncomplete)
        #expect(reader.seal?.measurementCount == 2 && reader.seal?.gapCount == 0)
        #expect(reader.seal?.catalogEntryCount == 4)
        #expect(try reader.next() == nil)
        #expect(reader.statistics.bytesProcessed == UInt64(bytes.count))
        #expect(reader.statistics.framedRecords == written.framedRecords)
        #expect(reader.statistics.encodedCatalogBytes == written.encodedCatalogBytes)
        #expect(reader.statistics.maximumRecordPayloadBytes == written.maximumRecordPayloadBytes)
        #expect(reader.statistics.maximumIOChunkBytes == 1 && written.maximumIOChunkBytes <= 256)
        #expect(try reader.profile(at: 0) == .levels(sessionTestLevel()))
        #expect(try reader.source(at: 0) == sessionTestSource())
        #expect(try reader.series(at: 0).clock == .sourceSamples)
        #expect(throws: SessionArchiveError.invalidMetadata) { _ = try reader.profile(at: 1) }
    }
}

@Test func sessionStreamingRecoveryIsExplicitAndNeverConfusesTruncationWithASeal() throws {
    let (bytes, _) = try sessionTestArchive()
    var starts: [Int] = []
    var offset = 16
    while offset < bytes.count {
        starts.append(offset)
        offset += 48 + Int(SessionArchiveWire.unsigned(bytes, offset: offset + 4, bytes: 4))
    }
    #expect(offset == bytes.count && starts.count == 7)
    // Every cut through the second scalar or seal, plus complete-record cuts.
    let cuts = Set(starts.dropFirst()).union(starts[5]..<bytes.count)
    for cut in cuts.sorted() {
        let prefix = Data(bytes.prefix(cut))
        let strict = try sessionStreamingReader(prefix)
        #expect(throws: SessionArchiveError.truncated) { _ = try sessionDrain(strict) }
        #expect(strict.seal == nil && !strict.isIncomplete)
        let recover = try sessionStreamingReader(prefix, recovery: .inspectCompletePrefix)
        let events = try sessionDrain(recover)
        #expect(events.last == .incomplete && recover.seal == nil && recover.isIncomplete)
        #expect(try recover.next() == nil)
    }
    for cut in [0, 9, 15, 16, starts[1] - 1] {
        #expect(throws: SessionArchiveError.truncated) {
            _ = try sessionStreamingReader(
                Data(bytes.prefix(cut)), recovery: .inspectCompletePrefix)
        }
    }
    var trailing = bytes
    trailing.append(1)
    let invalid = try sessionStreamingReader(trailing, recovery: .inspectCompletePrefix)
    #expect(throws: SessionArchiveError.malformedRecord) { _ = try sessionDrain(invalid) }
    #expect(!invalid.isIncomplete && invalid.seal == nil)
    #expect(throws: SessionArchiveError.invalidState) { _ = try invalid.next() }
}

@Test func sessionStreamingCorruptionAndRehashedDuplicateTimestampsFailClosed() throws {
    let (original, _) = try sessionTestArchive()
    var corrupt = original
    corrupt[corrupt.count - 1] ^= 1
    let damaged = try sessionStreamingReader(corrupt, recovery: .inspectCompletePrefix)
    #expect(throws: SessionArchiveError.integrityMismatch) { _ = try sessionDrain(damaged) }
    #expect(damaged.seal == nil && !damaged.isIncomplete)

    let limits = try SessionArchiveLimits()
    var offset = 0
    let raw = try SessionArchiveWireReader(limits: limits) { requested in
        let result = Data(original.dropFirst(offset).prefix(requested))
        offset += result.count
        return result
    }
    var duplicate = Data()
    let output = try SessionArchiveWireWriter(limits: limits) { duplicate.append($0) }
    while let record = try raw.next() {
        if record.kind == .footer { break }
        try output.append(record.kind, payload: record.payload)
        if record.kind == .measurement {
            // Valid framing/checksum cannot make a duplicate semantic timestamp valid.
            try output.append(record.kind, payload: record.payload)
            break
        }
    }
    let reader = try sessionStreamingReader(duplicate, recovery: .inspectCompletePrefix)
    #expect(throws: SessionArchiveError.duplicateTimestamp) { _ = try sessionDrain(reader) }
    #expect(!reader.isIncomplete && reader.seal == nil)
}

@Test func sessionStreamingRejectsForgedSealCountsAndIdentity() throws {
    for corruptHash in [false, true] {
        let header = try sessionTestHeader()
        var bytes = Data()
        let wire = try SessionArchiveWireWriter(limits: SessionArchiveLimits()) { bytes.append($0) }
        try wire.append(.header, payload: canonicalContractJSON(header))
        let seal = try SessionArchiveSeal(
            completion: .completed, precedingRecordCount: corruptHash ? 1 : 2,
            precedingByteCount: wire.byteCount,
            precedingSHA256: CalibrationDigest(
                sha256: corruptHash ? String(repeating: "0", count: 64) : wire.prefixSHA256),
            measurementCount: 0, gapCount: 0, catalogEntryCount: corruptHash ? 1 : 2)
        try wire.append(.footer, payload: canonicalContractJSON(seal))
        let reader = try sessionStreamingReader(bytes)
        #expect(throws: SessionArchiveError.integrityMismatch) { _ = try reader.next() }
        #expect(reader.seal == nil)
    }
}

@Test func sessionStreamingWriterValidationIsRecoverableButSinkFailureIsTerminal() throws {
    let catalog = try sessionTestCatalog(start: 0)
    var bytes = Data()
    var failSink = false
    var writer: SessionArchiveWriter?
    var attemptedReentry = false
    writer = try SessionArchiveWriter(header: sessionTestHeader(), limits: SessionArchiveLimits()) {
        chunk in
        if failSink { throw NSError(domain: "/private/personal-recording", code: 1) }
        if let writer, !attemptedReentry {
            attemptedReentry = true
            #expect(throws: SessionArchiveError.invalidState) { _ = try writer.finish() }
        }
        bytes.append(chunk)
    }
    let active = try #require(writer)
    try active.addProfile(catalog.profiles[0].recipe)
    #expect(attemptedReentry)
    let before = bytes
    #expect(throws: SessionArchiveError.duplicateIdentity) {
        try active.addProfile(catalog.profiles[0].recipe)
    }
    #expect(bytes == before)
    try active.addSource(catalog.sources[0])
    try active.addSeries(catalog.series[0])
    let frame = try sessionTestMeasurement(catalog: catalog, start: 0)
    try active.append(frame, to: 0)
    let written = bytes
    #expect(throws: SessionArchiveError.duplicateTimestamp) { try active.append(frame, to: 0) }
    #expect(bytes == written)
    failSink = true
    #expect(throws: SessionArchiveError.outputFailure) { try active.finish() }
    failSink = false
    #expect(throws: SessionArchiveError.invalidState) { try active.finish() }
    #expect(active.seal == nil)
    // Break the test's optional-holder closure cycle; the library retains only its sink.
    writer = nil
}

@Test func sessionStreamingLongTimelineKeepsMetadataAndRecordBoundsFixed() throws {
    let (bytes, written) = try sessionTestArchive(count: 20_000)
    let reader = try sessionStreamingReader(bytes, chunk: 257)
    var count = 0
    var initialCatalogBytes: Int?
    while let event = try reader.next() {
        if case .measurement(_, let record) = event {
            #expect(record.timestamp.sourceSample == Int64(count + 2))
            count += 1
            if initialCatalogBytes == nil {
                initialCatalogBytes = reader.statistics.encodedCatalogBytes
            }
            #expect(reader.statistics.encodedCatalogBytes == initialCatalogBytes)
            #expect(reader.statistics.catalogEntries == 4)
        }
    }
    #expect(count == 20_000 && reader.seal?.measurementCount == 20_000)
    #expect(reader.statistics.maximumRecordPayloadBytes == written.maximumRecordPayloadBytes)
    #expect(reader.statistics.maximumIOChunkBytes <= 257)
    #expect(written.maximumRecordPayloadBytes < 2048)
}
