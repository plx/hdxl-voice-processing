import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct SessionReplayPlanFixture {
    let profile: SessionArchiveProfile
    let source: SessionArchiveSource
    let series: SessionArchiveSeries
    let media: SessionArchiveMediaReference
    let mask: MaskPlan?

    init(
        masked: Bool = false, missing: Bool = false,
        inclusion: SessionArchiveMediaInclusion = .embedded
    ) throws {
        profile = try .schedule(
            AnalysisScheduleProfile(
                inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
                channels: .arithmeticMean, levels: sessionTestLevel()))
        source = try sessionTestSource(start: 100)
        let interval = try SourceInterval(
            epoch: source.origin.source.epoch, startSample: 100, sampleCount: 128, sampleRate: 16000
        )
        if masked {
            let provenance = try MaskProvenance(
                kind: .externalAnnotation,
                identifier: VersionedIdentifier(name: "synthetic-replay-mask", version: 1))
            mask = try MaskPlan(
                source: interval, provenances: [provenance], policy: MaskSelectionPolicy(),
                observations: [
                    MaskObservation(
                        source: missing
                            ? SourceInterval(
                                epoch: interval.epoch, startSample: 150, sampleCount: 5,
                                sampleRate: 16000) : interval,
                        provenanceIndex: 0,
                        tags: missing ? [.missingAcquisition] : [.speechDetected])
                ])
        } else {
            mask = nil
        }
        series = try SessionArchiveSeries(
            profileIndex: 0, sourceIndex: 0,
            measurement: MeasurementDescriptor(
                kind: .rms, unit: .normalizedAmplitude,
                algorithm: sessionTestLevel().identity().identifier),
            clock: .secondsFromOrigin, isScheduled: true,
            mask: mask.map {
                try SessionArchiveMask(
                    PreparedAnalysisMask(timeline: MaskTimeline($0), scope: .allEligible).provenance
                )
            })
        media = try sessionTestMedia(
            Data("abc".utf8), inclusion: inclusion,
            mappings: [
                SessionArchiveMediaMapping(sourceIndex: 0, source: interval, fileStartSample: 0)
            ])
    }

    func prepare(_ writer: SessionArchiveWriter) throws {
        try writer.addProfile(profile)
        try writer.addSource(source)
        try writer.addSeries(series)
        try writer.addMediaReference(media)
    }
}

@Test func sessionReplayPlanRetainsExactRecipeMaskAndExplicitAudioAbsence() throws {
    for masked in [false, true] {
        for inclusion in [SessionArchiveMediaInclusion.embedded, .omitted] {
            let fixture = try SessionReplayPlanFixture(masked: masked, inclusion: inclusion)
            var bytes = Data()
            let writer = try SessionArchiveWriter(
                header: sessionAudioHeader(), limits: SessionArchiveLimits()
            ) { bytes.append($0) }
            try fixture.prepare(writer)
            let plan = try SessionArchiveReplayPlan(
                seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0, mask: fixture.mask)
            try writer.addReplayPlan(plan)
            #expect(throws: SessionArchiveError.duplicateIdentity) {
                try writer.addReplayPlan(plan)
            }
            if inclusion == .embedded { try writer.appendMedia(Data("abc".utf8), to: 0) }
            try writer.finish()
            var offset = 0
            let reader = try SessionArchiveReader(limits: SessionArchiveLimits()) { n in
                let data = Data(bytes.dropFirst(offset).prefix(n))
                offset += data.count
                return data
            }
            var plans = 0
            while let event = try reader.next() {
                if case .replayPlan(let index, let value) = event {
                    #expect(index == 0 && value == plan)
                    plans += 1
                }
            }
            #expect(plans == 1 && reader.replayPlanIndex(for: 0) == 0)
            #expect(reader.replayPlanIndex(for: 1) == nil)
            #expect(try reader.replayPlan(at: 0) == plan)
            #expect(try reader.mediaReference(at: 0).inclusion == inclusion)
            #expect(try reader.profile(at: 0) == fixture.profile)
            #expect(reader.seal != nil && reader.statistics.catalogEntries == 6)
        }
    }
}

@Test func sessionReplayPlanRejectsMissingOrChangedMaskAndDoesNotJoinGaps() throws {
    let fixture = try SessionReplayPlanFixture(masked: true)
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionAudioHeader(), limits: SessionArchiveLimits()
    ) { bytes.append($0) }
    try fixture.prepare(writer)
    let before = bytes
    #expect(throws: SessionArchiveError.invalidMetadata) {
        try writer.addReplayPlan(
            SessionArchiveReplayPlan(seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0))
    }
    let original = try #require(fixture.mask)
    let changed = try MaskPlan(
        source: original.source, provenances: original.provenances, policy: original.policy,
        observations: original.observations,
        effectiveDelaySeconds: original.effectiveDelaySeconds + 1)
    #expect(throws: SessionArchiveError.incompatibleProfile) {
        try writer.addReplayPlan(
            SessionArchiveReplayPlan(
                seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0, mask: changed))
    }
    #expect(throws: SessionArchiveError.outOfOrder) {
        try writer.addReplayPlan(
            SessionArchiveReplayPlan(
                seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 1, mask: original))
    }
    #expect(bytes == before)
    let withGap = try SessionReplayPlanFixture(masked: true, missing: true)
    let other = try SessionArchiveWriter(
        header: sessionAudioHeader(), limits: SessionArchiveLimits()
    ) { _ in }
    try withGap.prepare(other)
    #expect(throws: SessionArchiveError.invalidMetadata) {
        try other.addReplayPlan(
            SessionArchiveReplayPlan(
                seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0, mask: withGap.mask))
    }
}

@Test func sessionReplayPlanRefusesDifferentPCMRecipeAndBoundsMaskMetadata() throws {
    let fixture = try SessionReplayPlanFixture(masked: true)
    let writer = try SessionArchiveWriter(
        header: sessionAudioHeader(), limits: SessionArchiveLimits()
    ) { _ in }
    try writer.addProfile(fixture.profile)
    try writer.addSource(fixture.source)
    try writer.addSeries(fixture.series)
    let decoder = try CalibrationDecoderProvenance(
        identifier: fixture.media.decoder.identifier, runtime: fixture.media.decoder.runtime,
        storage: fixture.media.decoder.storage,
        decodedPCM: PCMFormat(sampleRate: 16000, channelCount: 2, encoding: .float64),
        fileSampleCount: 128)
    try writer.addMediaReference(
        SessionArchiveMediaReference(
            media: fixture.media.media, decoder: decoder, inclusion: .embedded,
            provenance: fixture.media.provenance, mappings: fixture.media.mappings))
    #expect(throws: SessionArchiveError.incompatibleProfile) {
        try writer.addReplayPlan(
            SessionArchiveReplayPlan(
                seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0, mask: fixture.mask))
    }
    let mask = try #require(fixture.mask)
    let excessive = try MaskPlan(
        source: mask.source, provenances: mask.provenances, policy: mask.policy,
        observations: Array(
            repeating: mask.observations[0],
            count: SessionArchiveReplayPlan.maximumMaskObservations + 1))
    #expect(throws: SessionArchiveError.sizeLimitExceeded) {
        _ = try SessionArchiveReplayPlan(
            seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0, mask: excessive)
    }
}

private func sessionReplayNextSource(_ fixture: SessionReplayPlanFixture) throws
    -> SessionArchiveSource
{
    try SessionArchiveSource(
        origin: AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: fixture.source.origin.source.epoch, startSample: 238,
                sampleCount: 0, sampleRate: 16000),
            continuityEpoch: fixture.source.origin.continuityEpoch.successor()),
        acquisition: fixture.source.acquisition)
}

private func sessionReplayGap(
    _ fixture: SessionReplayPlanFixture, observedCount: Int64, knownLoss: Bool
) throws -> SessionArchiveGap {
    let observed = try SourceInterval(
        epoch: fixture.source.origin.source.epoch, startSample: 100,
        sampleCount: observedCount, sampleRate: 16000)
    return try SessionArchiveGap(
        previousSourceIndex: 0, nextSourceIndex: 1, observedSource: observed,
        dispatchedSourceSamples: observedCount - 8, pendingSourceSamplesDiscarded: 8,
        missingSource: knownLoss
            ? SourceInterval(
                epoch: observed.epoch, startSample: observed.endSample,
                sampleCount: 238 - observed.endSample, sampleRate: 16000) : nil,
        reason: .droppedAudio)
}

private func sessionReplayReader(_ bytes: Data) throws -> SessionArchiveReader {
    var offset = 0
    return try SessionArchiveReader(limits: SessionArchiveLimits()) { count in
        let data = Data(bytes.dropFirst(offset).prefix(count))
        offset += data.count
        return data
    }
}

@Test func sessionReplayWriterRejectsMappingsBeyondGapInEitherRecordOrder() throws {
    for gapFirst in [false, true] {
        for knownLoss in [false, true] {
            let fixture = try SessionReplayPlanFixture(inclusion: .omitted)
            var bytes = Data()
            let writer = try SessionArchiveWriter(
                header: sessionAudioHeader(), limits: SessionArchiveLimits()
            ) { bytes.append($0) }
            try fixture.prepare(writer)
            try writer.addSource(sessionReplayNextSource(fixture))
            let plan = try SessionArchiveReplayPlan(
                seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0)
            let gap = try sessionReplayGap(fixture, observedCount: 64, knownLoss: knownLoss)
            if gapFirst { try writer.append(gap) } else { try writer.addReplayPlan(plan) }
            let before = bytes
            let statistics = writer.statistics
            // A refused record must not publish bytes or reserve an identity.
            for _ in 0..<2 {
                #expect(throws: SessionArchiveError.invalidMetadata) {
                    if gapFirst { try writer.addReplayPlan(plan) } else { try writer.append(gap) }
                }
                #expect(bytes == before)
                #expect(writer.statistics == statistics)
            }
            if !gapFirst {
                try writer.append(
                    sessionReplayGap(fixture, observedCount: 128, knownLoss: knownLoss))
            }
            try writer.finish()
            let reader = try sessionReplayReader(bytes)
            while try reader.next() != nil {}
            #expect(reader.seal?.gapCount == 1)
            #expect(reader.replayPlanIndex(for: 0) == (gapFirst ? nil : 0))
        }
    }
}

// Bypass semantic writer validation to test an importer receiving an otherwise
// correctly framed, hashed and sealed archive from an independent producer.
private func sessionRawReplayGapArchive(
    observedCount: Int64, gapFirst: Bool, knownLoss: Bool
) throws -> Data {
    let fixture = try SessionReplayPlanFixture(inclusion: .omitted)
    var bytes = Data()
    let wire = try SessionArchiveWireWriter(limits: SessionArchiveLimits()) { bytes.append($0) }
    try wire.append(.header, payload: canonicalContractJSON(sessionAudioHeader()))
    try wire.append(.profile, payload: canonicalContractJSON(fixture.profile))
    try wire.append(.source, payload: canonicalContractJSON(fixture.source))
    try wire.append(.source, payload: canonicalContractJSON(sessionReplayNextSource(fixture)))
    try wire.append(.series, payload: canonicalContractJSON(fixture.series))
    try wire.append(.mediaReference, payload: canonicalContractJSON(fixture.media))
    let gap = try canonicalContractJSON(
        sessionReplayGap(fixture, observedCount: observedCount, knownLoss: knownLoss))
    let plan = try canonicalContractJSON(
        SessionArchiveReplayPlan(seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0))
    if gapFirst { try wire.append(.gap, payload: gap) }
    try wire.append(.replayPlan, payload: plan)
    if !gapFirst { try wire.append(.gap, payload: gap) }
    let seal = try SessionArchiveSeal(
        completion: .completed, precedingRecordCount: wire.recordCount,
        precedingByteCount: wire.byteCount,
        precedingSHA256: CalibrationDigest(sha256: wire.prefixSHA256),
        measurementCount: 0, gapCount: 1, catalogEntryCount: 7, mediaReferenceCount: 1)
    try wire.append(.footer, payload: canonicalContractJSON(seal))
    return bytes
}

@Test func sessionReplayReaderRejectsGapCrossingButAcceptsAcquiredPendingSamples() throws {
    for gapFirst in [false, true] {
        for knownLoss in [false, true] {
            let invalid = try sessionReplayReader(
                sessionRawReplayGapArchive(
                    observedCount: 64, gapFirst: gapFirst, knownLoss: knownLoss))
            #expect(throws: SessionArchiveError.invalidMetadata) {
                while try invalid.next() != nil {}
            }
            #expect(invalid.seal == nil && !invalid.isIncomplete)
            // Mapping [100,228) includes eight acquired-but-undispatched samples;
            // only [228,238) is missing. The mapping ends exactly at that boundary.
            let valid = try sessionReplayReader(
                sessionRawReplayGapArchive(
                    observedCount: 128, gapFirst: gapFirst, knownLoss: knownLoss))
            while try valid.next() != nil {}
            #expect(valid.seal?.gapCount == 1 && valid.replayPlanIndex(for: 0) == 0)
        }
    }
}

@Test func sessionReplayMetadataForNextSourceMayPrecedeItsIncomingGap() throws {
    let fixture = try SessionReplayPlanFixture(inclusion: .omitted)
    var bytes = Data()
    let writer = try SessionArchiveWriter(
        header: sessionAudioHeader(), limits: SessionArchiveLimits()
    ) { bytes.append($0) }
    try fixture.prepare(writer)
    let next = try sessionReplayNextSource(fixture)
    try writer.addSource(next)
    try writer.addSeries(
        SessionArchiveSeries(
            profileIndex: 0, sourceIndex: 1, measurement: fixture.series.measurement,
            clock: .secondsFromOrigin, isScheduled: true))
    try writer.addMediaReference(
        sessionTestMedia(
            Data("abc".utf8), inclusion: .omitted,
            mappings: [
                SessionArchiveMediaMapping(
                    sourceIndex: 1,
                    source: SourceInterval(
                        epoch: next.origin.source.epoch, startSample: 238,
                        sampleCount: 128, sampleRate: 16000), fileStartSample: 0)
            ], id: 5804))
    try writer.addReplayPlan(
        SessionArchiveReplayPlan(seriesIndex: 0, mediaReferenceIndex: 0, mappingIndex: 0))
    try writer.addReplayPlan(
        SessionArchiveReplayPlan(seriesIndex: 1, mediaReferenceIndex: 1, mappingIndex: 0))
    try writer.append(sessionReplayGap(fixture, observedCount: 128, knownLoss: true))
    try writer.finish()
    let reader = try sessionReplayReader(bytes)
    while try reader.next() != nil {}
    #expect(reader.replayPlanIndex(for: 1) == 1 && reader.seal?.gapCount == 1)
}
