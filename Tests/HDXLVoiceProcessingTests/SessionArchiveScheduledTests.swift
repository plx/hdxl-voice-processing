import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func sessionScheduledProfile() throws -> AnalysisScheduleProfile {
    try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64,
            windowLength: 400, hopLength: 160, accumulation: .compensatedSliding,
            weighting: .bs1770Revision5(warmupSampleCount: 500)),
        pitch: YINProfile(
            estimator: YINConfiguration(
                sampleRate: 16000, inputPrecision: .float64,
                pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 160),
            tracker: YINTrackerConfiguration()),
        cpps: CPPSProfile(
            cepstrogram: CepstrogramConfiguration(
                sourceSampleRate: 16000, hopSeconds: 0.01, declaredInputBandwidthHz: 8000,
                conditioningMethod: .streamingPreview(lobes: 8, cutoffFraction: 0.9)),
            settings: CPPSConfiguration(
                timeWindowSeconds: 0.02, prominence: CPPConfiguration(fitMethod: .leastSquares))))
}

@Test func sessionScheduledRoundTripPreservesActualKernelExportsAndPopulationEvidence() throws {
    let count = 4001
    let source = try sessionTestSource(start: (1 << 54) + 29)
    let support = try SourceInterval(
        epoch: source.origin.source.epoch, startSample: source.origin.source.startSample,
        sampleCount: Int64(count), sampleRate: 16000)
    let annotation = try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "synthetic-session-annotation", version: 1))
    let mask = try PreparedAnalysisMask(
        timeline: MaskTimeline(
            MaskPlan(
                source: support, provenances: [annotation], policy: MaskSelectionPolicy(),
                observations: [
                    MaskObservation(
                        source: support, provenanceIndex: 0,
                        tags: [.speechDetected, .lowPeriodicityConfidence]),
                    MaskObservation(
                        source: SourceInterval(
                            epoch: support.epoch, startSample: support.startSample + 13,
                            sampleCount: 997, sampleRate: 16000), provenanceIndex: 0,
                        tags: [.clipping, .silence]),
                ], effectiveDelaySeconds: 0.1)), scope: .allEligible)
    let profile = try sessionScheduledProfile()
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: source.origin, mode: .finite,
        expectedSampleCount: Int64(count), sourceTileCapacity: 128, mask: mask)
    let signal = (0..<count).map { 0.3 * sin(2 * .pi * 125 * Double($0) / 16000) }
    var frames: [ScheduledFrame] = []
    _ = try signal.withUnsafeBufferPointer {
        try worker.processInterleaved($0, interval: support) { frames.append($0) }
    }
    _ = try worker.finish { frames.append($0) }
    #expect(!frames.isEmpty)
    var catalog = try SessionArchiveCatalog(limits: SessionArchiveLimits())
    let recipe = SessionArchiveProfile.schedule(profile)
    try catalog.add(recipe, payloadBytes: canonicalContractJSON(recipe).count)
    try catalog.add(source, payloadBytes: canonicalContractJSON(source).count)
    var seriesIndices: [MeasurementDescriptor: UInt32] = [:]
    var hadUnavailable = false
    var hadDistinctCoverage = false
    var hadSharedDependencyStart = false
    var lastDependencyStart: [MeasurementDescriptor: Int64] = [:]
    var metrics: Set<ScheduledMetric> = []
    for frame in frames {
        let requested: [ScheduledMetric]
        switch frame.algorithm {
        case .levels: requested = [.rms, .levelDBFS, .clippingFraction, .kWeightedEnergy]
        case .yin: requested = [.fundamentalFrequency, .trackedFundamentalFrequency]
        case .cpps: requested = [.cpp, .cpps]
        case .hnr: requested = [.harmonicToNoiseRatio]
        }
        for metric in requested {
            metrics.insert(metric)
            let export = try frame.export(metric)
            let series = try SessionArchiveSeries(
                profileIndex: 0, sourceIndex: 0, measurement: export.result.measurement,
                clock: .secondsFromOrigin, isScheduled: true,
                mask: SessionArchiveMask(mask.provenance))
            let index: UInt32
            if let existing = seriesIndices[series.measurement] {
                index = existing
            } else {
                index = try catalog.add(series, payloadBytes: canonicalContractJSON(series).count)
                seriesIndices[series.measurement] = index
                #expect(
                    try decodeSessionMetadata(
                        SessionArchiveSeries.self, from: canonicalContractJSON(series)) == series)
            }
            let value = try SessionArchiveMeasurement(export, source: source, series: series)
            let encoded = try SessionArchiveScalarWire.encode(
                value, seriesIndex: index, catalog: catalog)
            let (decodedIndex, decoded) = try SessionArchiveScalarWire.decode(
                encoded, catalog: catalog)
            #expect(decodedIndex == index && decoded == value)
            #expect(decoded.result == export.result)
            let scheduled = try #require(decoded.scheduled)
            #expect(scheduled.dependencyTiming == export.dependencyTiming)
            #expect(scheduled.frameCenterSecondsFromOrigin == export.frameCenterSecondsFromOrigin)
            #expect(
                scheduled.workerBatchingUpperBoundSeconds == export.workerBatchingUpperBoundSeconds)
            for tag in MaskTag.allCases {
                #expect(
                    scheduled.dependencyCoverage.samples(tag: tag)
                        == export.dependencyCoverage.samples(tag: tag))
            }
            #expect(scheduled.dependencyCoverage.source == export.dependencyCoverage.source)
            #expect(scheduled.dependencyCoverage.eligible == export.dependencyCoverage.eligible)
            #expect(scheduled.dependencyCoverage.selected == export.dependencyCoverage.selected)
            hadDistinctCoverage =
                hadDistinctCoverage
                || scheduled.dependencyTiming.includedSampleCount
                    < scheduled.dependencyCoverage.source
            if case .unavailable = decoded.result.outcome { hadUnavailable = true }
            if lastDependencyStart[series.measurement]
                == scheduled.dependencyTiming.source.startSample
            {
                hadSharedDependencyStart = true
            }
            lastDependencyStart[series.measurement] = scheduled.dependencyTiming.source.startSample
            catalog.accepted(decoded, seriesIndex: index)
        }
    }
    #expect(metrics.count == 8 && seriesIndices.count == 8)
    #expect(hadUnavailable && hadDistinctCoverage && hadSharedDependencyStart)
    #expect(catalog.entryCount == 10)
}

@Test func sessionScheduledRejectsMismatchedContextInsteadOfDroppingIt() throws {
    let source = try sessionTestSource()
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(sampleRate: 16000, channelCount: 1, encoding: .float64),
        channels: .arithmeticMean, levels: sessionTestLevel())
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: source.origin, mode: .finite,
        expectedSampleCount: 400, sourceTileCapacity: 128)
    var frames: [ScheduledFrame] = []
    _ = try Array(repeating: 0.25, count: 400).withUnsafeBufferPointer {
        try worker.processInterleaved(
            $0,
            interval: SourceInterval(
                epoch: source.origin.source.epoch, startSample: 0, sampleCount: 400,
                sampleRate: 16000)
        ) {
            frames.append($0)
        }
    }
    _ = try worker.finish { frames.append($0) }
    let frame = try #require(frames.first)
    let export = try frame.export(.rms)
    let series = try SessionArchiveSeries(
        profileIndex: 0, sourceIndex: 0, measurement: export.result.measurement,
        clock: .secondsFromOrigin, isScheduled: true)
    #expect(throws: SessionArchiveError.invalidMetadata) {
        _ = try SessionArchiveMeasurement(
            export, source: sessionTestSource(start: 1), series: series)
    }
    var catalog = try SessionArchiveCatalog(limits: SessionArchiveLimits())
    let recipe = SessionArchiveProfile.schedule(profile)
    try catalog.add(recipe, payloadBytes: canonicalContractJSON(recipe).count)
    try catalog.add(source, payloadBytes: canonicalContractJSON(source).count)
    #expect(throws: SessionArchiveError.invalidMetadata) {
        try catalog.add(
            SessionArchiveSeries(
                profileIndex: 0, sourceIndex: 0, measurement: series.measurement,
                clock: .sourceSamples), payloadBytes: 1)
    }
    try catalog.add(series, payloadBytes: canonicalContractJSON(series).count)
    let valid = try SessionArchiveMeasurement(export, source: source, series: series)
    let bad = try SessionArchiveMeasurement(
        timestamp: valid.timestamp, result: valid.result,
        scheduled: SessionArchiveScheduledMetadata(
            dependencyTiming: export.dependencyTiming,
            dependencyCoverage: SessionArchiveCoverage(source: 400, eligible: 400, selected: 399),
            frameCenterSecondsFromOrigin: export.frameCenterSecondsFromOrigin,
            workerBatchingUpperBoundSeconds: export.workerBatchingUpperBoundSeconds))
    #expect(throws: SessionArchiveError.invalidMetadata) {
        try catalog.validate(bad, seriesIndex: 0)
    }
}
