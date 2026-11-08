import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let hnrMaskEpoch = StreamEpoch(
    streamID: UUID(uuidString: "F3E1FF82-8253-4F69-98E4-A6715CC98039")!)
private let hnrMaskStart: Int64 = (1 << 54) + 123
private func hnrMaskSource(_ offset: Int64, _ count: Int64) throws -> SourceInterval {
    try SourceInterval(
        epoch: hnrMaskEpoch, startSample: hnrMaskStart + offset,
        sampleCount: count, sampleRate: 4000)
}
private func hnrMaskProvenance(_ kind: MaskSourceKind = .externalAnnotation) throws
    -> MaskProvenance
{
    try MaskProvenance(
        kind: kind, identifier: VersionedIdentifier(name: "hnr-test-selection", version: 1))
}
private func hnrMaskConfiguration(_ normalization: HNRNormalizationDefinition = .wholeInterval)
    throws -> HNRConfiguration
{
    try HNRConfiguration(
        method: .forwardCrossCorrelation, sampleRate: 4000,
        pitchFloorHz: 500, periodsPerWindow: 2, hopSeconds: 0.005, normalization: normalization)
}
private func hnrMaskCompletion(
    _ source: SourceInterval, identity: ProfileIdentity,
    slots: Int, finite: Int, mean: Double?, observed: Int64,
    unity: Int = 0, cancelled: Bool = false
) -> HNRCompletion {
    let available = finite + unity
    return HNRCompletion(
        profile: identity, source: source, completeGridFrameCount: slots,
        emittedSlotCount: slots, availableFrameCount: available,
        unavailableFrameCount: slots - available, finiteDecibelFrameCount: finite,
        reportingLimitFrameCount: unity, numericalZeroNoiseFrameCount: unity,
        lowConfidenceFrameCount: unity, clippedFrameCount: 0,
        observedSampleCount: observed, finiteUncappedMeanDB: mean,
        referencePresentationMeanDB: available == 0
            ? nil
            : ((mean ?? 0) * Double(finite) + 150 * Double(unity)) / Double(available),
        isCancelled: cancelled,
        unavailability: cancelled
            ? .cancelled
            : (unity > 0 ? .unsupportedRange : (available == 0 ? .silence : nil)))
}

@Test func hnrPopulationIdentityRejectsUnknownPoliciesAndUnprovenVoiceLabels() throws {
    let measurement = try hnrMaskConfiguration()
    let external = try hnrMaskProvenance()
    let profile = try HNRStatisticProfile(
        measurement: measurement, population: .voiceOnly,
        selection: MaskSelectionPolicy(selectionSources: [0]), provenances: [external])
    let encoded = try canonicalContractJSON(profile)
    #expect(try JSONDecoder().decode(HNRStatisticProfile.self, from: encoded) == profile)
    let raw = try HNRStatisticProfile(
        measurement: measurement, population: .allEligible,
        selection: MaskSelectionPolicy(), provenances: [external])
    let silence = try HNRStatisticProfile(
        measurement: measurement, population: .silenceExcluded,
        selection: MaskSelectionPolicy(rejectedTags: [.silence]), provenances: [external])
    #expect(try Set([profile.identity(), raw.identity(), silence.identity()]).count == 3)
    for (key, replacement) in [
        ("aggregation", "durationMean"), ("supportPolicy", "frameCenter"),
        ("regionPolicy", "concatenate"), ("unexpected", "field"),
    ] {
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[key] = replacement
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HNRStatisticProfile.self, from: malformed)
        }
    }
    for kind in [
        MaskSourceKind.energyEligibility, .spectralFlatnessSpeechActivity, .algorithmDiagnostics,
    ] {
        #expect(throws: HNRError.invalidConfiguration) {
            try HNRStatisticProfile(
                measurement: measurement, population: .voiceOnly,
                selection: MaskSelectionPolicy(selectionSources: [0]),
                provenances: [hnrMaskProvenance(kind)])
        }
    }
    #expect(throws: HNRError.invalidConfiguration) {
        try HNRStatisticProfile(
            measurement: measurement, population: .allEligible,
            selection: MaskSelectionPolicy(rejectedTags: [.silence]), provenances: [])
    }
    #expect(throws: HNRError.invalidConfiguration) {
        try HNRStatisticProfile(
            measurement: measurement, population: .customSelection,
            selection: MaskSelectionPolicy(selectionSources: [1]), provenances: [external])
    }
}

@Test func hnrRegionMeansUseFramesAndKeepMissingUnavailableUnityAndCancellationSeparate() throws {
    let measurement = try hnrMaskConfiguration()
    let source = try hnrMaskSource(0, 1000)
    let provenance = try hnrMaskProvenance()
    let policy = try MaskSelectionPolicy()
    let timeline = try MaskTimeline(
        MaskPlan(
            source: source, provenances: [provenance], policy: policy,
            observations: [
                MaskObservation(
                    source: hnrMaskSource(200, 100), provenanceIndex: 0, tags: [.missingAcquisition]
                )
            ]))
    let profile = try HNRStatisticProfile(
        measurement: measurement, population: .allEligible,
        selection: policy, provenances: [provenance])
    let identity = try measurement.identity()
    let first = hnrMaskCompletion(
        timeline.selectedRegions[0], identity: identity,
        slots: 3, finite: 2, mean: 5, observed: 150)
    let second = hnrMaskCompletion(
        timeline.selectedRegions[1], identity: identity,
        slots: 2, finite: 1, mean: 20, observed: 500)
    let report = try HNRRegionReport(
        profile: profile, timeline: timeline, regions: [first, second])
    #expect(try #require(report.meanDB) == 10)
    #expect(
        report.availableFrameCount == 3 && report.unavailableFrameCount == 2
            && report.frameCoverage == 0.6)
    #expect(report.observedSampleCount == 650 && report.observedSelectedCoverage == 650.0 / 900)
    #expect(report.timeline.coverage.missingSampleCount == 100)
    #expect(report.pendingRegionCount == 0 && !report.isCancelled)
    let scalar = try report.measurementResult()
    #expect(scalar.timing.source == source && scalar.timing.includedSampleCount == 650)
    #expect(scalar.outcome.estimate?.warnings == [.partialCoverage])
    #expect(throws: HNRError.unexpectedContext) {
        try HNRRegionReport(profile: profile, timeline: timeline, regions: [second, first])
    }
    #expect(throws: HNRError.invalidConfiguration) {
        try HNRRegionReport(profile: profile, timeline: timeline, regions: [first])
    }
    let zero = hnrMaskCompletion(
        second.source, identity: identity, slots: 2, finite: 1,
        mean: 20, observed: 500, unity: 1)
    let unity = try HNRRegionReport(profile: profile, timeline: timeline, regions: [first, zero])
    #expect(unity.finiteUncappedMeanDB == 10 && unity.meanDB == nil)
    #expect(unity.referencePresentationMeanDB == 45 && unity.numericalZeroNoiseFrameCount == 1)
    #expect(unity.unavailability == .unsupportedRange)
    #expect(try unity.measurementResult().outcome == .unavailable(.unsupportedRange))
    let interrupted = hnrMaskCompletion(
        first.source, identity: identity, slots: 1, finite: 1,
        mean: 0, observed: 40, cancelled: true)
    let cancelled = try HNRRegionReport(
        profile: profile, timeline: timeline, regions: [interrupted])
    #expect(cancelled.isCancelled && cancelled.pendingRegionCount == 1 && cancelled.meanDB == nil)
    #expect(cancelled.finiteUncappedMeanDB == 0 && cancelled.observedSampleCount == 40)
    #expect(cancelled.unavailability == .cancelled)
}

@Test func hnrMaskEmptyMissingAndExcludedDoNotBecomeNumericalZero() throws {
    let measurement = try hnrMaskConfiguration()
    let provenance = try hnrMaskProvenance()
    for (count, tag, population, reason) in [
        (
            0, MaskTag.missingAcquisition, HNRPopulation.allEligible,
            UnavailabilityReason.insufficientData
        ),
        (200, .missingAcquisition, .allEligible, .missingAcquisition),
        (200, .silence, .silenceExcluded, .excluded),
    ] {
        let source = try hnrMaskSource(0, Int64(count))
        let policy = try MaskSelectionPolicy(rejectedTags: tag == .silence ? [.silence] : [])
        let timeline = try MaskTimeline(
            MaskPlan(
                source: source, provenances: [provenance], policy: policy,
                observations: count == 0
                    ? [] : [MaskObservation(source: source, provenanceIndex: 0, tags: [tag])]))
        let profile = try HNRStatisticProfile(
            measurement: measurement, population: population,
            selection: policy, provenances: [provenance])
        let report = try HNRRegionReport(profile: profile, timeline: timeline, regions: [])
        #expect(report.meanDB == nil && report.unavailability == reason)
        #expect(report.observedSampleCount == 0 && report.frameCoverage == 0)
        #expect(try report.measurementResult().outcome == .unavailable(reason))
    }
}

@Test func hnrFrameSelectionUsesFullNormalizationDependencyAndPreservesRawObservations() throws {
    let c = try hnrMaskConfiguration()
    let source = try hnrMaskSource(0, 400)
    let timing = try AnalysisTiming(
        source: source, includedSampleCount: source.sampleCount,
        sourceStartSeconds: 123, hostStartNanoseconds: 1_000_000_000,
        completedHostNanoseconds: 2_000_000_000)
    let pcm = (0..<400).map { i in
        1.2 * sin(Double(i) * 2 * .pi / 7) + 0.16 * cos(Double(i) * 2 * .pi / 3.2)
    }
    let analyzer = try PreparedIntervalHNR<Double>(configuration: c, timing: timing)
    try pcm.withUnsafeBufferPointer { try analyzer.append($0, interval: source) }
    var outputs: [HNRFrameResult] = []
    let completion = try analyzer.finish {
        if case .frame(let frame) = $0 { outputs.append(frame.result) }
    }
    #expect(completion.clippedFrameCount > 0)
    #expect(
        completion.clippedFrameCount
            == outputs.filter { $0.selectedObservation != nil && $0.hasClipping }.count)
    #expect(
        completion.lowConfidenceFrameCount
            == outputs.filter {
                guard let value = $0.selectedObservation else { return false }
                return value.periodicity < 0.5 || value.status != .finite
            }.count)
    let raw = try #require(outputs.first { $0.selectedObservation?.finiteDecibels != nil })
    let provenance = try hnrMaskProvenance()
    let policy = try MaskSelectionPolicy(rejectedTags: [.silence])
    let profile = try HNRStatisticProfile(
        measurement: c, population: .silenceExcluded,
        selection: policy, provenances: [provenance])
    for (tag, expected) in [
        (MaskTag.silence, UnavailabilityReason.excluded),
        (.missingAcquisition, .missingAcquisition),
    ] {
        let timeline = try MaskTimeline(
            MaskPlan(
                source: source, provenances: [provenance], policy: policy,
                observations: [
                    MaskObservation(source: hnrMaskSource(399, 1), provenanceIndex: 0, tags: [tag])
                ]))
        #expect(raw.frameTiming.source.endSample < source.endSample - 1)
        let selection = try HNRFrameSelection(raw: raw, profile: profile, timeline: timeline)
        #expect(selection.raw == raw && selection.raw.selectedObservation != nil)
        #expect(
            selection.selectedObservation == nil && selection.selectionUnavailability == expected)
        let scalar = try selection.measurementResult()
        #expect(scalar.outcome == .unavailable(expected) && scalar.timing.includedSampleCount == 0)
        #expect(
            scalar.timing.source == source
                && scalar.timing.completedHostNanoseconds == 2_000_000_000)
    }
    let all = try MaskTimeline(
        MaskPlan(source: source, provenances: [provenance], policy: policy, observations: []))
    let selected = try HNRFrameSelection(raw: raw, profile: profile, timeline: all)
    #expect(selected.selectionUnavailability == nil && selected.selectedRegionIndex == 0)
    #expect(selected.selectedObservation == raw.selectedObservation)
    #expect(try selected.measurementResult().outcome == raw.measurementResult().outcome)
}

@Test func hnrSelectedRegionsRecomputeNormalizationWithoutJoiningExcludedPCM() throws {
    let c = try hnrMaskConfiguration()
    let source = try hnrMaskSource(0, 600)
    let policy = try MaskSelectionPolicy(rejectedTags: [.suspectedExternalNoise])
    let provenance = try hnrMaskProvenance()
    let timeline = try MaskTimeline(
        MaskPlan(
            source: source, provenances: [provenance], policy: policy,
            observations: [
                MaskObservation(
                    source: hnrMaskSource(200, 200), provenanceIndex: 0,
                    tags: [.suspectedExternalNoise])
            ]))
    let profile = try HNRStatisticProfile(
        measurement: c, population: .customSelection,
        selection: policy, provenances: [provenance])
    let pcm = (0..<600).map { i in
        let gain = (200..<400).contains(i) ? 0.8 : 0.01
        return gain * (0.3 * sin(Double(i) * 2 * .pi / 7) + 0.04 * cos(Double(i) * 2 * .pi / 3.2))
    }
    func analyze(_ region: SourceInterval) throws -> ([HNRFrameResult], HNRCompletion) {
        let worker = try PreparedIntervalHNR<Double>(
            configuration: c,
            timing: AnalysisTiming(source: region, includedSampleCount: region.sampleCount))
        let start = Int(region.startSample - source.startSample)
        try pcm.withUnsafeBufferPointer {
            try worker.append(
                UnsafeBufferPointer(rebasing: $0[start..<start + Int(region.sampleCount)]),
                interval: region)
        }
        var frames: [HNRFrameResult] = []
        let completion = try worker.finish {
            if case .frame(let frame) = $0 { frames.append(frame.result) }
        }
        return (frames, completion)
    }
    let raw = try analyze(source)
    #expect(raw.0.first?.unavailability == .silence && raw.0.first?.strongestObservation != nil)
    var results: [HNRCompletion] = []
    for region in timeline.selectedRegions {
        let (frames, completion) = try analyze(region)
        #expect(
            !frames.isEmpty && frames.allSatisfy { $0.selectedObservation?.finiteDecibels != nil })
        #expect(frames.allSatisfy { $0.dependencyTiming.source == region })
        for frame in frames {
            let selected = try HNRFrameSelection(raw: frame, profile: profile, timeline: timeline)
            #expect(selected.selectionUnavailability == nil)
        }
        results.append(completion)
    }
    let report = try HNRRegionReport(profile: profile, timeline: timeline, regions: results)
    #expect(report.meanDB != nil && report.unavailableFrameCount == 0)
    #expect(report.timeline.coverage.excludedEligibleSampleCount == 200)
    #expect(report.availableFrameCount == results.reduce(0) { $0 + $1.availableFrameCount })
    #expect(
        try HNRIntervalLayout(configuration: c, sampleCount: 400).frameCount
            > report.completeGridFrameCount)
    #expect(report.observedSampleCount <= 400 && report.observedSampleCount > 0)
}
