import Foundation
import HDXLVoiceProcessing
import Testing

@testable import HDXLVoiceProcessingAudio

private struct SessionAudioReplayFixture {
    let profile: AnalysisScheduleProfile
    let source: SessionArchiveSource
    let interval: SourceInterval
    let fileStart: Int64
    let mask: MaskPlan?
    let mediaURL: URL
    let original: Data
    let decoder: CalibrationDecoderProvenance
    let metrics: [ScheduledMetric]
    let expected: [ScheduledMetric: [ScheduledMeasurementExport]]

    init(
        directory: URL, precision: AnalysisPrecision = .float64, layout: PCMLayout = .planar,
        allMetrics: Bool = false, masked: Bool = false
    ) throws {
        let rate = 16000
        let count = allMetrics ? 2401 : 1001
        let samples = (0..<count).flatMap { index -> [Int16] in
            let value = Int16(9000 * sin(2 * .pi * 125 * Double(index) / Double(rate)))
            return [value, -value / 2]
        }
        let temporary = try schedulingWAV(samples, rate: rate, channels: 2)
        defer { try? FileManager.default.removeItem(at: temporary) }
        mediaURL = directory.appendingPathComponent("original-\(UUID()).wav")
        original = try Data(contentsOf: temporary)
        try original.write(to: mediaURL)
        if allMetrics {
            let base = try fileScheduleProfile(precision: precision, layout: layout, rate: rate)
            profile = try AnalysisScheduleProfile(
                inputFormat: base.inputFormat, channels: base.channels, levels: base.levels,
                pitch: YINProfile(
                    estimator: try #require(base.pitch).estimator,
                    tracker: YINTrackerConfiguration()), cpps: base.cpps)
            metrics = [
                .meanSquare, .rms, .peakAmplitude, .crestFactor, .levelDBFS,
                .clippingFraction, .kWeightedEnergy, .fundamentalFrequency,
                .trackedFundamentalFrequency, .cpp, .cpps,
            ]
        } else {
            profile = try AnalysisScheduleProfile(
                inputFormat: PCMFormat(
                    sampleRate: Double(rate), channelCount: 2,
                    encoding: precision == .float32 ? .float32 : .float64, layout: layout),
                channels: .arithmeticMean,
                levels: LevelConfiguration(
                    sampleRate: rate, inputPrecision: precision, windowLength: 100,
                    hopLength: 50, accumulation: .compensatedSliding, weighting: .none))
            metrics = [.rms]
        }
        let epoch = StreamEpoch(streamID: UUID())
        let start: Int64 = (1 << 54) + 57
        let domain = try SourceInterval(
            epoch: epoch, startSample: start, sampleCount: Int64(count), sampleRate: Double(rate))
        if masked {
            mask = try MaskPlan(
                source: domain,
                provenances: [
                    MaskProvenance(
                        kind: .externalAnnotation,
                        identifier: VersionedIdentifier(name: "synthetic-gap", version: 1))
                ],
                policy: MaskSelectionPolicy(),
                observations: [
                    MaskObservation(
                        source: SourceInterval(
                            epoch: epoch, startSample: start + 300, sampleCount: 400,
                            sampleRate: Double(rate)), provenanceIndex: 0,
                        tags: [.missingAcquisition])
                ])
            fileStart = 700
        } else {
            mask = nil
            fileStart = 17
        }
        interval = try SourceInterval(
            epoch: epoch, startSample: start + fileStart, sampleCount: Int64(count) - fileStart,
            sampleRate: Double(rate))
        source = try SessionArchiveSource(
            origin: AnalysisScheduleOrigin(
                source: SourceInterval(
                    epoch: epoch, startSample: interval.startSample, sampleCount: 0,
                    sampleRate: Double(rate)), continuityEpoch: StreamEpoch(streamID: UUID()),
                sourceStartSeconds: 12.25),
            acquisition: SessionAcquisitionMetadata(conditions: CalibrationRecordingConditions()))
        let prepared = try mask.map {
            try PreparedAnalysisMask(timeline: MaskTimeline($0), scope: .allEligible)
        }
        let inputURL = mediaURL
        let recipe = profile
        let origin = source.origin
        let mappedFileStart = fileStart
        let mappedCount = interval.sampleCount
        let selectedMetrics = metrics
        func collect<Sample: BinaryFloatingPoint & Sendable>(_: Sample.Type) throws
            -> (CalibrationDecoderProvenance, [ScheduledMetric: [ScheduledMeasurementExport]])
        {
            let worker = try PreparedAudioFileSchedule<Sample>(
                url: inputURL, profile: recipe, origin: origin,
                fileStartSample: mappedFileStart, sampleCount: mappedCount,
                chunkCapacity: 127, sourceTileCapacity: 128, mask: prepared,
                maskRouting: .singleContinuityRegion)
            var values: [ScheduledMetric: [ScheduledMeasurementExport]] = [:]
            var failed: (any Error)?
            while worker.completion == nil {
                try worker.read { output in
                    for metric in selectedMetrics {
                        let algorithm: ScheduledAlgorithm
                        switch metric {
                        case .fundamentalFrequency, .trackedFundamentalFrequency: algorithm = .yin
                        case .cpp, .cpps: algorithm = .cpps
                        default: algorithm = .levels
                        }
                        if output.frame.algorithm == algorithm {
                            do {
                                values[metric, default: []].append(try output.frame.export(metric))
                            } catch { failed = error }
                        }
                    }
                }
            }
            if let failed { throw failed }
            return (try CalibrationDecoderProvenance(worker.decoding), values)
        }
        (decoder, expected) = try precision == .float32 ? collect(Float.self) : collect(Double.self)
    }

    func archive(
        directory: URL, decoder alternate: CalibrationDecoderProvenance? = nil,
        media alternateMedia: Data? = nil, embedded: Bool = true,
        completion: SessionArchiveCompletion = .completed, gapBeforePlan: Bool? = nil
    ) throws -> URL {
        let url = directory.appendingPathComponent("archive-\(UUID()).hvps")
        let bytes = alternateMedia ?? original
        let reference = try SessionArchiveMediaReference(
            media: CalibrationMediaReference(
                referenceIdentifier: "synthetic-wave", originalRecordingID: UUID(),
                content: CalibrationDigest(bytes: bytes), byteCount: Int64(bytes.count)),
            decoder: alternate ?? decoder, inclusion: embedded ? .embedded : .omitted,
            provenance: VersionedIdentifier(name: "synthetic-PCM16", version: 1),
            mappings: [
                SessionArchiveMediaMapping(
                    sourceIndex: 0, source: interval, fileStartSample: fileStart)
            ])
        try SessionArchiveFiles.write(
            to: url, header: sessionFileTestHeader(audio: embedded), limits: SessionArchiveLimits(),
            completion: completion
        ) { writer in
            try writer.addProfile(.schedule(profile))
            try writer.addSource(source)
            for metric in metrics {
                let values = try #require(expected[metric])
                let first = try #require(values.first)
                let series = try SessionArchiveSeries(
                    profileIndex: 0, sourceIndex: 0, measurement: first.result.measurement,
                    clock: .secondsFromOrigin, isScheduled: true,
                    mask: first.mask.map(SessionArchiveMask.init))
                let index = try writer.addSeries(series)
                for value in values { try writer.append(value, to: index) }
            }
            let gap: SessionArchiveGap?
            if gapBeforePlan != nil {
                let missing = try SourceInterval(
                    epoch: interval.epoch, startSample: interval.endSample,
                    sampleCount: 8, sampleRate: interval.sampleRate)
                try writer.addSource(
                    SessionArchiveSource(
                        origin: AnalysisScheduleOrigin(
                            source: SourceInterval(
                                epoch: interval.epoch, startSample: missing.endSample,
                                sampleCount: 0, sampleRate: interval.sampleRate),
                            continuityEpoch: source.origin.continuityEpoch.successor()),
                        acquisition: source.acquisition))
                gap = try SessionArchiveGap(
                    previousSourceIndex: 0, nextSourceIndex: 1, observedSource: interval,
                    dispatchedSourceSamples: interval.sampleCount - 8,
                    pendingSourceSamplesDiscarded: 8, missingSource: missing, reason: .droppedAudio)
            } else {
                gap = nil
            }
            try writer.addMediaReference(reference)
            if embedded {
                if alternateMedia == nil {
                    // The reference is already registered for the following plans.
                    for offset in stride(
                        from: 0, to: bytes.count, by: writer.maximumMediaChunkBytes)
                    {
                        try writer.appendMedia(
                            Data(bytes.dropFirst(offset).prefix(writer.maximumMediaChunkBytes)),
                            to: 0)
                    }
                } else {
                    try writer.appendMedia(bytes, to: 0)
                }
            }
            if gapBeforePlan == true, let gap { try writer.append(gap) }
            for index in metrics.indices {
                try writer.addReplayPlan(
                    SessionArchiveReplayPlan(
                        seriesIndex: UInt32(index), mediaReferenceIndex: 0, mappingIndex: 0,
                        mask: mask))
            }
            if gapBeforePlan == false, let gap { try writer.append(gap) }
        }
        return url
    }
}

@Test func sessionAudioReplayStopsAtArchivedGapInEitherRecordOrder() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SessionAudioReplayFixture(directory: directory)
    for gapFirst in [false, true] {
        let url = try fixture.archive(directory: directory, gapBeforePlan: gapFirst)
        var values: [ScheduledMeasurementExport] = []
        let result = try SessionArchiveAudioReplay.run(
            at: url, planIndex: 0, scratchDirectory: directory,
            archiveLimits: SessionArchiveLimits(),
            replayLimits: SessionArchiveReplayLimits(
                decodedChunkCapacity: 251, sourceTileCapacity: 128)
        ) { values.append($0) }
        #expect(values == fixture.expected[.rms])
        #expect(result.source == fixture.interval)
        #expect(result.decodedSamples == fixture.interval.sampleCount)
        #expect(
            values.allSatisfy { $0.result.timing.source.endSample <= fixture.interval.endSample })
        try expectNoSessionStage(directory)
    }
}

private func expectNoSessionStage(_ directory: URL) throws {
    #expect(
        try !FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains(where: { $0.hasPrefix(".hdxl-session-") }))
}

@Test func sessionAudioReplayMatchesOriginalAcrossPrecisionsLayoutsAndExactSourceClocks() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for precision in [AnalysisPrecision.float32, .float64] {
        for layout in [PCMLayout.planar, .interleaved] {
            let fixture = try SessionAudioReplayFixture(
                directory: directory, precision: precision, layout: layout)
            let url = try fixture.archive(directory: directory)
            var values: [ScheduledMeasurementExport] = []
            let result = try SessionArchiveAudioReplay.run(
                at: url, planIndex: 0, scratchDirectory: directory,
                archiveLimits: SessionArchiveLimits(),
                replayLimits: SessionArchiveReplayLimits(
                    decodedChunkCapacity: 251, sourceTileCapacity: 128)
            ) { values.append($0) }
            #expect(values == fixture.expected[.rms])
            #expect(result.source == fixture.interval && result.source.startSample > (1 << 54))
            #expect(result.decodedSamples == fixture.interval.sampleCount)
            #expect(result.emittedMeasurements == UInt64(values.count) && !values.isEmpty)
            #expect(
                result.maximumDecodedChunkSamples <= 251 && result.maximumPreparedBufferBytes > 0)
            #expect(
                result.actualDecoder == fixture.decoder && result.originalDecoder == fixture.decoder
            )
            #expect(try result.profile == fixture.profile.identity())
            try expectNoSessionStage(directory)
        }
    }
}

@Test func sessionAudioReplaySelectsEverySupportedMetricAndPreservesPinnedRecipe() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SessionAudioReplayFixture(directory: directory, allMetrics: true)
    let url = try fixture.archive(directory: directory)
    for (index, metric) in fixture.metrics.enumerated() {
        var values: [ScheduledMeasurementExport] = []
        let result = try SessionArchiveAudioReplay.run(
            at: url, planIndex: UInt32(index), scratchDirectory: directory,
            archiveLimits: SessionArchiveLimits(),
            replayLimits: SessionArchiveReplayLimits(
                decodedChunkCapacity: 313, sourceTileCapacity: 128)
        ) { values.append($0) }
        #expect(values == fixture.expected[metric])
        #expect(!values.isEmpty && result.seriesIndex == UInt32(index))
        #expect(result.profile == values.first?.result.profile)
    }
    try expectNoSessionStage(directory)
}

@Test func sessionAudioReplayPreservesFullMaskForOneContinuityRegionAndReportsNewRuntime() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SessionAudioReplayFixture(directory: directory, masked: true)
    let claimed = try CalibrationDecoderProvenance(
        identifier: fixture.decoder.identifier, runtime: "original-device-runtime",
        storage: fixture.decoder.storage, decodedPCM: fixture.decoder.decodedPCM,
        fileSampleCount: fixture.decoder.fileSampleCount)
    let url = try fixture.archive(directory: directory, decoder: claimed, completion: .partial)
    var values: [ScheduledMeasurementExport] = []
    let result = try SessionArchiveAudioReplay.run(
        at: url, planIndex: 0, scratchDirectory: directory, archiveLimits: SessionArchiveLimits(),
        replayLimits: SessionArchiveReplayLimits(decodedChunkCapacity: 63, sourceTileCapacity: 128)
    ) { values.append($0) }
    #expect(values == fixture.expected[.rms])
    #expect(values.allSatisfy { $0.mask != nil && $0.origin == fixture.source.origin })
    #expect(result.originalDecoder == claimed && result.actualDecoder == fixture.decoder)
    #expect(result.sessionCompletion == .partial && result.source == fixture.interval)
    try expectNoSessionStage(directory)
}

@Test func sessionAudioReplayRejectsMissingFalseOrUndecodableMediaBeforeEmitting() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SessionAudioReplayFixture(directory: directory)
    let missing = try fixture.archive(directory: directory, embedded: false)
    #expect(throws: SessionArchiveError.missingMedia) {
        try SessionArchiveAudioReplay.run(
            at: missing, planIndex: 0, scratchDirectory: directory,
            archiveLimits: SessionArchiveLimits(), replayLimits: SessionArchiveReplayLimits()
        ) { _ in Issue.record("Audio-free archives cannot be replayed") }
    }
    for changed in [
        try CalibrationDecoderProvenance(
            identifier: "unknown-decoder", runtime: fixture.decoder.runtime,
            storage: fixture.decoder.storage, decodedPCM: fixture.decoder.decodedPCM,
            fileSampleCount: fixture.decoder.fileSampleCount),
        try CalibrationDecoderProvenance(
            identifier: fixture.decoder.identifier, runtime: fixture.decoder.runtime,
            storage: ["container": .text("false-format")], decodedPCM: fixture.decoder.decodedPCM,
            fileSampleCount: fixture.decoder.fileSampleCount),
        try CalibrationDecoderProvenance(
            identifier: fixture.decoder.identifier, runtime: fixture.decoder.runtime,
            storage: fixture.decoder.storage, decodedPCM: fixture.decoder.decodedPCM,
            fileSampleCount: fixture.decoder.fileSampleCount + 1),
    ] {
        let url = try fixture.archive(directory: directory, decoder: changed)
        #expect(throws: SessionArchiveError.incompatibleMedia) {
            try SessionArchiveAudioReplay.run(
                at: url, planIndex: 0, scratchDirectory: directory,
                archiveLimits: SessionArchiveLimits(), replayLimits: SessionArchiveReplayLimits()
            ) { _ in Issue.record("False decoder provenance cannot be replayed") }
        }
    }
    let garbage = try fixture.archive(directory: directory, media: Data("not-audio".utf8))
    #expect(throws: SessionArchiveError.incompatibleMedia) {
        try SessionArchiveAudioReplay.run(
            at: garbage, planIndex: 0, scratchDirectory: directory,
            archiveLimits: SessionArchiveLimits(), replayLimits: SessionArchiveReplayLimits()
        ) { _ in Issue.record("Hash integrity is not proof of an audio container") }
    }
    try expectNoSessionStage(directory)
}

@Test func sessionAudioReplayCancellationExpansionLimitsAndCallbackFailuresCleanUp() throws {
    let directory = try sessionFileTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SessionAudioReplayFixture(directory: directory)
    let url = try fixture.archive(directory: directory)
    var keepGoing = true
    var emitted = 0
    #expect(throws: SessionArchiveError.cancelled) {
        try SessionArchiveAudioReplay.run(
            at: url, planIndex: 0, scratchDirectory: directory,
            archiveLimits: SessionArchiveLimits(), replayLimits: SessionArchiveReplayLimits(),
            shouldContinue: { keepGoing },
            emit: { _ in
                emitted += 1
                keepGoing = false
            })
    }
    #expect(emitted == 1)
    #expect(throws: SessionArchiveError.analysisFailure) {
        try SessionArchiveAudioReplay.run(
            at: url, planIndex: 0, scratchDirectory: directory,
            archiveLimits: SessionArchiveLimits(), replayLimits: SessionArchiveReplayLimits()
        ) { _ in throw NSError(domain: "private-details", code: 1) }
    }
    for limits in [
        try SessionArchiveReplayLimits(maximumSourceSamples: fixture.interval.sampleCount - 1),
        try SessionArchiveReplayLimits(maximumSourceSeconds: 0.001),
    ] {
        #expect(throws: SessionArchiveError.sizeLimitExceeded) {
            try SessionArchiveAudioReplay.run(
                at: url, planIndex: 0, scratchDirectory: directory,
                archiveLimits: SessionArchiveLimits(), replayLimits: limits
            ) { _ in Issue.record("Expansion limits must precede analysis") }
        }
    }
    try expectNoSessionStage(directory)
}
