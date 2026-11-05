import Foundation
import Testing

@testable import HDXLVoiceProcessing

private let aggregateEpoch = StreamEpoch(
    streamID: UUID(uuidString: "0F2B41C3-1035-4EE4-9535-000000000137")!)
private let aggregateStart: Int64 = (1 << 54) + 137

private func aggregateSource(_ start: Int64, _ count: Int64) throws -> SourceInterval {
    try SourceInterval(
        epoch: aggregateEpoch, startSample: aggregateStart + start,
        sampleCount: count, sampleRate: 10_000)
}
private func aggregateProfile() throws -> CPPSProfile {
    try .murtonRecipePraat7(sourceSampleRate: 10_000, declaredInputBandwidthHz: 5000)
}
private func aggregateProvenance() throws -> MaskProvenance {
    try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "constructed-test-regions", version: 1))
}

@Test func cppsRegionWeightingCoverageAndPopulationIdentity() throws {
    let source = try aggregateSource(0, 50_000)
    let provenance = try aggregateProvenance()
    let policy = try MaskSelectionPolicy()
    let timeline = try MaskTimeline(
        MaskPlan(
            source: source, provenances: [provenance], policy: policy,
            observations: [
                MaskObservation(
                    source: aggregateSource(10_000, 10_000), provenanceIndex: 0,
                    tags: [.missingAcquisition])
            ]))
    let measurement = try aggregateProfile()
    let durationProfile = try CPPSStatisticProfile(
        measurement: measurement, population: .allEligible,
        selection: policy, provenances: [provenance])
    let frameProfile = try CPPSStatisticProfile(
        measurement: measurement, population: .allEligible,
        selection: policy, provenances: [provenance], aggregation: .equalFrameMean)
    let identity = try measurement.identity()
    let first = CPPSCompletion(
        profile: identity, source: timeline.selectedRegions[0],
        frameCount: 2, availableFrameCount: 2, meanDB: 2, unavailability: nil)
    let second = CPPSCompletion(
        profile: identity, source: timeline.selectedRegions[1],
        frameCount: 2, availableFrameCount: 2, meanDB: 8, unavailability: nil)
    let duration = try CPPSRegionReport(
        profile: durationProfile, timeline: timeline, regions: [first, second])
    let frames = try CPPSRegionReport(
        profile: frameProfile, timeline: timeline, regions: [first, second])
    #expect(duration.meanDB == 6.5)
    #expect(frames.meanDB == 5)
    #expect(duration.observedSampleCount == 40_000)
    #expect(duration.observedDurationSeconds == 4)
    #expect(duration.observedSelectedCoverage == 1)
    #expect(duration.timeline.coverage.missingSampleCount == 10_000)
    #expect(duration.identity != frames.identity)
    let exported = try duration.measurementResult()
    #expect(exported.timing.source == source && exported.timing.includedSampleCount == 40_000)
    #expect(exported.outcome.estimate?.warnings == [.partialCoverage])
    let unavailable = CPPSCompletion(
        profile: identity, source: second.source,
        frameCount: 1, availableFrameCount: 0, meanDB: nil, unavailability: .insufficientData)
    let partial = try CPPSRegionReport(
        profile: durationProfile, timeline: timeline, regions: [first, unavailable])
    #expect(partial.meanDB == 2 && partial.observedSelectedCoverage == 0.25)
    #expect(throws: CPPSError.profileMismatch) {
        try CPPSRegionReport(
            profile: durationProfile, timeline: timeline, regions: [second, first])
    }
    let silence = try CPPSStatisticProfile(
        measurement: measurement, population: .silenceExcluded,
        selection: MaskSelectionPolicy(rejectedTags: [.silence]), provenances: [provenance])
    let voice = try CPPSStatisticProfile(
        measurement: measurement, population: .voiceOnly,
        selection: MaskSelectionPolicy(selectionSources: [0]), provenances: [provenance])
    #expect(try Set([durationProfile.identity(), silence.identity(), voice.identity()]).count == 3)
    #expect(
        try JSONDecoder().decode(CPPSStatisticProfile.self, from: canonicalContractJSON(voice))
            == voice)
}

@Test func cppsRegionMissingExcludedAndEmptyNeverBecomeZero() throws {
    let measurement = try aggregateProfile()
    let provenance = try aggregateProvenance()
    for (count, tag, population, expected) in [
        (
            0, MaskTag.missingAcquisition, CPPSPopulation.allEligible,
            UnavailabilityReason.insufficientData
        ),
        (10_000, .missingAcquisition, .allEligible, .missingAcquisition),
        (10_000, .silence, .silenceExcluded, .excluded),
    ] {
        let source = try aggregateSource(0, Int64(count))
        let policy = try MaskSelectionPolicy(rejectedTags: tag == .silence ? [.silence] : [])
        let observations =
            count == 0
            ? []
            : [
                try MaskObservation(
                    source: source,
                    provenanceIndex: 0, tags: [tag])
            ]
        let timeline = try MaskTimeline(
            MaskPlan(
                source: source, provenances: [provenance],
                policy: policy, observations: observations))
        let profile = try CPPSStatisticProfile(
            measurement: measurement, population: population,
            selection: policy, provenances: [provenance])
        let result = try CPPSRegionReport(profile: profile, timeline: timeline, regions: [])
        #expect(result.meanDB == nil && result.unavailability == expected)
        #expect(result.observedSampleCount == 0)
        #expect(try result.measurementResult().outcome.estimate == nil)
    }
}

private func aggregateFrame(
    _ index: UInt64, support: SourceInterval, center: Double,
    value: Double?, reason: UnavailabilityReason? = nil, regionStart: Int64 = 0
) throws -> CPPSFrameResult {
    let profile = try aggregateProfile()
    let context = try CepstralFrameContext(
        origin: aggregateSource(regionStart, 0),
        timing: AnalysisTiming(source: support, includedSampleCount: support.sampleCount),
        frameIndex: index, firstAnalysisSampleIndex: Int64(index) * 20,
        suppliedAnalysisSampleCount: 1000, centerSecondsFromOrigin: center)
    let observation = value.map {
        CPPObservation(
            prominenceDB: $0, peakQuefrencySeconds: 0.008,
            peakDB: $0, backgroundDB: 0, slopeDBPerSecond: 0, interceptDB: 0,
            residualMeanDB: 0, residualRMSDB: 0, residualMedianDB: 0, residualMaximumAbsoluteDB: 0,
            peakIsAtSearchBoundary: false, usedBidirectionalTieRule: false)
    }
    let rawProfile = CPPProfile(
        cepstrogram: profile.cepstrogram, settings: profile.settings.prominence)
    let raw = try CPPFrameResult(
        profile: rawProfile.identity(), sourceProfile: profile.cepstrogram.identity(),
        context: context, layout: CPPLayout(profile: rawProfile), observation: observation,
        unavailability: reason)
    return try CPPSFrameResult(
        profile: profile.identity(), sourceProfile: profile.cepstrogram.identity(),
        rawCPP: raw, context: context, observation: observation, unavailability: reason,
        temporalSupportFrameCount: 1, usesSmoothingEdge: false, lookaheadSeconds: 0.006)
}

@Test func cppsRollingExpiryGapExclusionAndCoverageUnion() throws {
    let provenance = try aggregateProvenance()
    let policy = try MaskSelectionPolicy(rejectedTags: [.silence])
    let timeline = try MaskTimeline(
        MaskPlan(
            source: aggregateSource(0, 100_000),
            provenances: [provenance], policy: policy,
            observations: [
                MaskObservation(
                    source: aggregateSource(2000, 1000), provenanceIndex: 0,
                    tags: [.missingAcquisition]),
                MaskObservation(
                    source: aggregateSource(3000, 1000), provenanceIndex: 0, tags: [.silence]),
            ]))
    let profile = try CPPSStatisticProfile(
        measurement: aggregateProfile(), population: .silenceExcluded,
        selection: policy, provenances: [provenance], aggregation: .rollingFrameMean,
        rollingWindowSeconds: 1)
    let worker = try PreparedRollingCPPS(profile: profile, origin: aggregateSource(0, 0))
    for index in 0..<3 {
        try worker.append(
            aggregateFrame(
                UInt64(index), support: aggregateSource(Int64(index) * 500, 1000),
                center: Double(index + 1) * 0.05, value: Double(index + 1) * 2))
    }
    let initial = try worker.result(atSourceSample: aggregateStart + 2000, mask: timeline)
    #expect(initial.meanDB == 4 && initial.contributingFrameCount == 3)
    #expect(initial.observedSampleCountInWindow == 2000)
    #expect(initial.timing.includedSampleCount == 2000)
    let missing = try worker.result(atSourceSample: aggregateStart + 2500, mask: timeline)
    #expect(missing.meanDB == nil && missing.unavailability == .missingAcquisition)
    let excluded = try worker.result(atSourceSample: aggregateStart + 3500, mask: timeline)
    #expect(excluded.meanDB == nil && excluded.unavailability == .excluded)
    let noNewFrame = try worker.result(atSourceSample: aggregateStart + 5000, mask: timeline)
    #expect(noNewFrame.meanDB == nil && noNewFrame.unavailability == .insufficientData)
    try worker.append(
        aggregateFrame(
            0, support: aggregateSource(4000, 1000), center: 0.05,
            value: 10, regionStart: 4000))
    let resumed = try worker.result(atSourceSample: aggregateStart + 5000, mask: timeline)
    #expect(resumed.meanDB == 5.5 && resumed.contributingFrameCount == 4)
    #expect(resumed.observedSampleCountInWindow == 3000)
    #expect(resumed.eligibleSampleCount == 4000 && resumed.selectedSampleCount == 3000)
    let stale = try worker.result(atSourceSample: aggregateStart + 15_000, mask: timeline)
    #expect(stale.meanDB == nil && stale.unavailability == .stale)
    #expect(stale.contributingFrameCount == 0 && stale.observedSampleCountInWindow == 0)
    #expect(stale.latestFrameAgeSeconds == 1.05)
    #expect(throws: CPPSError.unexpectedFrame) {
        try worker.result(atSourceSample: aggregateStart + 14_999, mask: timeline)
    }
    try worker.reset(origin: aggregateSource(0, 0))
    let reset = try worker.result(atSourceSample: aggregateStart + 2000, mask: timeline)
    #expect(reset.meanDB == nil && reset.unavailability == .insufficientData)
}

@Test func cppsRollingLatestUnavailableSuppressesPriorNumber() throws {
    let policy = try MaskSelectionPolicy()
    let timeline = try MaskTimeline(
        MaskPlan(
            source: aggregateSource(0, 20_000), provenances: [],
            policy: policy, observations: []))
    let profile = try CPPSStatisticProfile(
        measurement: aggregateProfile(), population: .allEligible,
        selection: policy, provenances: [], aggregation: .rollingFrameMean, rollingWindowSeconds: 1)
    let worker = try PreparedRollingCPPS(profile: profile, origin: aggregateSource(0, 0))
    try worker.append(aggregateFrame(0, support: aggregateSource(0, 1000), center: 0.05, value: 0))
    #expect(try worker.result(atSourceSample: aggregateStart + 1000, mask: timeline).meanDB == 0)
    try worker.append(
        aggregateFrame(
            1, support: aggregateSource(500, 1000), center: 0.1,
            value: nil, reason: .analysisFailure))
    let result = try worker.result(atSourceSample: aggregateStart + 1500, mask: timeline)
    #expect(result.meanDB == nil && result.unavailability == .analysisFailure)
    #expect(try result.measurementResult().outcome.estimate == nil)
}
