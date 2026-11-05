import Foundation
import Testing

@testable import HDXLVoiceProcessing

/// Constructed controls, not human phonation labels or calibrated SPL evidence.
@Test func cppsMaskedPCMRegionsIntensityAndLowPeriodicity() throws {
    let epoch = StreamEpoch(streamID: UUID())
    let start: Int64 = (1 << 54) + 3700
    func source(_ offset: Int, _ count: Int) throws -> SourceInterval {
        try SourceInterval(
            epoch: epoch, startSample: start + Int64(offset),
            sampleCount: Int64(count), sampleRate: 16_000)
    }
    var seed: UInt32 = 37
    let noise = (0..<4800).map { _ -> Double in
        seed = 1_664_525 &* seed &+ 1_013_904_223
        return Double(seed) / Double(UInt32.max) - 0.5
    }
    let vowel = noise.enumerated().map { index, noise in
        let phase = 2 * Double.pi * 125 * Double(index) / 16_000
        return 0.25 * sin(phase) + 0.12 * sin(2 * phase + 0.17)
            + 0.08 * sin(3 * phase + 0.3) + 0.001 * noise
    }
    let pcm =
        vowel + Array(repeating: 0.0, count: 1600) + noise
        + Array(repeating: 0.0, count: 1600) + vowel.map { $0 * 0.25 }
    let provenance = try MaskProvenance(
        kind: .externalAnnotation,
        identifier: VersionedIdentifier(name: "constructed-cpps-controls", version: 1))
    let policy = try MaskSelectionPolicy(rejectedTags: [.silence])
    let timeline = try MaskTimeline(
        MaskPlan(
            source: source(0, pcm.count),
            provenances: [provenance], policy: policy,
            observations: [
                MaskObservation(
                    source: source(4800, 1600), provenanceIndex: 0, tags: [.missingAcquisition]),
                MaskObservation(source: source(11200, 1600), provenanceIndex: 0, tags: [.silence]),
            ]))
    let expectedRegions = try [source(0, 4800), source(6400, 4800), source(12800, 4800)]
    #expect(timeline.selectedRegions == expectedRegions)
    let profile = try CPPSProfile.murtonRecipePraat7(
        sourceSampleRate: 16_000, declaredInputBandwidthHz: 8000)
    // Preparation is outside the routing callbacks. Region order selects each
    // independently conditioned worker; no smoothing/filter state crosses a gap.
    let workers = try timeline.selectedRegions.map {
        try PreparedIntervalCPPS<Double>(profile: profile, source: $0)
    }
    let cursor = PreparedMaskCursor<Double>(timeline: timeline, scope: .selected)
    var completions: [CPPSCompletion] = []
    var frames: [[CPPSFrameResult]] = Array(repeating: [], count: workers.count)
    var callbackError: (any Error)?
    try pcm.withUnsafeBufferPointer { input in
        for offset in stride(from: 0, to: pcm.count, by: 137) {
            let end = min(offset + 137, pcm.count)
            try cursor.process(
                UnsafeBufferPointer(rebasing: input[offset..<end]),
                interval: source(offset, end - offset)
            ) { buffer, context in
                do {
                    try workers[context.regionIndex].append(buffer, interval: context.source)
                    if context.endsRegion {
                        completions.append(
                            try workers[context.regionIndex].finish {
                                frames[context.regionIndex].append($0.result)
                            })
                    }
                } catch { callbackError = error }
            }
        }
    }
    if let callbackError { throw callbackError }
    #expect(completions.count == 3)
    for (index, region) in timeline.selectedRegions.enumerated() {
        let direct = try PreparedIntervalCPPS<Double>(profile: profile, source: region)
        let left = Int(region.startSample - start)
        try pcm.withUnsafeBufferPointer { input in
            try direct.append(
                UnsafeBufferPointer(rebasing: input[left..<left + Int(region.sampleCount)]),
                interval: region)
        }
        var directFrames: [CPPSFrameResult] = []
        let completion = try direct.finish { directFrames.append($0.result) }
        #expect(completion == completions[index] && directFrames == frames[index])
        #expect(frames[index].allSatisfy { $0.context.timing.source == region })
    }
    let high = try #require(completions[0].meanDB)
    let lowPeriodicity = try #require(completions[1].meanDB)
    let low = try #require(completions[2].meanDB)
    #expect(abs(high - low) < 1e-6)
    #expect(high > lowPeriodicity + 5)
    let statistic = try CPPSStatisticProfile(
        measurement: profile, population: .silenceExcluded,
        selection: policy, provenances: [provenance])
    let report = try CPPSRegionReport(profile: statistic, timeline: timeline, regions: completions)
    #expect(report.observedSampleCount == 14400)
    #expect(report.timeline.coverage.missingSampleCount == 1600)
    #expect(report.timeline.coverage.excludedEligibleSampleCount == 1600)
    #expect(report.observedSelectedCoverage == 1)
    #expect(abs(try #require(report.meanDB) - (high + lowPeriodicity + low) / 3) < 1e-12)
}
