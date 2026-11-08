import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func sessionGapRoundTripPreservesKnownAndUnknownLossAndClosesOldSource() throws {
    for known in [false, true] {
        let fixture = try sessionTestCatalog(start: 0)
        let previous = fixture.sources[0]
        let observed = try SourceInterval(
            epoch: previous.origin.source.epoch, startSample: 0, sampleCount: 20, sampleRate: 16000)
        let missing =
            known
            ? try SourceInterval(
                epoch: observed.epoch, startSample: 20, sampleCount: 5, sampleRate: 16000) : nil
        let next = try SessionArchiveSource(
            origin: AnalysisScheduleOrigin(
                source: SourceInterval(
                    epoch: observed.epoch, startSample: 25, sampleCount: 0, sampleRate: 16000),
                continuityEpoch: previous.origin.continuityEpoch.successor()),
            acquisition: previous.acquisition)
        let gap = try SessionArchiveGap(
            previousSourceIndex: 0, nextSourceIndex: 1, observedSource: observed,
            dispatchedSourceSamples: 18, pendingSourceSamplesDiscarded: 2, missingSource: missing,
            reason: .droppedAudio)
        var bytes = Data()
        let limits = try SessionArchiveLimits()
        let writer = try SessionArchiveWriter(header: sessionTestHeader(), limits: limits) {
            bytes.append($0)
        }
        try writer.addProfile(fixture.profiles[0].recipe)
        try writer.addSource(previous)
        try writer.addSource(next)
        try writer.addSeries(fixture.series[0])
        try writer.addSeries(
            SessionArchiveSeries(
                profileIndex: 0, sourceIndex: 1,
                measurement: fixture.series[0].measurement, clock: .sourceSamples))
        try writer.append(sessionTestMeasurement(catalog: fixture, start: 0), to: 0)
        try writer.append(gap)
        let afterGap = bytes
        #expect(throws: SessionArchiveError.outOfOrder) {
            try writer.append(sessionTestMeasurement(catalog: fixture, start: 10), to: 0)
        }
        #expect(bytes == afterGap)
        #expect(throws: SessionArchiveError.outOfOrder) { try writer.append(gap) }
        try writer.append(sessionTestMeasurement(catalog: fixture, start: 25), to: 1)
        try writer.finish(.partial)
        var offset = 0
        let reader = try SessionArchiveReader(limits: limits) { n in
            let data = Data(bytes.dropFirst(offset).prefix(n))
            offset += data.count
            return data
        }
        var gaps: [SessionArchiveGap] = []
        while let event = try reader.next() {
            if case .gap(let event) = event { gaps.append(event) }
        }
        #expect(gaps == [gap] && reader.seal?.gapCount == 1 && reader.seal?.measurementCount == 2)
        #expect(gaps[0].missingSource == missing)
        #expect(gaps[0].pendingSourceSamplesDiscarded == 2)
        #expect(
            try reader.source(at: 1).origin.continuityEpoch.sequence == previous.origin
                .continuityEpoch.sequence + 1)
    }
}

@Test func sessionGapRejectsContradictoryExtentsContinuityAndEarlierPublishedNextSource() throws {
    var catalog = try sessionTestCatalog(start: 0)
    let first = catalog.sources[0]
    let bad = try SessionArchiveSource(
        origin: AnalysisScheduleOrigin(
            source: SourceInterval(
                epoch: first.origin.source.epoch, startSample: 25, sampleCount: 0, sampleRate: 16000
            ),
            continuityEpoch: first.origin.continuityEpoch), acquisition: first.acquisition)
    try catalog.add(bad, payloadBytes: canonicalContractJSON(bad).count)
    let observed = try SourceInterval(
        epoch: first.origin.source.epoch, startSample: 0, sampleCount: 20, sampleRate: 16000)
    let gap = try SessionArchiveGap(
        previousSourceIndex: 0, nextSourceIndex: 1, observedSource: observed,
        dispatchedSourceSamples: 18, pendingSourceSamplesDiscarded: 2, missingSource: nil,
        reason: .droppedAudio)
    #expect(throws: SessionArchiveError.invalidMetadata) { try catalog.validate(gap) }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveGap(
            previousSourceIndex: 0, nextSourceIndex: 1, observedSource: observed,
            dispatchedSourceSamples: 18, pendingSourceSamplesDiscarded: 3, missingSource: nil,
            reason: .droppedAudio)
    }
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveGap(
            previousSourceIndex: 0, nextSourceIndex: 1, observedSource: observed,
            dispatchedSourceSamples: 18, pendingSourceSamplesDiscarded: 2,
            missingSource: SourceInterval(
                epoch: observed.epoch, startSample: 19, sampleCount: 5, sampleRate: 16000),
            reason: .droppedAudio)
    }
    let good = try SessionArchiveSource(
        origin: AnalysisScheduleOrigin(
            source: bad.origin.source,
            continuityEpoch: first.origin.continuityEpoch.successor()),
        acquisition: first.acquisition)
    try catalog.add(good, payloadBytes: canonicalContractJSON(good).count)
    try catalog.add(
        SessionArchiveSeries(
            profileIndex: 0, sourceIndex: 2, measurement: catalog.series[0].measurement,
            clock: .sourceSamples), payloadBytes: 100)
    let properGap = try SessionArchiveGap(
        previousSourceIndex: 0, nextSourceIndex: 2, observedSource: observed,
        dispatchedSourceSamples: 18, pendingSourceSamplesDiscarded: 2, missingSource: nil,
        reason: .droppedAudio)
    try catalog.validate(properGap)
    let later = try sessionTestMeasurement(catalog: catalog, start: 25)
    try catalog.validate(later, seriesIndex: 1)
    catalog.accepted(later, seriesIndex: 1)
    #expect(throws: SessionArchiveError.outOfOrder) { try catalog.validate(properGap) }
}
