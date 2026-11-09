import Foundation
import Testing

@testable import HDXLVoiceProcessing

func shimmerTestTiming(
    end: Double = 0.125, start: Int64 = 0, included: Int64? = nil,
    anchor: Double? = nil
) throws -> AnalysisTiming {
    let count = Int64(ceil(end * 16000))
    return try AnalysisTiming(
        source: SourceInterval(
            epoch: StreamEpoch(streamID: UUID()),
            startSample: start, sampleCount: count, sampleRate: 16000),
        includedSampleCount: included ?? count, sourceStartSeconds: anchor,
        hostStartNanoseconds: 123, completedHostNanoseconds: 456)
}

func shimmerTestAmplitudes(_ values: [Double], rejections: ShimmerAmplitudeRejections = []) throws
    -> [ShimmerAmplitudeInput]
{
    try values.enumerated().map {
        try ShimmerAmplitudeInput(
            timeSeconds: Double($0.offset) / 128, amplitude: $0.element,
            sequenceIndex: UInt64($0.offset), rejections: rejections)
    }
}

@Test func shimmerPreparedAPIReplaysReferenceQueriesWithCoverageAndSeparateVariants() throws {
    for fixture in try shimmerFixtures() {
        let input = fixture.input
        let configuration = try ShimmerConfiguration(
            sampleRate: 16000,
            minimumPeriodSeconds: input.minimumPeriodSeconds,
            maximumPeriodSeconds: input.maximumPeriodSeconds,
            maximumAmplitudeFactor: input.maximumAmplitudeFactor)
        let worker = try PreparedShimmer(
            configuration: configuration, maximumAmplitudeCount: max(1, input.amplitudes.count))
        let records = try input.amplitudes.indices.map {
            try ShimmerAmplitudeInput(
                timeSeconds: input.timesSeconds[$0], amplitude: input.amplitudes[$0],
                sequenceIndex: UInt64($0))
        }
        let timing = try shimmerTestTiming(end: input.domainEndSeconds + 1 / 16000)
        let query = try ShimmerQueryRange(
            startSeconds: input.queryStartSeconds, endSeconds: input.queryEndSeconds)
        let result = try records.withUnsafeBufferPointer {
            try worker.analyze($0, dependencyTiming: timing, query: query)
        }
        #expect(result.profile == (try configuration.identity()))
        #expect(result.query == query && result.dependencyTiming == timing)
        #expect(result.coverage.normalizationAmplitudeCount == fixture.oracle.normalizationCount)
        #expect(result.coverage.acceptedPairCount == fixture.oracle.pairStartIndices.count)
        #expect(
            result.coverage.acceptedAPQ11NeighborhoodCount
                == fixture.oracle.apq11WindowStartIndices.count)
        for variant in ShimmerVariant.allCases {
            let expected = fixture.reference.data[variant.rawValue] ?? nil
            let estimate = result.estimate(variant)
            #expect(
                estimate.status == (expected == nil ? .unavailable : .available),
                "\(input.name) \(variant)")
            if let value = estimate.value, let expected {
                #expect(
                    abs(value - expected)
                        <= (try #require(fixture.comparison.bounds[variant.rawValue])))
            }
            let separate = try records.withUnsafeBufferPointer {
                try worker.analyze(variant, amplitudes: $0, dependencyTiming: timing, query: query)
            }
            #expect(separate.estimate(variant) == estimate && separate.coverage == result.coverage)
            for other in ShimmerVariant.allCases where other != variant {
                #expect(separate.estimate(other).status == .notRequested)
                #expect(throws: ShimmerError.measurementNotRequested) {
                    try separate.measurementResult(other)
                }
            }
        }
    }
}

@Test func shimmerPreparedDistinguishesZeroUnavailableAndNormalizationExclusions() throws {
    let worker = try PreparedShimmer(
        configuration: ShimmerConfiguration(sampleRate: 16000), maximumAmplitudeCount: 20)
    let timing = try shimmerTestTiming()
    for (values, reasons, expected) in [
        ([Double](), ShimmerAmplitudeRejections(), UnavailabilityReason.insufficientData),
        (Array(repeating: 0.0, count: 13), [], .silence),
        (Array(repeating: 1.0, count: 13), .excluded, .excluded),
        (Array(repeating: 1.0, count: 13), .invalidInput, .invalidInput),
        (Array(repeating: 1.0, count: 13), .missingAcquisition, .missingAcquisition),
    ] {
        let amplitudes = try shimmerTestAmplitudes(values, rejections: reasons)
        let result = try amplitudes.withUnsafeBufferPointer {
            try worker.analyze($0, dependencyTiming: timing)
        }
        #expect(result.local.status == .unavailable && result.local.value == nil)
        #expect(result.local.unavailability == expected)
    }
    let constant = try shimmerTestAmplitudes(Array(repeating: 1, count: 13))
    let result = try constant.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing)
    }
    for variant in ShimmerVariant.allCases { #expect(result.estimate(variant).value == 0) }
    #expect(result.coverage.normalizationAmplitudeCount == 12)
    #expect(result.coverage.acceptedAPQ11NeighborhoodCount == 3)
    #expect(result.coverage.acceptedPairDurationSeconds == 12.0 / 128)
    #expect(result.coverage.durationCoverage == 0.75)
    let excludedTiming = try shimmerTestTiming(included: 0)
    let excluded = try constant.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: excludedTiming)
    }
    #expect(excluded.local.unavailability == .excluded)
    #expect(excluded.coverage.normalizationAmplitudeCount == 0)
}

@Test func shimmerPreparedNeverReconnectsDroppedSequenceIndicesOrReusedRunIDs() throws {
    let worker = try PreparedShimmer(
        configuration: ShimmerConfiguration(sampleRate: 16000), maximumAmplitudeCount: 20)
    let timing = try shimmerTestTiming()
    for mode in 0..<3 {
        let records: [ShimmerAmplitudeInput] = try (0..<13).map { i in
            let amplitude: Double? = mode == 2 && i == 6 ? nil : 1
            let sequenceIndex = UInt64(i + (mode == 0 && i >= 6 ? 1 : 0))
            let runID: UInt64 = mode == 1 && i == 6 ? 1 : 0
            let reasons: ShimmerAmplitudeRejections = mode == 2 && i == 6 ? .unreliable : []
            return try ShimmerAmplitudeInput(
                timeSeconds: Double(i) / 128,
                amplitude: amplitude, sequenceIndex: sequenceIndex, runID: runID,
                rejections: reasons)
        }
        let result = try records.withUnsafeBufferPointer {
            try worker.analyze($0, dependencyTiming: timing)
        }
        #expect(result.coverage.acceptedAPQ11NeighborhoodCount == 0)
        #expect(result.apq11.unavailability == .discontinuity)
        #expect(result.coverage.acceptedPairCount == (mode == 0 ? 11 : 10))
        #expect(result.coverage.normalizationAmplitudeCount == (mode == 2 ? 11 : 12))
    }
}

@Test func shimmerInvalidCallsAreRetryableAndInputCannotMisstateMissingValues() throws {
    let worker = try PreparedShimmer(
        configuration: ShimmerConfiguration(sampleRate: 16000), maximumAmplitudeCount: 3)
    let timing = try shimmerTestTiming()
    for value in [-1.0, .nan, .infinity] {
        #expect(throws: ShimmerError.invalidInput) {
            try ShimmerAmplitudeInput(timeSeconds: 0, amplitude: value, sequenceIndex: 0)
        }
    }
    #expect(throws: ShimmerError.invalidInput) {
        try ShimmerAmplitudeInput(timeSeconds: 0, amplitude: nil, sequenceIndex: 0)
    }
    #expect(throws: ShimmerError.invalidInput) {
        try ShimmerAmplitudeInput(
            timeSeconds: 0, amplitude: 1, sequenceIndex: 0, rejections: .init(rawValue: 1 << 15))
    }
    let oversized = try shimmerTestAmplitudes([1, 1, 1, 1])
    #expect(throws: ShimmerError.capacityExceeded) {
        try oversized.withUnsafeBufferPointer { try worker.analyze($0, dependencyTiming: timing) }
    }
    let records = try shimmerTestAmplitudes([1, 1, 1])
    let duplicate = [records[0], records[0]]
    #expect(throws: ShimmerError.invalidInput) {
        try duplicate.withUnsafeBufferPointer { try worker.analyze($0, dependencyTiming: timing) }
    }
    #expect(worker.executionStatistics.analyzedQueryCount == 0)
    let result = try records.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing)
    }
    #expect(result.local.value == 0 && worker.executionStatistics.analyzedQueryCount == 1)
    try worker.reset()
    #expect(worker.executionStatistics.analyzedQueryCount == 0)
}

@Test func shimmerExportKeepsUnitsTimingAndExploratoryApplicability() throws {
    let configuration = try ShimmerConfiguration(
        sampleRate: 16000, applicability: .exploratoryRolling, rollingWindowSampleCount: 2000)
    let worker = try PreparedShimmer(configuration: configuration, maximumAmplitudeCount: 13)
    let records = try shimmerTestAmplitudes((0..<13).map { 1 + Double($0 % 2) / 4 })
    let timing = try shimmerTestTiming(start: Int64.max - 2000, anchor: 20)
    let result = try records.withUnsafeBufferPointer {
        try worker.analyze($0, dependencyTiming: timing)
    }
    #expect(result.queryCenterSourceSeconds == 20.0625)
    let scalar = try result.measurementResult(.local, unit: .percent)
    #expect(scalar.timing == timing && scalar.profile == result.profile)
    let value = try #require(scalar.outcome.estimate)
    #expect(value.value == (try #require(result.local.value)) * 100)
    #expect(
        value.warnings.contains(.exploratoryApplicability)
            && value.warnings.contains(.partialCoverage))
    #expect(try result.measurementResult(.db).measurement.unit == .decibelsRatio)
    #expect(throws: ContractError.invalidUnit) { try result.measurementResult(.db, unit: .percent) }
    let data = try result.canonicalJSON()
    #expect(data == (try result.canonicalJSON()))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["coverage"] != nil && object["inputProvenance"] != nil && object["query"] != nil)
}
