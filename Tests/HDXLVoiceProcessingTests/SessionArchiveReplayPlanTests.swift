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
