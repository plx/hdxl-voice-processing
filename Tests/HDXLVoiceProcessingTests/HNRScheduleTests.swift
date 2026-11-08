import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func hnrScheduleOrigin(rate: Int, sequence: UInt64 = 0, start: Int64 = (1 << 54) + 39)
    throws -> AnalysisScheduleOrigin
{
    let epoch = StreamEpoch(streamID: UUID(uuidString: "0480BFCA-9D9E-4BA3-B4AD-000000000039")!)
    return try AnalysisScheduleOrigin(
        source: SourceInterval(
            epoch: epoch, startSample: start,
            sampleCount: 0, sampleRate: Double(rate)),
        continuityEpoch: StreamEpoch(streamID: epoch.streamID, sequence: sequence),
        sourceStartSeconds: 12.5, hostStartNanoseconds: 1_000_000_000,
        wallClockStartUnixSeconds: 1000)
}

private func hnrScheduled<Sample: BinaryFloatingPoint & Sendable>(
    _ pcm: [Sample],
    configuration: HNRConfiguration, origin: AnalysisScheduleOrigin, mode: AnalysisScheduleMode,
    chunks: [Int]
) throws -> ([ScheduledFrame], AnalysisScheduleCompletion) {
    let profile = try AnalysisScheduleProfile(
        inputFormat: PCMFormat(
            sampleRate: Double(configuration.sampleRate), channelCount: 2,
            encoding: configuration.inputPrecision == .float32 ? .float32 : .float64),
        channels: PCMChannelSelection(channelIndex: 1), hnr: configuration)
    let worker = try PreparedAnalysisSchedule<Sample>(
        profile: profile, origin: origin, mode: mode,
        expectedSampleCount: mode == .finite ? Int64(pcm.count) : nil, sourceTileCapacity: 61)
    let bytes = worker.preparedBufferBytes
    let input = pcm.flatMap { [Sample(0.23), $0] }
    var frames: [ScheduledFrame] = []
    var offset = 0
    var iteration = 0
    try input.withUnsafeBufferPointer { samples in
        while offset < pcm.count {
            let count = min(chunks[iteration % chunks.count], pcm.count - offset)
            let source = try SourceInterval(
                epoch: origin.source.epoch,
                startSample: origin.source.startSample + Int64(offset), sampleCount: Int64(count),
                sampleRate: origin.source.sampleRate)
            let report = try worker.processInterleaved(
                UnsafeBufferPointer(rebasing: samples[2 * offset..<2 * (offset + count)]),
                interval: source
            ) { frames.append($0) }
            #expect(report.consumedSourceSamples == count && !report.isCancelled)
            offset += count
            iteration += 1
        }
    }
    if configuration.normalization == .wholeInterval { #expect(frames.isEmpty) }
    let result = try worker.finish { frames.append($0) }
    #expect(worker.preparedBufferBytes == bytes)
    #expect(
        try worker.finish { _ in Issue.record("Repeated HNR schedule finish emitted") } == result)
    return (frames, result)
}

private func hnrCompareSchedule<Sample: BinaryFloatingPoint & Sendable>(
    _ pcm: [Sample],
    configuration c: HNRConfiguration
) throws {
    let origin = try hnrScheduleOrigin(rate: c.sampleRate)
    let batch = try hnrScheduled(
        pcm, configuration: c, origin: origin, mode: .finite, chunks: [pcm.count])
    let chunks = try hnrScheduled(
        pcm, configuration: c, origin: origin, mode: .finite, chunks: [1, 7, 83, 3])
    #expect(batch.0 == chunks.0 && batch.1 == chunks.1)
    let local = try SourceInterval(
        epoch: origin.continuityEpoch, startSample: 0,
        sampleCount: Int64(pcm.count), sampleRate: origin.source.sampleRate)
    var direct: [HNRAnalysisResult] = []
    if c.normalization == .causalWindow {
        let stream = try hnrScheduled(
            pcm, configuration: c, origin: origin, mode: .continuous, chunks: [19, 2, 41])
        #expect(stream.0 == batch.0 && stream.1 == batch.1)
        let native = try PreparedHNRStream<Sample>(configuration: c, epoch: local.epoch)
        try pcm.withUnsafeBufferPointer {
            try native.process($0, interval: local) { direct.append($0.frame.result) }
        }
        let completion = try native.finish { direct.append($0.frame.result) }
        #expect(batch.1.hnrStream == completion && batch.1.hnrInterval == nil)
    } else {
        let native = try PreparedIntervalHNR<Sample>(
            configuration: c,
            timing: AnalysisTiming(source: local, includedSampleCount: local.sampleCount))
        try pcm.withUnsafeBufferPointer { try native.append($0, interval: local) }
        let completion = try native.finish { direct.append($0.result) }
        #expect(batch.1.hnrInterval == completion && batch.1.hnrStream == nil)
    }
    #expect(batch.0.count == direct.count && !direct.isEmpty)
    for (scheduled, native) in zip(batch.0, direct) {
        #expect(scheduled.value == .hnr(native) && scheduled.algorithm == .hnr)
        #expect(scheduled.frameCenterSecondsFromOrigin == native.centerSourceSeconds)
        #expect(try scheduled.timing == origin.mappedTiming(native.dependencyTiming))
        let exported = try scheduled.export(.harmonicToNoiseRatio)
        #expect(try exported.result.outcome == native.measurementResult().outcome)
        #expect(exported.result.profile == scheduled.schedule)
        #expect(exported.frameCenterSecondsFromOrigin == scheduled.frameCenterSecondsFromOrigin)
        #expect(exported.dependencyTiming == scheduled.timing)
        #expect(exported.dependencyCoverage.source == scheduled.timing.source.sampleCount)
    }
}

@Test func hnrScheduleMatchesDirectKernelsAcrossMethodsPrecisionModesAndChunks() throws {
    for method in HNRMethod.allCases {
        for normalization in [HNRNormalizationDefinition.wholeInterval, .causalWindow] {
            for precision in [AnalysisPrecision.float32, .float64] {
                let c = try HNRConfiguration(
                    method: method, sampleRate: 44100, inputPrecision: precision,
                    pitchFloorHz: 500, periodsPerWindow: 2, hopSeconds: 0.005,
                    normalization: normalization)
                let pcm = (0..<4 * c.causalWindowSampleCount + 37).map {
                    0.3 * sin(Double($0) * 2 * .pi * 631 / 44100) + 0.02
                        * cos(Double($0) * 2 * .pi * 2271 / 44100)
                }
                if precision == .float32 {
                    try hnrCompareSchedule(pcm.map(Float.init), configuration: c)
                } else {
                    try hnrCompareSchedule(pcm, configuration: c)
                }
            }
        }
    }
}

@Test func hnrScheduleProfileContractsAndEmptyIntervalsRemainExplicit() throws {
    let format = try PCMFormat(sampleRate: 4000, channelCount: 1, encoding: .float64)
    for normalization in [HNRNormalizationDefinition.wholeInterval, .causalWindow] {
        let c = try HNRConfiguration(
            method: .autocorrelation, sampleRate: 4000,
            pitchFloorHz: 500, periodsPerWindow: 2, normalization: normalization)
        let p = try AnalysisScheduleProfile(inputFormat: format, channels: .arithmeticMean, hnr: c)
        #expect(
            try JSONDecoder().decode(AnalysisScheduleProfile.self, from: canonicalContractJSON(p))
                == p)
        let requirement = try #require(p.requirements().first)
        #expect(
            requirement.algorithm == .hnr
                && requirement.requiresCompleteInterval == (normalization == .wholeInterval))
        #expect(
            requirement.placement
                == (normalization == .wholeInterval
                    ? .centeredCompleteInterval : .leftAlignedFractionalGrid))
        if normalization == .wholeInterval {
            #expect(throws: AnalysisScheduleError.unsupportedLiveProfile) {
                try p.validate(mode: .continuous)
            }
        } else {
            try p.validate(mode: .continuous)
        }
        let worker = try PreparedAnalysisSchedule<Double>(
            profile: p,
            origin: hnrScheduleOrigin(rate: 4000), mode: .finite, expectedSampleCount: 0)
        var outputs: [ScheduledFrame] = []
        let completion = try worker.finish { outputs.append($0) }
        if normalization == .wholeInterval {
            #expect(
                outputs.count == 1 && completion.hnrInterval?.unavailability == .insufficientData)
            #expect(
                try outputs[0].measurementResult(.harmonicToNoiseRatio).outcome
                    == .unavailable(.insufficientData))
        } else {
            #expect(outputs.isEmpty && completion.hnrStream?.framing.disposition == .empty)
        }
    }
    #expect(throws: AnalysisScheduleError.invalidConfiguration) {
        try AnalysisScheduleProfile(
            inputFormat: format, channels: .arithmeticMean,
            hnr: HNRConfiguration(method: .autocorrelation, sampleRate: 16000))
    }
    #expect(throws: AnalysisScheduleError.invalidConfiguration) {
        try AnalysisScheduleProfile(
            inputFormat: format, channels: .arithmeticMean,
            hnr: HNRConfiguration(
                method: .autocorrelation, sampleRate: 4000, inputPrecision: .float32))
    }
}

@Test func hnrDirectAndScheduledClocksUseNearestEvenNanoseconds() throws {
    let c = try HNRConfiguration(
        method: .forwardCrossCorrelation, sampleRate: 128000,
        pitchFloorHz: 16000, periodsPerWindow: 2, hopSeconds: 1.0 / 128000,
        normalization: .causalWindow)
    let origin = try hnrScheduleOrigin(rate: c.sampleRate, start: 0)
    let worker = try PreparedHNRStream<Double>(
        configuration: c,
        origin: AnalysisTiming(
            source: origin.source, includedSampleCount: 0,
            sourceStartSeconds: origin.sourceStartSeconds,
            hostStartNanoseconds: origin.hostStartNanoseconds))
    let pcm = Array(repeating: 0.0, count: c.causalWindowSampleCount + 3)
    let interval = try SourceInterval(
        epoch: origin.source.epoch, startSample: 0,
        sampleCount: Int64(pcm.count), sampleRate: Double(c.sampleRate))
    var times: [UInt64?] = []
    try pcm.withUnsafeBufferPointer {
        try worker.process($0, interval: interval) {
            times.append($0.frame.result.dependencyTiming.hostStartNanoseconds)
        }
    }
    try worker.finish { times.append($0.frame.result.dependencyTiming.hostStartNanoseconds) }
    let expected: [UInt64?] = [
        1_000_000_000, 1_000_007_812, 1_000_015_625, 1_000_023_438, 1_000_031_250,
    ]
    #expect(times == expected)
    let scheduled = try hnrScheduled(
        pcm, configuration: c, origin: origin, mode: .continuous, chunks: [1, 3, 7])
    #expect(scheduled.0.map(\.timing.hostStartNanoseconds) == expected)
}

@Test func hnrScheduleCancellationAndResetPreserveLifecycleAndRejectOversizedReplacement() throws {
    for normalization in [HNRNormalizationDefinition.wholeInterval, .causalWindow] {
        let c = try HNRConfiguration(
            method: .forwardCrossCorrelation, sampleRate: 4000,
            pitchFloorHz: 500, periodsPerWindow: 2, normalization: normalization)
        let profile = try AnalysisScheduleProfile(
            inputFormat: PCMFormat(sampleRate: 4000, channelCount: 1, encoding: .float64),
            channels: .arithmeticMean, hnr: c)
        let origin = try hnrScheduleOrigin(rate: 4000)
        let worker = try PreparedAnalysisSchedule<Double>(
            profile: profile, origin: origin,
            mode: .finite, expectedSampleCount: 200, sourceTileCapacity: 31)
        let source = try SourceInterval(
            epoch: origin.source.epoch, startSample: origin.source.startSample,
            sampleCount: 200, sampleRate: 4000)
        var callbacks = 0
        func cancel(_ frame: ScheduledFrame) {
            callbacks += 1
            #expect(frame.algorithm == .hnr)
            #expect(throws: AnalysisScheduleError.reentrantCall) { try worker.finish { _ in } }
            worker.cancel()
        }
        let process = try Array(repeating: 0.0, count: 200).withUnsafeBufferPointer {
            try worker.processInterleaved($0, interval: source, emit: cancel)
        }
        if normalization == .wholeInterval {
            #expect(callbacks == 0 && !process.isCancelled)
            let result = try worker.finish(emit: cancel)
            #expect(result.isCancelled && result.hnrInterval?.isCancelled == true)
            #expect(result.hnrInterval?.emittedSlotCount == 1)
        } else {
            #expect(process.isCancelled && process.consumedSourceSamples == 31)
        }
        #expect(callbacks == 1 && worker.preparedBufferBytes == 0)
        let next = try hnrScheduleOrigin(
            rate: 4000, sequence: 1, start: origin.source.startSample + 200)
        if normalization == .wholeInterval {
            #expect(throws: HNRError.unexpectedContext) {
                try worker.reset(
                    origin: next,
                    expectedSampleCount: Int64(HNRConfiguration.maximumIntervalSampleCount) + 1,
                    reason: .explicitReset)
            }
            #expect(
                worker.origin == origin && worker.isCancelled && worker.preparedBufferBytes == 0)
        }
        try worker.reset(origin: next, expectedSampleCount: 200, reason: .explicitReset)
        var frames: [ScheduledFrame] = []
        let resumed = try SourceInterval(
            epoch: next.source.epoch, startSample: next.source.startSample,
            sampleCount: 200, sampleRate: 4000)
        try Array(repeating: 0.0, count: 200).withUnsafeBufferPointer {
            try worker.processInterleaved($0, interval: resumed) { frames.append($0) }
        }
        let completion = try worker.finish { frames.append($0) }
        #expect(!completion.isCancelled && !frames.isEmpty)
        #expect(
            frames.allSatisfy {
                $0.origin == next && $0.timing.source.startSample >= next.source.startSample
            })
        #expect(completion.observedSource == resumed)
    }
}

@Test func hnrMaskedScheduleKeepsRegionsIndependentAndMapsOfflineReports() throws {
    let origin = try hnrScheduleOrigin(rate: 4000)
    func source(_ start: Int64, _ count: Int64) throws -> SourceInterval {
        try SourceInterval(
            epoch: origin.source.epoch, startSample: origin.source.startSample + start,
            sampleCount: count, sampleRate: 4000)
    }
    let provenance = try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "hnr-schedule-selections", version: 1))
    let policy = try MaskSelectionPolicy(selectionSources: [0])
    let timeline = try MaskTimeline(
        MaskPlan(
            source: source(0, 800), provenances: [provenance], policy: policy,
            observations: [
                MaskObservation(source: source(0, 200), provenanceIndex: 0, selection: .selected),
                MaskObservation(source: source(400, 200), provenanceIndex: 0, selection: .selected),
                MaskObservation(
                    source: source(300, 100), provenanceIndex: 0, tags: [.missingAcquisition]),
            ]))
    for normalization in [HNRNormalizationDefinition.wholeInterval, .causalWindow] {
        let c = try HNRConfiguration(
            method: .forwardCrossCorrelation, sampleRate: 4000,
            pitchFloorHz: 500, periodsPerWindow: 2, normalization: normalization)
        let profile = try AnalysisScheduleProfile(
            inputFormat: PCMFormat(
                sampleRate: 4000, channelCount: 1,
                encoding: .float64), channels: .arithmeticMean, hnr: c)
        for scope in [MaskAnalysisScope.selected, .allEligible] {
            let mask = try PreparedAnalysisMask(timeline: timeline, scope: scope)
            let worker = try PreparedMaskedAnalysisSchedule<Double>(
                profile: profile, origin: origin,
                mode: .finite, mask: mask, sourceTileCapacity: 31)
            var frames: [ScheduledFrame] = []
            var regions: [AnalysisScheduleCompletion] = []
            for (start, count) in [(0, 300), (400, 400)] {
                if start == 400 { try worker.skipMissingAcquisition(source(300, 100)) }
                let values = (start..<start + count).map {
                    0.3 * sin(Double($0) * 2 * .pi / 7) + 0.04 * cos(Double($0) * 2 * .pi / 3.2)
                }
                try values.withUnsafeBufferPointer {
                    try worker.processInterleaved(
                        $0, interval: source(Int64(start), Int64(count)),
                        emit: { frames.append($0) }, regionCompleted: { regions.append($0) })
                }
            }
            let completion = try worker.finish()
            let expected = scope == .selected ? timeline.selectedRegions : timeline.eligibleRegions
            #expect(
                regions.map(\.observedSource) == expected && completion.completedRegionCount == 2)
            #expect(completion.coverage.missing == 100 && completion.coverage.selected == 400)
            for frame in frames {
                #expect(try timeline.eligibleRegion(containing: frame.timing.source) != nil)
                if scope == .selected {
                    #expect(try timeline.selectedRegion(containing: frame.timing.source) != nil)
                }
                #expect(frame.mask == mask.provenance)
            }
            if normalization == .wholeInterval && scope == .selected {
                let statistic = try HNRStatisticProfile(
                    measurement: c, population: .voiceOnly,
                    selection: policy, provenances: [provenance])
                let report = try HNRRegionReport(
                    profile: statistic, timeline: timeline, scheduledRegions: regions)
                #expect(report.regions.map(\.source) == expected && report.meanDB != nil)
                #expect(
                    report.availableFrameCount
                        == frames.filter {
                            guard case .hnr(.frame(let value)) = $0.value else { return false }
                            return value.selectedObservation != nil
                        }.count)
            }
        }
    }
}
