import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func rollingJitterOrigin(rate: Int = 16384, start: Int64 = 0) throws -> SourceInterval {
    try SourceInterval(
        epoch: StreamEpoch(streamID: UUID()), startSample: start,
        sampleCount: 0, sampleRate: Double(rate))
}

private func rollingJitterSupport(_ origin: SourceInterval, start: Int64 = 0, end: Int64) throws
    -> SourceInterval
{
    try SourceInterval(
        epoch: origin.epoch, startSample: origin.startSample + start,
        sampleCount: end - start, sampleRate: origin.sampleRate)
}

private func rollingJitterTiming(_ source: SourceInterval, included: Int64? = nil) throws
    -> AnalysisTiming
{
    try AnalysisTiming(
        source: source, includedSampleCount: included ?? source.sampleCount,
        sourceStartSeconds: 42, hostStartNanoseconds: 100, completedHostNanoseconds: 900,
        effectiveDelaySeconds: source.durationSeconds)
}

private func expectRollingJitterEquivalent(
    _ actual: JitterAnalysisResult, _ expected: JitterAnalysisResult
) {
    let a = actual.coverage
    let b = expected.coverage
    #expect(actual.profile == expected.profile && actual.query == expected.query)
    #expect(actual.dependencyTiming == expected.dependencyTiming)
    let actualCounts: [Int] = [
        a.selectedPeriodCount, a.acceptedPeriodCount, a.meanPeriodCount, a.acceptedPairCount,
        a.acceptedRAPNeighborhoodCount, a.acceptedPPQ5NeighborhoodCount,
        a.candidatePairCount, a.candidateRAPNeighborhoodCount, a.candidatePPQ5NeighborhoodCount,
    ]
    let expectedCounts: [Int] = [
        b.selectedPeriodCount, b.acceptedPeriodCount, b.meanPeriodCount, b.acceptedPairCount,
        b.acceptedRAPNeighborhoodCount, b.acceptedPPQ5NeighborhoodCount,
        b.candidatePairCount, b.candidateRAPNeighborhoodCount, b.candidatePPQ5NeighborhoodCount,
    ]
    #expect(actualCounts == expectedCounts)
    #expect(a.rejections == b.rejections)
    #expect(
        abs(a.analyzedDurationSeconds - b.analyzedDurationSeconds)
            <= 2 * expected.query.endSeconds.ulp)
    // Tree depth is bounded by 20; compare its pairwise sums against the
    // separately compensated batch sums with a forward-rounding allowance.
    #expect(
        abs(a.acceptedPeriodDurationSeconds - b.acceptedPeriodDurationSeconds)
            <= 64 * Double.ulpOfOne * max(1, b.acceptedPeriodDurationSeconds))
    #expect((a.meanPeriodSeconds == nil) == (b.meanPeriodSeconds == nil))
    if let x = a.meanPeriodSeconds, let y = b.meanPeriodSeconds {
        #expect(abs(x - y) <= 64 * Double.ulpOfOne * y)
    }
    for variant in JitterVariant.allCases {
        let x = actual.estimate(variant)
        let y = expected.estimate(variant)
        #expect(x.status == y.status && x.unavailability == y.unavailability)
        if let x = x.value, let y = y.value {
            #expect(abs(x - y) <= 128 * Double.ulpOfOne * max(y, 1e-12))
        }
    }
}

@Test func jitterRollingMatchesBatchAcrossWrapsGapsRejectionsAndSingleVariants() throws {
    for rate in [16000, 16384] {
        let origin = try rollingJitterOrigin(rate: rate, start: (1 << 53) + 137)
        let configuration = try JitterConfiguration(
            sampleRate: rate,
            applicability: .exploratoryRolling, rollingWindowSampleCount: 4096,
            minimumPeriodSeconds: 1.0 / 256, maximumPeriodSeconds: 1.0 / 16)
        let rolling = try PreparedRollingJitter(
            configuration: configuration, origin: origin,
            maximumPeriodCount: 200)
        let separate = try JitterVariant.allCases.map {
            try PreparedRollingJitter(
                configuration: configuration, origin: origin,
                maximumPeriodCount: 200, variant: $0)
        }
        let batch = try PreparedJitter(configuration: configuration, maximumPeriodCount: 1200)
        var periods: [JitterPeriodInput] = []
        var cursor: Int64 = 0
        var run: UInt64 = 0
        let lengths: [Int64] = [64, 65, 66, 80, 128, 256, 1024, 1600, 16]
        let reasons: [JitterPeriodRejections] = [
            .excluded, .discontinuity, .unreliable,
            .missingAcquisition, .invalidInput, .silence, [.unreliable, .excluded],
        ]
        for index in 0..<1200 {
            if index % 37 == 0 { cursor += 5 }
            if index % 43 == 0 { run += 1 }
            let start = cursor
            let length = lengths[(index * 7 + index / 11) % lengths.count]
            cursor += length
            let period = try JitterPeriodInput(
                startSeconds: Double(start) / Double(rate),
                endSeconds: Double(cursor) / Double(rate), runID: run,
                rejections: index % 13 == 4 ? reasons[(index / 13) % reasons.count] : [])
            let support = try rollingJitterSupport(origin, start: start, end: cursor)
            try rolling.append(period, dependency: support)
            for worker in separate { try worker.append(period, dependency: support) }
            periods.append(period)
            let timing = try rollingJitterTiming(rollingJitterSupport(origin, end: cursor))
            let actual = try rolling.result(
                atSourceSample: origin.startSample + cursor,
                dependencyTiming: timing)
            let query = try JitterQueryRange(
                startSeconds: Double(max(0, cursor - 4096)) / Double(rate),
                endSeconds: Double(cursor) / Double(rate))
            let expected = try periods.withUnsafeBufferPointer {
                try batch.analyze($0, dependencyTiming: timing, query: query)
            }
            expectRollingJitterEquivalent(actual, expected)
            for worker in separate {
                let result = try worker.result(
                    atSourceSample: origin.startSample + cursor,
                    dependencyTiming: timing)
                let variant = try #require(worker.variant)
                #expect(result.estimate(variant) == actual.estimate(variant))
                #expect(result.coverage == actual.coverage)
                for other in JitterVariant.allCases where other != variant {
                    #expect(result.estimate(other).status == .notRequested)
                }
            }
            #expect(actual.coverage.inputPeriodCount <= 201)
        }
        let statistics = rolling.executionStatistics
        #expect(statistics.appendedPeriodCount == 1200 && statistics.analyzedQueryCount == 1200)
        // At most five updated leaves and one amortized eviction per append;
        // this capacity's tree has nine nodes on each root path.
        #expect(statistics.sumTreeNodeUpdateCount <= 1200 * 6 * 9)
    }
}

@Test func jitterRollingPreservesExpiredDenominatorContextAndNewRightNeighbor() throws {
    for rejectFirst in [false, true] {
        let origin = try rollingJitterOrigin()
        let configuration = try JitterConfiguration(
            sampleRate: 16384,
            applicability: .exploratoryRolling, rollingWindowSampleCount: 192)
        let worker = try PreparedRollingJitter(
            configuration: configuration, origin: origin,
            maximumPeriodCount: 2)
        let points: [Int64] = [0, 128, 192, 320]
        for i in 0..<3 {
            let period = try JitterPeriodInput(
                startSeconds: Double(points[i]) / 16384,
                endSeconds: Double(points[i + 1]) / 16384,
                rejections: i == 0 && rejectFirst ? .excluded : [])
            try worker.append(
                period,
                dependency: rollingJitterSupport(
                    origin,
                    start: points[i], end: points[i + 1]))
            if i == 1 {
                let result = try worker.result(
                    atSourceSample: 192,
                    dependencyTiming: rollingJitterTiming(rollingJitterSupport(origin, end: 192)))
                #expect(result.coverage.meanPeriodCount == (rejectFirst ? 1 : 2))
            }
        }
        let dependency = try worker.requiredDependency(atSourceSample: 320)
        #expect(dependency.startSample == (rejectFirst ? 128 : 0))
        let result = try worker.result(
            atSourceSample: 320,
            dependencyTiming: rollingJitterTiming(dependency))
        #expect(result.coverage.selectedPeriodCount == 2 && result.coverage.inputPeriodCount == 3)
        #expect(result.coverage.meanPeriodCount == (rejectFirst ? 2 : 1))
        #expect(result.coverage.meanPeriodSeconds == (rejectFirst ? 1.5 : 2) / 256)
        #expect(result.coverage.rejections.bothAdjacentRatios == (rejectFirst ? 0 : 1))
        #expect(result.coverage.acceptedPairCount == 0)
    }
}

@Test func jitterRollingKeepsFractionalBoundaryComparisonsWithoutSampleRounding() throws {
    let origin = try rollingJitterOrigin(start: Int64.max - 1024)
    let configuration = try JitterConfiguration(
        sampleRate: 16384,
        applicability: .exploratoryRolling, rollingWindowSampleCount: 128)
    let cutoff = 256.0 / 16384
    for start in [cutoff.nextDown, cutoff, cutoff.nextUp] {
        let worker = try PreparedRollingJitter(
            configuration: configuration, origin: origin,
            maximumPeriodCount: 2)
        try worker.append(
            JitterPeriodInput(startSeconds: start, endSeconds: 384.0 / 16384),
            dependency: rollingJitterSupport(origin, end: 384))
        let timing = try rollingJitterTiming(rollingJitterSupport(origin, end: 384))
        let result = try worker.result(
            atSourceSample: origin.startSample + 384, dependencyTiming: timing)
        #expect(result.coverage.selectedPeriodCount == (start >= cutoff ? 1 : 0))
        #expect(result.query.startSeconds == cutoff)
        #expect(result.dependencyTiming.source.startSample == Int64.max - 1024)
        let window = try #require(result.sampleAlignedQuery)
        #expect(window.startSample == origin.startSample + 256 && window.sampleCount == 128)
        #expect(result.coverage.analyzedDurationSeconds == 128.0 / 16384)
        let json = try #require(
            JSONSerialization.jsonObject(with: result.canonicalJSON()) as? [String: Any])
        let encoded = try #require(json["sampleAlignedQuery"] as? [String: Any])
        #expect((encoded["startSample"] as? NSNumber)?.int64Value == origin.startSample + 256)
        // An unrelated huge prefix would erase the small relative query in
        // Double coordinates. The declared stream origin bounds its envelope.
        let unrelatedPrefix = try SourceInterval(
            epoch: origin.epoch, startSample: 0,
            sampleCount: origin.startSample + 384, sampleRate: origin.sampleRate)
        #expect(throws: JitterError.unexpectedContext) {
            try worker.result(
                atSourceSample: origin.startSample + 384,
                dependencyTiming: rollingJitterTiming(unrelatedPrefix))
        }
    }
}

@Test func jitterBatchRollingWindowAcceptsSampleGridRoundingButRejectsAnExtraSample() throws {
    let origin = try rollingJitterOrigin(rate: 16000)
    let configuration = try JitterConfiguration(
        sampleRate: 16000,
        applicability: .exploratoryRolling, rollingWindowSampleCount: 4096)
    let worker = try PreparedJitter(configuration: configuration, maximumPeriodCount: 1)
    let timing = try rollingJitterTiming(rollingJitterSupport(origin, end: 9499))
    let exact = try JitterQueryRange(startSeconds: 5403.0 / 16000, endSeconds: 9499.0 / 16000)
    let oversized = try JitterQueryRange(startSeconds: 5402.0 / 16000, endSeconds: 9499.0 / 16000)
    try [JitterPeriodInput]().withUnsafeBufferPointer { periods in
        let result = try worker.analyze(periods, dependencyTiming: timing, query: exact)
        #expect(result.query == exact)
        #expect(throws: JitterError.unexpectedContext) {
            try worker.analyze(periods, dependencyTiming: timing, query: oversized)
        }
    }
}

@Test func jitterRollingCapacityAndInvalidCallsAreAtomicAndResetStartsANewEpoch() throws {
    let origin = try rollingJitterOrigin()
    let configuration = try JitterConfiguration(
        sampleRate: 16384,
        applicability: .exploratoryRolling, rollingWindowSampleCount: 512)
    let worker = try PreparedRollingJitter(
        configuration: configuration, origin: origin,
        maximumPeriodCount: 2)
    let support = try rollingJitterSupport(origin, end: 256)
    let a = try JitterPeriodInput(startSeconds: 0, endSeconds: 128.0 / 16384)
    let b = try JitterPeriodInput(startSeconds: a.endSeconds, endSeconds: 256.0 / 16384)
    let c = try JitterPeriodInput(startSeconds: b.endSeconds, endSeconds: 384.0 / 16384)
    try worker.append(a, dependency: support)
    try worker.append(b, dependency: support)
    let before = worker.executionStatistics
    #expect(throws: JitterError.capacityExceeded) {
        try worker.append(c, dependency: rollingJitterSupport(origin, end: 384))
    }
    #expect(throws: JitterError.unexpectedContext) {
        try worker.append(a, dependency: rollingJitterSupport(origin, end: 4096))
    }
    let wrongEpoch = try rollingJitterOrigin()
    #expect(throws: JitterError.unexpectedContext) {
        try worker.append(c, dependency: rollingJitterSupport(wrongEpoch, end: 4096))
    }
    #expect(throws: JitterError.unexpectedContext) {
        try worker.append(c, dependency: support)
    }
    #expect(throws: JitterError.unexpectedContext) {
        try worker.requiredDependency(atSourceSample: 255)
    }
    #expect(throws: JitterError.unexpectedContext) {
        try worker.result(
            atSourceSample: 256,
            dependencyTiming: rollingJitterTiming(
                rollingJitterSupport(origin, start: 128, end: 256)))
    }
    #expect(throws: JitterError.unexpectedContext) { try worker.reset(origin: support) }
    #expect(worker.executionStatistics == before)
    let full = try worker.result(
        atSourceSample: 256, dependencyTiming: rollingJitterTiming(support))
    #expect(full.local.value == 0)
    let expiredSupport = try worker.requiredDependency(atSourceSample: 1024)
    #expect(expiredSupport.startSample == 512 && expiredSupport.sampleCount == 512)
    let expired = try worker.result(
        atSourceSample: 1024,
        dependencyTiming: rollingJitterTiming(expiredSupport))
    #expect(expired.local.value == nil && expired.local.unavailability == .stale)
    #expect(expired.coverage.acceptedPeriodCount == 0 && expired.coverage.durationCoverage == 0)
    #expect(throws: JitterError.unexpectedContext) {
        try worker.requiredDependency(atSourceSample: 1023)
    }
    let newOrigin = try SourceInterval(
        epoch: origin.epoch.successor(), startSample: 99,
        sampleCount: 0, sampleRate: origin.sampleRate)
    try worker.reset(origin: newOrigin)
    #expect(worker.executionStatistics.appendedPeriodCount == 0)
    #expect(worker.executionStatistics.analyzedQueryCount == 0)
    #expect(worker.executionStatistics.retainedInputCount == 0)
    #expect(worker.executionStatistics.sumTreeNodeUpdateCount == 0)
    try worker.append(a, dependency: rollingJitterSupport(newOrigin, end: 128))
    #expect(worker.origin == newOrigin)
    #expect(throws: JitterError.invalidConfiguration) {
        try PreparedRollingJitter(
            configuration: JitterConfiguration(sampleRate: 16384),
            origin: origin, maximumPeriodCount: 2)
    }
    #expect(throws: JitterError.capacityExceeded) {
        try PreparedRollingJitter(
            configuration: configuration, origin: origin, maximumPeriodCount: 0)
    }
}

@Test func jitterRollingDoesNotAccumulateSubtractionDriftOrStitchIndependentBlocks() throws {
    let origin = try rollingJitterOrigin()
    let configuration = try JitterConfiguration(
        sampleRate: 16384,
        applicability: .exploratoryRolling, rollingWindowSampleCount: 1024)
    let worker = try PreparedRollingJitter(
        configuration: configuration, origin: origin,
        maximumPeriodCount: 17)
    var cursor: Int64 = 0
    for i in 0..<10000 {
        let length: Int64 = i < 20 && i % 2 == 1 ? 80 : 64
        let start = cursor
        cursor += length
        let period = try JitterPeriodInput(
            startSeconds: Double(start) / 16384,
            endSeconds: Double(cursor) / 16384, runID: UInt64(i / 8))
        try worker.append(
            period, dependency: rollingJitterSupport(origin, start: start, end: cursor))
    }
    let dependency = try worker.requiredDependency(atSourceSample: cursor)
    let result = try worker.result(
        atSourceSample: cursor, dependencyTiming: rollingJitterTiming(dependency))
    #expect(result.coverage.selectedPeriodCount == 16)
    #expect(result.coverage.acceptedPairCount == 14)
    #expect(result.coverage.acceptedRAPNeighborhoodCount == 12)
    #expect(result.coverage.acceptedPPQ5NeighborhoodCount == 8)
    #expect(result.coverage.rejections.discontinuousPairs == 1)
    for variant in JitterVariant.allCases { #expect(result.estimate(variant).value == 0) }
    let excluded = try worker.result(
        atSourceSample: cursor,
        dependencyTiming: rollingJitterTiming(dependency, included: 0))
    #expect(
        excluded.coverage.selectedPeriodCount == 16 && excluded.coverage.acceptedPeriodCount == 0)
    #expect(excluded.coverage.meanPeriodCount == 0 && excluded.coverage.acceptedPairCount == 0)
    #expect(
        excluded.coverage.rejections.excluded == 16
            && excluded.coverage.rejections.discontinuousPairs == 15)
    for variant in JitterVariant.allCases {
        #expect(excluded.estimate(variant).unavailability == .excluded)
    }
    // A query exclusion is not a mutation of the original period flags.
    let restored = try worker.result(
        atSourceSample: cursor, dependencyTiming: rollingJitterTiming(dependency))
    #expect(restored == result)
}

@Test func jitterRollingDiagnosticsArePerQueryAndPreserveResults() throws {
    let origin = try rollingJitterOrigin()
    let configuration = try JitterConfiguration(
        sampleRate: 16384,
        applicability: .exploratoryRolling, rollingWindowSampleCount: 1024)
    var baseline: JitterAnalysisResult?
    for mode in DiagnosticMode.allCases {
        let sink = RecordingSink()
        let worker = try PreparedRollingJitter(
            configuration: configuration, origin: origin,
            maximumPeriodCount: 8, diagnostics: WorkerDiagnostics(mode: mode, sink: sink))
        let support = try rollingJitterSupport(origin, end: 512)
        for i in 0..<8 {
            try worker.append(
                JitterPeriodInput(
                    startSeconds: Double(i) / 256,
                    endSeconds: Double(i + 1) / 256), dependency: support)
        }
        #expect(sink.entries.allSatisfy { if case .begin = $0 { false } else { true } })
        for _ in 0..<17 {
            let result = try worker.result(
                atSourceSample: 512, dependencyTiming: rollingJitterTiming(support))
            if let baseline { #expect(result == baseline) } else { baseline = result }
        }
        let starts = sink.entries.compactMap { entry -> DiagnosticRecord? in
            if case .begin(let record) = entry { record } else { nil }
        }
        let ends = sink.entries.compactMap { entry -> DiagnosticRecord? in
            if case .end(let record) = entry { record } else { nil }
        }
        #expect(starts == ends)
        let expected: [UInt64] =
            mode == .disabled ? [] : mode == .sampled ? [0, 16] : Array(0..<17)
        #expect(starts.map(\.metadata.frameSequence) == expected)
        #expect(
            starts.allSatisfy {
                $0.stage == .perturbation && $0.metadata.profileToken == 50
                    && $0.metadata.sampleCount == 512 && $0.metadata.elapsedProcessingCount == 8
            })
    }
}

@Test func jitterRollingDistinguishesEmptyCrossingLongPeriodAndExpiredHistory() throws {
    let origin = try rollingJitterOrigin()
    let configuration = try JitterConfiguration(
        sampleRate: 16384,
        applicability: .exploratoryRolling, rollingWindowSampleCount: 128)
    let worker = try PreparedRollingJitter(
        configuration: configuration, origin: origin,
        maximumPeriodCount: 1)
    let empty = try worker.result(atSourceSample: 0, dependencyTiming: rollingJitterTiming(origin))
    #expect(empty.local.unavailability == .insufficientData)
    let long = try JitterPeriodInput(startSeconds: 0, endSeconds: 1)
    try worker.append(long, dependency: rollingJitterSupport(origin, end: 16384))
    let support = try worker.requiredDependency(atSourceSample: 16384)
    let crossing = try worker.result(
        atSourceSample: 16384, dependencyTiming: rollingJitterTiming(support))
    #expect(crossing.coverage.selectedPeriodCount == 0 && crossing.coverage.inputPeriodCount == 1)
    #expect(crossing.local.unavailability == .insufficientData)
    let staleSupport = try worker.requiredDependency(atSourceSample: 16384 + 128)
    let stale = try worker.result(
        atSourceSample: 16384 + 128,
        dependencyTiming: rollingJitterTiming(staleSupport))
    #expect(stale.local.unavailability == .stale)
    #expect(stale.coverage.acceptedPeriodDurationSeconds == 0)
}
