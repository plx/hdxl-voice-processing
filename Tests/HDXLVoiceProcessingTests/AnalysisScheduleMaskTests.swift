import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let schedulingMaskEpoch = StreamEpoch(
    streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000140")!)

private func schedulingMaskSource(_ start: Int64, _ count: Int64) throws -> SourceInterval {
    try SourceInterval(
        epoch: schedulingMaskEpoch, startSample: start,
        sampleCount: count, sampleRate: 16000)
}

private func schedulingMaskFixture(scope: MaskAnalysisScope) throws -> PreparedAnalysisMask {
    let evidence = try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "scheduler-test-annotation", version: 1))
    return try PreparedAnalysisMask(
        timeline: MaskTimeline(
            MaskPlan(
                source: schedulingMaskSource(100, 1200), provenances: [evidence],
                policy: MaskSelectionPolicy(selectionSources: [0]),
                observations: [
                    MaskObservation(
                        source: schedulingMaskSource(100, 1200), provenanceIndex: 0,
                        tags: [.speechDetected, .lowPeriodicityConfidence]),
                    MaskObservation(
                        source: schedulingMaskSource(100, 400), provenanceIndex: 0,
                        selection: .selected),
                    MaskObservation(
                        source: schedulingMaskSource(700, 400), provenanceIndex: 0,
                        selection: .selected),
                    MaskObservation(
                        source: schedulingMaskSource(600, 100), provenanceIndex: 0,
                        tags: [.missingAcquisition]),
                    MaskObservation(
                        source: schedulingMaskSource(300, 500), provenanceIndex: 0,
                        tags: [.clipping]),
                ], effectiveDelaySeconds: 0.1)), scope: scope)
}

private func schedulingMaskProfile(layout: PCMLayout = .interleaved) throws
    -> AnalysisScheduleProfile
{
    try AnalysisScheduleProfile(
        inputFormat: PCMFormat(
            sampleRate: 16000, channelCount: 1,
            encoding: .float64, layout: layout), channels: PCMChannelSelection(channelIndex: 0),
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64,
            windowLength: 600, hopLength: 200, accumulation: .compensatedSliding, weighting: .none),
        pitch: YINProfile(
            estimator: YINConfiguration(
                sampleRate: 16000, inputPrecision: .float64,
                pitchFloorHz: 50, pitchCeilingHz: 700, hopLength: 200)))
}

private func schedulingMaskOrigin() throws -> AnalysisScheduleOrigin {
    try AnalysisScheduleOrigin(
        source: schedulingMaskSource(100, 0),
        continuityEpoch: schedulingMaskEpoch, sourceStartSeconds: 4,
        hostStartNanoseconds: 10_000_000_000, wallClockStartUnixSeconds: 1_000)
}

@Test func schedulingCoveragePrefixMatchesIndependentIntervalIntersections() throws {
    let mask = try schedulingMaskFixture(scope: .selected)
    var seed: UInt64 = 40
    for _ in 0..<120 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let start = 100 + Int64((seed >> 32) % 1201)
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let count = Int64((seed >> 32) % UInt64(1301 - start))
        let source = try schedulingMaskSource(start, count)
        let result = try mask.coverage(of: source)
        var eligible: Int64 = 0
        var selected: Int64 = 0
        var tags: [MaskTag: Int64] = [:]
        for segment in mask.timeline.segments {
            let n = max(
                0,
                min(source.endSample, segment.source.endSample)
                    - max(source.startSample, segment.source.startSample))
            if segment.isEligible { eligible += n }
            if segment.isSelected { selected += n }
            for tag in segment.tags { tags[tag, default: 0] += n }
        }
        #expect(result.source == count)
        #expect(result.eligible == eligible)
        #expect(result.selected == selected)
        #expect(result.missing + result.eligible == count)
        #expect(result.excludedEligible + result.selected == eligible)
        for tag in MaskTag.allCases { #expect(result.samples(tag: tag) == tags[tag, default: 0]) }
    }
    #expect(throws: AnalysisScheduleError.unexpectedInput) {
        try mask.coverage(of: schedulingMaskSource(99, 1))
    }
}

@Test func schedulingSelectedRegionsNeverBridgeAndKeepUnavailablePitchEvidence() throws {
    let mask = try schedulingMaskFixture(scope: .selected)
    let profile = try schedulingMaskProfile()
    let origin = try schedulingMaskOrigin()
    var baseline: [ScheduledFrame] = []
    var baselineRegions: [AnalysisScheduleCompletion] = []
    var baselineCompletion: MaskedScheduleCompletion?
    for chunks in [[500], [1], [31, 7, 89, 2]] {
        let worker = try PreparedMaskedAnalysisSchedule<Double>(
            profile: profile, origin: origin, mode: .finite, mask: mask, sourceTileCapacity: 64)
        let bytes = worker.preparedBufferBytes
        var frames: [ScheduledFrame] = []
        var regions: [AnalysisScheduleCompletion] = []
        for interval in [try schedulingMaskSource(100, 500), try schedulingMaskSource(700, 600)] {
            if interval.startSample == 700 {
                try worker.skipMissingAcquisition(schedulingMaskSource(600, 100))
            }
            var index = 0
            while worker.nextInputSample < interval.endSample {
                let count = min(
                    chunks[index % chunks.count], Int(interval.endSample - worker.nextInputSample))
                let source = try schedulingMaskSource(worker.nextInputSample, Int64(count))
                _ = try Array(repeating: 0.0, count: count).withUnsafeBufferPointer {
                    try worker.processInterleaved(
                        $0, interval: source,
                        emit: { frames.append($0) }, regionCompleted: { regions.append($0) })
                }
                index += 1
            }
        }
        let result = try worker.finish()
        #expect(try worker.finish() == result)
        #expect(worker.preparedBufferBytes == bytes)
        #expect(result.outcome == .completed)
        #expect(result.coverage.source == 1200)
        #expect(result.coverage.eligible == 1100)
        #expect(result.coverage.selected == 800)
        #expect(result.coverage.missing == 100)
        #expect(result.analyzedSampleCount == 800)
        #expect(result.completedRegionCount == 2)
        #expect(regions.map(\.observedSource) == mask.timeline.selectedRegions)
        #expect(Set(frames.map(\.origin.continuityEpoch.sequence)) == Set([0, 1]))
        for frame in frames {
            #expect(try mask.timeline.selectedRegion(containing: frame.timing.source) != nil)
            #expect(frame.coverage.selected == frame.coverage.source)
            #expect(frame.coverage.samples(tag: .speechDetected) == frame.coverage.source)
            #expect(frame.coverage.samples(tag: .lowPeriodicityConfidence) == frame.coverage.source)
            #expect(frame.mask == mask.provenance)
            switch frame.value {
            case .levels(let value): #expect(value.unweighted.energy == nil)
            case .pitch(let raw, _): #expect(raw.observation == nil)
            case .cpps: Issue.record("Unexpected CPPS")
            }
        }
        if baseline.isEmpty {
            baseline = frames
            baselineRegions = regions
            baselineCompletion = result
        } else {
            #expect(frames == baseline)
            #expect(regions == baselineRegions)
            #expect(result == baselineCompletion)
        }
    }
    #expect(!baseline.isEmpty)
}

@Test func schedulingRawPlanarRegionsRetainRejectedSamplesAndExplicitGaps() throws {
    let mask = try schedulingMaskFixture(scope: .allEligible)
    let worker = try PreparedMaskedAnalysisSchedule<Double>(
        profile: schedulingMaskProfile(layout: .planar), origin: schedulingMaskOrigin(),
        mode: .continuous, mask: mask, sourceTileCapacity: 64)
    #expect(throws: AnalysisScheduleError.invalidGap) {
        try worker.skipMissingAcquisition(schedulingMaskSource(100, 1))
    }
    #expect(throws: AnalysisScheduleError.invalidGap) {
        try Array(repeating: 0.0, count: 600).withUnsafeBufferPointer { buffer in
            try [buffer].withUnsafeBufferPointer {
                try worker.processPlanar(
                    $0, interval: schedulingMaskSource(100, 600), emit: { _ in })
            }
        }
    }
    #expect(worker.nextInputSample == 100)
    var frames: [ScheduledFrame] = []
    var completions: [AnalysisScheduleCompletion] = []
    for source in [try schedulingMaskSource(100, 500), try schedulingMaskSource(700, 600)] {
        if source.startSample == 700 {
            try worker.skipMissingAcquisition(schedulingMaskSource(600, 100))
        }
        _ = try Array(repeating: 0.0, count: Int(source.sampleCount)).withUnsafeBufferPointer {
            buffer in
            try [buffer].withUnsafeBufferPointer {
                try worker.processPlanar(
                    $0, interval: source,
                    emit: { frames.append($0) }, regionCompleted: { completions.append($0) })
            }
        }
    }
    let result = try worker.finish()
    #expect(result.analyzedSampleCount == 1100)
    #expect(result.coverage.selected == 800)
    #expect(completions.map(\.observedSource) == mask.timeline.eligibleRegions)
    #expect(frames.contains { $0.coverage.excludedEligible > 0 })
    #expect(frames.allSatisfy { $0.coverage.missing == 0 })
    #expect(
        frames.contains {
            if case .levels(let value) = $0.value { return value.unweighted.energy != nil }
            return false
        })
}

@Test func schedulingMaskedCancellationAndEmptySelectionHaveTypedCompletion() throws {
    let mask = try schedulingMaskFixture(scope: .allEligible)
    let worker = try PreparedMaskedAnalysisSchedule<Double>(
        profile: schedulingMaskProfile(), origin: schedulingMaskOrigin(),
        mode: .finite, mask: mask, sourceTileCapacity: 64)
    var calls = 0
    let report = try Array(repeating: 0.0, count: 500).withUnsafeBufferPointer {
        try worker.processInterleaved($0, interval: schedulingMaskSource(100, 500)) { _ in
            calls += 1
            #expect(throws: AnalysisScheduleError.reentrantCall) { try worker.finish() }
            worker.cancel()
        }
    }
    #expect(calls == 1)
    #expect(report.isCancelled)
    let cancelled = try worker.finish()
    #expect(cancelled.outcome == .cancelled)
    #expect(cancelled.completedRegionCount == 0)

    let empty = try PreparedAnalysisMask(
        timeline: MaskTimeline(
            MaskPlan(
                source: schedulingMaskSource(100, 17), provenances: mask.timeline.plan.provenances,
                policy: MaskSelectionPolicy(selectionSources: [0]), observations: [])),
        scope: .selected)
    let independent = try PreparedMaskedAnalysisSchedule<Double>(
        profile: schedulingMaskProfile(), origin: schedulingMaskOrigin(), mode: .finite, mask: empty
    )
    _ = try Array(repeating: 0.0, count: 17).withUnsafeBufferPointer {
        try independent.processInterleaved($0, interval: schedulingMaskSource(100, 17)) { _ in
            Issue.record("Empty selection emitted analysis")
        }
    }
    let result = try independent.finish()
    #expect(result.outcome == .noSelectedSamples)
    #expect(result.coverage.eligible == 17)
    #expect(result.coverage.selected == 0)
    #expect(result.analyzedSampleCount == 0)
}

@Test func schedulingWeightedExportsRetainFullFilterHistoryCoverage() throws {
    let provenance = try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "weighted-history-test", version: 1))
    let mask = try PreparedAnalysisMask(
        timeline: MaskTimeline(
            MaskPlan(
                source: schedulingMaskSource(100, 12), provenances: [provenance],
                policy: MaskSelectionPolicy(selectionSources: [0]),
                observations: [
                    MaskObservation(
                        source: schedulingMaskSource(104, 8), provenanceIndex: 0,
                        selection: .selected),
                    MaskObservation(
                        source: schedulingMaskSource(100, 4), provenanceIndex: 0, tags: [.clipping]),
                ])), scope: .allEligible)
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(
            sampleRate: 16000, channelCount: 1, encoding: .float64), channels: .arithmeticMean,
        levels: LevelConfiguration(
            sampleRate: 16000, inputPrecision: .float64,
            windowLength: 4, hopLength: 4, accumulation: .compensatedSliding,
            weighting: .bs1770Revision5(warmupSampleCount: 0)))
    #expect(try profile.requirements().first?.history == .continuousCausalHistory)
    let worker = try PreparedAnalysisSchedule<Double>(
        profile: profile, origin: schedulingMaskOrigin(),
        mode: .finite, expectedSampleCount: 12, sourceTileCapacity: 4, mask: mask)
    var frames: [ScheduledFrame] = []
    _ = try Array(repeating: 0.25, count: 12).withUnsafeBufferPointer {
        try worker.processInterleaved($0, interval: schedulingMaskSource(100, 12)) {
            frames.append($0)
        }
    }
    _ = try worker.finish { frames.append($0) }
    let last = try #require(frames.last)
    #expect(last.timing.source == (try schedulingMaskSource(100, 12)))
    #expect(last.frameCenterSecondsFromOrigin == 10.0 / 16000)
    #expect(last.coverage.selected == 8)
    #expect(last.coverage.samples(tag: .clipping) == 4)
    let exported = try last.export(.kWeightedEnergy)
    #expect(exported.result.timing.source == (try schedulingMaskSource(108, 4)))
    #expect(exported.dependencyCoverage == last.coverage)
    #expect(exported.mask == mask.provenance)
}

@Test func schedulingMaskReplayReusesStorageAndStartsFreshContinuity() throws {
    let mask = try schedulingMaskFixture(scope: .selected)
    let worker = try PreparedMaskedAnalysisSchedule<Double>(
        profile: schedulingMaskProfile(), origin: schedulingMaskOrigin(), mode: .finite,
        mask: mask, sourceTileCapacity: 64)
    let bytes = worker.preparedBufferBytes
    var baseline: [ScheduledFrameValue] = []
    for iteration in 0..<3 {
        if iteration > 0 { try worker.resetToStart() }
        var values: [ScheduledFrameValue] = []
        for source in [try schedulingMaskSource(100, 500), try schedulingMaskSource(700, 600)] {
            if source.startSample == 700 {
                try worker.skipMissingAcquisition(schedulingMaskSource(600, 100))
            }
            _ = try Array(repeating: 0.0, count: Int(source.sampleCount)).withUnsafeBufferPointer {
                try worker.processInterleaved($0, interval: source) { frame in
                    #expect(throws: AnalysisScheduleError.reentrantCall) {
                        try worker.resetToStart()
                    }
                    values.append(frame.value)
                }
            }
        }
        let report = try worker.finish()
        #expect(report.completedRegionCount == 2)
        #expect(worker.preparedBufferBytes == bytes)
        #expect(worker.origin.continuityEpoch.sequence == UInt64(iteration * 2))
        // Native metadata has fresh epochs; inspect numerical validity/counts instead.
        if iteration == 0 { baseline = values }
        #expect(values.count == baseline.count)
        #expect(
            values.allSatisfy { value in
                switch value {
                case .levels(let value): value.unweighted.energy == nil
                case .pitch(let raw, _): raw.observation == nil
                case .cpps: false
                }
            })
    }
}
