import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func shimmerOrigin(start: Int64 = 0) throws -> SourceInterval {
    try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: start, sampleCount: 0, sampleRate: 16384)
}
private func shimmerSupport(_ origin: SourceInterval, start: Int64 = 0, end: Int64) throws
    -> SourceInterval
{
    try SourceInterval(
        epoch: origin.epoch, startSample: origin.startSample + start,
        sampleCount: end - start, sampleRate: origin.sampleRate)
}
private func shimmerRollingTiming(_ source: SourceInterval, included: Int64? = nil) throws
    -> AnalysisTiming
{
    try AnalysisTiming(
        source: source, includedSampleCount: included ?? source.sampleCount,
        sourceStartSeconds: 20, hostStartNanoseconds: 123, completedHostNanoseconds: 456)
}

@Test func shimmerRollingMatchesFreshBatchAcrossExpirationsRejectionsAndAllVariants() throws {
    for variant in [nil] + ShimmerVariant.allCases.map(Optional.some) {
        let origin = try shimmerOrigin(start: Int64.max - 200000)
        let configuration = try ShimmerConfiguration(
            sampleRate: 16384,
            applicability: .exploratoryRolling, rollingWindowSampleCount: 2048)
        let rolling = try PreparedRollingShimmer(
            configuration: configuration, origin: origin,
            maximumAmplitudeCount: 32, variant: variant)
        let batch = try PreparedShimmer(configuration: configuration, maximumAmplitudeCount: 1000)
        var history: [ShimmerAmplitudeInput] = []
        for i in 0..<700 {
            let missing = i % 17 == 8
            let value: Double? = missing ? nil : 1 + 0.1 * sin(Double(i))
            let record = try ShimmerAmplitudeInput(
                timeSeconds: Double((i + 1) * 128) / 16384,
                amplitude: value, sequenceIndex: UInt64(i + (i >= 94 ? 1 : 0)),
                runID: UInt64(i / 43), rejections: missing ? .unreliable : [])
            let clock = Int64((i + 2) * 128)
            history.append(record)
            try rolling.append(
                record, dependency: shimmerSupport(origin, start: Int64(i * 128), end: clock))
            if i % 8 != 0 && i != 699 { continue }
            let fullTiming = try shimmerRollingTiming(shimmerSupport(origin, end: clock))
            let query = try ShimmerQueryRange(
                startSeconds: Double(max(0, clock - 2048)) / 16384,
                endSeconds: Double(clock) / 16384)
            let expected = try history.withUnsafeBufferPointer { records in
                if let variant {
                    return try batch.analyze(
                        variant, amplitudes: records, dependencyTiming: fullTiming, query: query)
                }
                return try batch.analyze(records, dependencyTiming: fullTiming, query: query)
            }
            let required = try rolling.requiredDependency(
                atSourceSample: origin.startSample + clock)
            let compactTiming = try shimmerRollingTiming(required)
            let actual = try rolling.result(
                atSourceSample: origin.startSample + clock, dependencyTiming: compactTiming)
            #expect(
                actual.coverage.selectedAmplitudeCount == expected.coverage.selectedAmplitudeCount)
            #expect(
                actual.coverage.normalizationAmplitudeCount
                    == expected.coverage.normalizationAmplitudeCount)
            #expect(actual.coverage.meanAmplitude == expected.coverage.meanAmplitude)
            #expect(actual.coverage.rejections == expected.coverage.rejections)
            #expect(actual.coverage.acceptedPairCount == expected.coverage.acceptedPairCount)
            #expect(
                actual.coverage.acceptedAPQ3NeighborhoodCount
                    == expected.coverage.acceptedAPQ3NeighborhoodCount)
            #expect(
                actual.coverage.acceptedAPQ5NeighborhoodCount
                    == expected.coverage.acceptedAPQ5NeighborhoodCount)
            #expect(
                actual.coverage.acceptedAPQ11NeighborhoodCount
                    == expected.coverage.acceptedAPQ11NeighborhoodCount)
            for measurement in ShimmerVariant.allCases {
                #expect(actual.estimate(measurement) == expected.estimate(measurement))
            }
            let aligned = try #require(actual.sampleAlignedQuery)
            #expect(aligned.endSample == origin.startSample + clock)
            #expect(aligned.startSample == origin.startSample + max(0, clock - 2048))
            #expect(actual.coverage.analyzedDurationSeconds == aligned.durationSeconds)
            #expect(rolling.executionStatistics.retainedAmplitudeCount <= 16)
        }
        #expect(rolling.executionStatistics.appendedAmplitudeCount == 700)
        #expect(rolling.executionStatistics.evaluatedAmplitudeCount > 1000)
    }
}

@Test func shimmerRollingUsesExactClosedTimestampBoundsAtLargeSampleOrigins() throws {
    let origin = try shimmerOrigin(start: Int64.max - 1024)
    let configuration = try ShimmerConfiguration(
        sampleRate: 16384,
        applicability: .exploratoryRolling, rollingWindowSampleCount: 128)
    let cutoff = 256.0 / 16384
    for time in [cutoff.nextDown, cutoff, cutoff.nextUp] {
        let rolling = try PreparedRollingShimmer(
            configuration: configuration, origin: origin, maximumAmplitudeCount: 2)
        try rolling.append(
            ShimmerAmplitudeInput(timeSeconds: time, amplitude: 1, sequenceIndex: 0),
            dependency: shimmerSupport(origin, end: 384))
        let fullTiming = try shimmerRollingTiming(shimmerSupport(origin, end: 384))
        let result = try rolling.result(
            atSourceSample: origin.startSample + 384, dependencyTiming: fullTiming)
        #expect(result.coverage.selectedAmplitudeCount == (time >= cutoff ? 1 : 0))
        #expect(result.query.startSeconds == cutoff)
        #expect(result.sampleAlignedQuery?.startSample == origin.startSample + 256)
        let unrelated = try SourceInterval(
            epoch: origin.epoch, startSample: 0,
            sampleCount: origin.startSample + 384, sampleRate: origin.sampleRate)
        #expect(throws: ShimmerError.unexpectedContext) {
            try rolling.result(
                atSourceSample: origin.startSample + 384,
                dependencyTiming: shimmerRollingTiming(unrelated))
        }
    }
}

@Test func shimmerRollingInvalidCallsAreAtomicAndExpiredHistoryIsStale() throws {
    let origin = try shimmerOrigin()
    let configuration = try ShimmerConfiguration(
        sampleRate: 16384,
        applicability: .exploratoryRolling, rollingWindowSampleCount: 512)
    let rolling = try PreparedRollingShimmer(
        configuration: configuration, origin: origin, maximumAmplitudeCount: 2)
    let a = try ShimmerAmplitudeInput(timeSeconds: 128.0 / 16384, amplitude: 1, sequenceIndex: 0)
    let b = try ShimmerAmplitudeInput(timeSeconds: 256.0 / 16384, amplitude: 1, sequenceIndex: 1)
    let c = try ShimmerAmplitudeInput(timeSeconds: 384.0 / 16384, amplitude: 1, sequenceIndex: 2)
    let support = try shimmerSupport(origin, end: 384)
    try rolling.append(a, dependency: support)
    try rolling.append(b, dependency: support)
    let before = rolling.executionStatistics
    #expect(throws: ShimmerError.capacityExceeded) { try rolling.append(c, dependency: support) }
    #expect(throws: ShimmerError.unexpectedContext) { try rolling.append(a, dependency: support) }
    #expect(throws: ShimmerError.unexpectedContext) {
        try rolling.append(c, dependency: shimmerSupport(shimmerOrigin(), end: 384))
    }
    #expect(throws: ShimmerError.unexpectedContext) {
        try rolling.append(c, dependency: shimmerSupport(origin, end: 256))
    }
    #expect(throws: ShimmerError.unexpectedContext) {
        try rolling.requiredDependency(atSourceSample: 383)
    }
    #expect(throws: ShimmerError.unexpectedContext) { try rolling.reset(origin: support) }
    #expect(rolling.executionStatistics == before)
    let result = try rolling.result(
        atSourceSample: 384, dependencyTiming: shimmerRollingTiming(support))
    #expect(result.local.value == 0)
    let excluded = try rolling.result(
        atSourceSample: 384, dependencyTiming: shimmerRollingTiming(support, included: 0))
    #expect(
        excluded.local.unavailability == .excluded
            && excluded.coverage.normalizationAmplitudeCount == 0)
    let expiredSupport = try rolling.requiredDependency(atSourceSample: 1024)
    #expect(expiredSupport.startSample == 512 && expiredSupport.sampleCount == 512)
    let stale = try rolling.result(
        atSourceSample: 1024, dependencyTiming: shimmerRollingTiming(expiredSupport))
    #expect(stale.local.unavailability == .stale)
    #expect(rolling.executionStatistics.retainedAmplitudeCount == 0)
    let next = try shimmerOrigin(start: 1000)
    try rolling.reset(origin: next)
    #expect(rolling.origin == next && rolling.executionStatistics.appendedAmplitudeCount == 0)
}
