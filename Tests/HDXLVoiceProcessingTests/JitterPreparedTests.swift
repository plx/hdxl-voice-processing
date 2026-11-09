import Foundation
import Testing

@testable import HDXLVoiceProcessing

private func jitterTestPeriods(
    _ units: [Double], rejections: JitterPeriodRejections = [], separateRuns: Bool = false
) throws -> [JitterPeriodInput] {
    var time = 0.0
    return try units.enumerated().map { index, unit in
        let next = time + unit / 256
        defer { time = next }
        return try JitterPeriodInput(
            startSeconds: time, endSeconds: next, runID: separateRuns ? UInt64(index) : 0,
            rejections: rejections)
    }
}

private func jitterTestTiming(
    end: Double = 0.125, start: Int64 = 0, included: Int64? = nil, anchor: Double? = nil
) throws -> AnalysisTiming {
    let count = Int64(ceil(end * 16000))
    return try AnalysisTiming(
        source: SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: start,
            sampleCount: count, sampleRate: 16000), includedSampleCount: included ?? count,
        sourceStartSeconds: anchor, hostStartNanoseconds: 123, completedHostNanoseconds: 456)
}

@Test func jitterPreparedAPIReplaysAllIndependentCasesWithExactQueryBounds() throws {
    struct Input: Decodable {
        let name: String
        let pointsSeconds: [Double]
        let domainEndSeconds: Double
        let queryStartSeconds: Double
        let queryEndSeconds: Double
        let minimumPeriodSeconds: Double
        let maximumPeriodSeconds: Double
        let maximumAdjacentFactor: Double
    }
    struct Manifest: Decodable { let catalog: [Input] }
    struct Fixture: Decodable {
        struct Reference: Decodable { let data: [String: Double?] }
        struct Comparison: Decodable {
            struct Bounds: Decodable {
                let seconds: Double
                let fraction: Double
            }
            let bounds: Bounds
        }
        let reference: Reference
        let comparison: Comparison
    }
    let directory = try #require(Bundle.module.resourceURL).appendingPathComponent(
        "Fixtures/Jitter")
    let catalog = try JSONDecoder().decode(
        Manifest.self,
        from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    ).catalog
    #expect(catalog.count == 69)
    for input in catalog {
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: directory.appendingPathComponent(input.name + ".json")))
        let configuration = try JitterConfiguration(
            sampleRate: 16000,
            minimumPeriodSeconds: input.minimumPeriodSeconds,
            maximumPeriodSeconds: input.maximumPeriodSeconds,
            maximumAdjacentPeriodFactor: input.maximumAdjacentFactor)
        let worker = try PreparedJitter(
            configuration: configuration, maximumPeriodCount: max(1, input.pointsSeconds.count))
        let periods = try zip(input.pointsSeconds, input.pointsSeconds.dropFirst()).map {
            try JitterPeriodInput(startSeconds: $0, endSeconds: $1)
        }
        let timing = try jitterTestTiming(end: input.domainEndSeconds + 1 / 16000)
        let query = try JitterQueryRange(
            startSeconds: input.queryStartSeconds, endSeconds: input.queryEndSeconds)
        let result = try periods.withUnsafeBufferPointer {
            try worker.analyze($0, dependencyTiming: timing, query: query)
        }
        #expect(result.profile == (try configuration.identity()))
        #expect(result.query == query && result.dependencyTiming == timing)
        #expect(
            result.coverage.meanPeriodCount
                == Int(try #require(fixture.reference.data["periodCount"] ?? nil)))
        for variant in JitterVariant.allCases {
            let expected = fixture.reference.data[variant.rawValue] ?? nil
            let estimate = result.estimate(variant)
            #expect(
                estimate.status == (expected == nil ? .unavailable : .available),
                "\(input.name) \(variant)")
            if let value = estimate.value, let expected {
                let tolerance =
                    variant == .absolute
                    ? fixture.comparison.bounds.seconds : fixture.comparison.bounds.fraction
                #expect(abs(value - expected) <= tolerance, "\(input.name) \(variant)")
            }
            let separate = try periods.withUnsafeBufferPointer {
                try worker.analyze(variant, periods: $0, dependencyTiming: timing, query: query)
            }
            #expect(separate.estimate(variant) == estimate)
            #expect(separate.coverage == result.coverage)
            for other in JitterVariant.allCases where other != variant {
                #expect(separate.estimate(other).status == .notRequested)
                #expect(throws: JitterError.measurementNotRequested) {
                    try separate.measurementResult(other)
                }
            }
        }
    }
}

@Test func jitterCoverageAndUnavailableReasonsRemainDistinctFromZero() throws {
    let worker = try PreparedJitter(
        configuration: JitterConfiguration(sampleRate: 16000), maximumPeriodCount: 20)
    let timing = try jitterTestTiming(end: 0.046875)
    let constant = try jitterTestPeriods(Array(repeating: 2, count: 6))
    let zero = try constant.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing)
    }
    #expect(zero.coverage.durationCoverage == 1 && zero.coverage.acceptedPeriodCount == 6)
    #expect(zero.coverage.acceptedPairCount == 5 && zero.coverage.acceptedRAPNeighborhoodCount == 4)
    #expect(zero.coverage.acceptedPPQ5NeighborhoodCount == 2)
    for variant in JitterVariant.allCases { #expect(zero.estimate(variant).value == 0) }
    let empty = try [JitterPeriodInput]().withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing)
    }
    #expect(empty.coverage.durationCoverage == 0 && empty.coverage.acceptedPeriodCount == 0)
    for variant in JitterVariant.allCases {
        #expect(
            empty.estimate(variant).value == nil
                && empty.estimate(variant).unavailability == .insufficientData)
    }
    for (rejection, reason) in [
        (JitterPeriodRejections.excluded, UnavailabilityReason.excluded),
        (.discontinuity, .discontinuity),
        (.unreliable, .lowConfidence), (.missingAcquisition, .missingAcquisition),
        (.invalidInput, .invalidInput), (.silence, .silence),
    ] {
        let periods = try jitterTestPeriods(Array(repeating: 2, count: 6), rejections: rejection)
        let result = try periods.withUnsafeBufferPointer {
            try worker.analyze($0, dependencyTiming: timing)
        }
        #expect(
            result.coverage.selectedPeriodCount == 6 && result.coverage.acceptedPeriodCount == 0)
        for variant in JitterVariant.allCases {
            #expect(result.estimate(variant).unavailability == reason)
        }
    }
    let excludedTiming = try jitterTestTiming(end: 0.046875, included: 0)
    let excluded = try constant.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: excludedTiming)
    }
    #expect(
        excluded.coverage.acceptedPeriodCount == 0 && excluded.coverage.rejections.excluded == 6)
    #expect(excluded.local.unavailability == .excluded)
    let silence = try [JitterPeriodInput]().withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing, sourceUnavailability: .silence)
    }
    #expect(silence.local.unavailability == .silence)
}

@Test func jitterRejectedBoundsRatiosAndExplicitRunsExplainMissingNeighborhoods() throws {
    let worker = try PreparedJitter(
        configuration: JitterConfiguration(sampleRate: 16000), maximumPeriodCount: 20)
    let tooLong = try jitterTestPeriods(Array(repeating: 8, count: 6))
    let bounds = try tooLong.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: jitterTestTiming(end: 0.2))
    }
    #expect(
        bounds.coverage.rejections.aboveMaximum == 6
            && bounds.local.unavailability == .unsupportedRange)
    let alternating = try jitterTestPeriods([2, 4, 2, 4, 2, 4])
    let ratios = try alternating.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: jitterTestTiming())
    }
    #expect(ratios.coverage.acceptedPeriodCount == 6 && ratios.coverage.meanPeriodCount == 2)
    #expect(
        ratios.coverage.rejections.ratioPairs == 5 && ratios.local.unavailability == .lowConfidence)
    let runs = try jitterTestPeriods(Array(repeating: 2, count: 6), separateRuns: true)
    let separated = try runs.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: jitterTestTiming())
    }
    #expect(separated.coverage.rejections.discontinuousPairs == 5)
    #expect(
        separated.coverage.acceptedPairCount == 0
            && separated.local.unavailability == .discontinuity)
}

@Test func jitterExportPreservesQueryContextUnitsCoverageAndLargeSourceOrigins() throws {
    let configuration = try JitterConfiguration(
        sampleRate: 16000, applicability: .exploratoryRolling, rollingWindowSampleCount: 16000)
    let worker = try PreparedJitter(configuration: configuration, maximumPeriodCount: 20)
    let periods = try jitterTestPeriods([2, 2.25, 2, 2.25, 2, 2.25])
    let timing = try jitterTestTiming(start: Int64.max - 10000, anchor: 42)
    let query = try JitterQueryRange(
        startSeconds: periods[1].startSeconds, endSeconds: periods[4].endSeconds)
    let result = try periods.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing, query: query)
    }
    #expect(result.dependencyTiming.source.startSample == Int64.max - 10000)
    #expect(result.queryCenterSourceSeconds == 42 + query.centerSeconds)
    #expect(result.dependencyTiming.includedSampleCount == timing.source.sampleCount)
    let fraction = try result.measurementResult(.local)
    let percent = try result.measurementResult(.local, unit: .percent)
    #expect(fraction.timing == timing && percent.timing == timing)
    guard case .available(let f) = fraction.outcome, case .available(let p) = percent.outcome else {
        Issue.record("Expected available relative jitter")
        return
    }
    #expect(p.value == f.value * 100 && p.warnings.contains(.exploratoryApplicability))
    #expect(fraction.measurement.unit == .fraction && percent.measurement.unit == .percent)
    #expect(throws: ContractError.invalidUnit) {
        try result.measurementResult(.absolute, unit: .percent)
    }
    #expect(throws: ContractError.invalidUnit) {
        try result.measurementResult(.local, unit: .seconds)
    }
    let json = try #require(
        JSONSerialization.jsonObject(with: result.canonicalJSON()) as? [String: Any])
    let encodedQuery = try #require(json["query"] as? [String: Double])
    #expect(
        encodedQuery["startSeconds"] == query.startSeconds
            && encodedQuery["endSeconds"] == query.endSeconds)
    #expect(
        json["coverage"] != nil && json["inputProvenance"] != nil && json["dependencyTiming"] != nil
    )
}

@Test func jitterInvalidCallsDoNotChangeExecutionStateOrPoisonReuse() throws {
    let worker = try PreparedJitter(
        configuration: JitterConfiguration(sampleRate: 16000), maximumPeriodCount: 6)
    let periods = try jitterTestPeriods(Array(repeating: 2, count: 6))
    let timing = try jitterTestTiming()
    let original = try periods.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing)
    }
    let before = worker.executionStatistics
    let overlap = [periods[1], periods[0]]
    #expect(throws: JitterError.invalidInput) {
        try overlap.withUnsafeBufferPointer { try worker.analyze($0, dependencyTiming: timing) }
    }
    #expect(throws: JitterError.capacityExceeded) {
        try (periods + [periods[0]]).withUnsafeBufferPointer {
            try worker.analyze($0, dependencyTiming: timing)
        }
    }
    #expect(throws: JitterError.unexpectedContext) {
        try periods.withUnsafeBufferPointer {
            try worker.analyze(
                $0, dependencyTiming: timing,
                query: JitterQueryRange(startSeconds: 0, endSeconds: 1))
        }
    }
    #expect(worker.executionStatistics == before)
    let after = try periods.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing)
    }
    #expect(after == original)
    try worker.reset()
    #expect(
        worker.executionStatistics.analyzedQueryCount == 0
            && worker.executionStatistics.lastInputPeriodCount == 0)
}

@Test func jitterInputDecodingAndAcquisitionBoundaryValidationAreStrict() throws {
    for (start, end) in [
        (0.0, 0.0), (1, 0), (.nan, 1), (0, .infinity),
        (-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
    ] {
        #expect(throws: JitterError.invalidInput) {
            try JitterPeriodInput(startSeconds: start, endSeconds: end)
        }
    }
    #expect(throws: JitterError.invalidInput) {
        try JitterPeriodInput(startSeconds: 0, endSeconds: 0.01, rejections: .init(rawValue: 128))
    }
    let period = try JitterPeriodInput(startSeconds: 0, endSeconds: 0.01)
    #expect(
        try JSONDecoder().decode(JitterPeriodInput.self, from: canonicalContractJSON(period))
            == period)
    var json = try #require(
        JSONSerialization.jsonObject(with: canonicalContractJSON(period)) as? [String: Any])
    json["extra"] = 1
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            JitterPeriodInput.self, from: JSONSerialization.data(withJSONObject: json))
    }
    let worker = try PreparedJitter(
        configuration: JitterConfiguration(sampleRate: 16000), maximumPeriodCount: 3)
    let outside = try JitterPeriodInput(startSeconds: -0.01, endSeconds: 0.005)
    let timing = try jitterTestTiming()
    #expect(throws: JitterError.unexpectedContext) {
        try [outside].withUnsafeBufferPointer { try worker.analyze($0, dependencyTiming: timing) }
    }
    let flagged = try JitterPeriodInput(
        startSeconds: -0.01, endSeconds: 0.005, rejections: .missingAcquisition)
    let result = try [flagged].withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing)
    }
    #expect(result.coverage.inputPeriodCount == 1 && result.coverage.selectedPeriodCount == 0)
}
