import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct JitterFixtureInput: Decodable {
    let name: String
    let pointsSeconds: [Double]
    let queryStartSeconds: Double
    let queryEndSeconds: Double
    let minimumPeriodSeconds: Double
    let maximumPeriodSeconds: Double
    let maximumAdjacentFactor: Double
}

private struct JitterFixture: Decodable {
    struct Oracle: Decodable {
        let selectedPeriodCount: Int
        let boundedPeriodCount: Int
        let meanPeriodCount: Int
        let pairIndices: [Int]
        let rapWindowStartIndices: [Int]
        let ppq5WindowStartIndices: [Int]
    }
    struct Reference: Decodable {
        let data: [String: Double?]
    }
    struct Comparison: Decodable {
        struct Bounds: Decodable { let seconds: Double; let fraction: Double }
        let bounds: Bounds
    }
    let input: JitterFixtureInput
    let oracle: Oracle
    let reference: Reference
    let comparison: Comparison
}

@Test func jitterNativeKernelMatchesEveryIndependentReferenceCase() throws {
    struct Manifest: Decodable { let catalog: [JitterFixtureInput] }
    let root = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Jitter")
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    #expect(manifest.catalog.count == 69)
    for input in manifest.catalog {
        let fixture = try JSONDecoder().decode(
            JitterFixture.self,
            from: Data(contentsOf: root.appendingPathComponent(input.name + ".json")))
        let configuration = try JitterConfiguration(
            sampleRate: 16000, minimumPeriodSeconds: input.minimumPeriodSeconds,
            maximumPeriodSeconds: input.maximumPeriodSeconds,
            maximumAdjacentPeriodFactor: input.maximumAdjacentFactor)
        let periods = zip(input.pointsSeconds, input.pointsSeconds.dropFirst()).enumerated().map {
            index, pair in
            JitterKernelPeriod(
                durationSeconds: pair.1 - pair.0,
                selected: pair.0 >= input.queryStartSeconds && pair.1 <= input.queryEndSeconds,
                reliable: true, connectsToPrevious: index > 0)
        }
        let combined = periods.withUnsafeBufferPointer {
            JitterKernel.evaluate($0, configuration: configuration)
        }
        #expect(combined.selectedPeriodCount == fixture.oracle.selectedPeriodCount, "\(input.name)")
        #expect(combined.boundedReliablePeriodCount == fixture.oracle.boundedPeriodCount, "\(input.name)")
        #expect(combined.meanPeriodCount == fixture.oracle.meanPeriodCount, "\(input.name)")
        #expect(combined.pairCount == fixture.oracle.pairIndices.count, "\(input.name)")
        #expect(combined.rapCount == fixture.oracle.rapWindowStartIndices.count, "\(input.name)")
        #expect(combined.ppq5Count == fixture.oracle.ppq5WindowStartIndices.count, "\(input.name)")
        let expectedMean = fixture.reference.data["meanPeriod"] ?? nil
        #expect((combined.meanPeriodSeconds == nil) == (expectedMean == nil), "\(input.name)")
        if let a = combined.meanPeriodSeconds, let b = expectedMean {
            #expect(abs(a - b) <= fixture.comparison.bounds.seconds, "\(input.name)")
        }
        for variant in JitterVariant.allCases {
            let expected = fixture.reference.data[variant.rawValue] ?? nil
            let actual = combined.value(variant)
            #expect((actual == nil) == (expected == nil), "\(input.name) \(variant)")
            if let actual, let expected {
                let bound = variant == .absolute
                    ? fixture.comparison.bounds.seconds : fixture.comparison.bounds.fraction
                #expect(abs(actual - expected) <= bound, "\(input.name) \(variant)")
            }
            let separate = periods.withUnsafeBufferPointer {
                JitterKernel.evaluate($0, configuration: configuration, requested: .init(variant))
            }
            #expect(separate.value(variant) == actual, "\(input.name) \(variant)")
            for unrequested in JitterVariant.allCases where unrequested != variant {
                #expect(separate.value(unrequested) == nil)
            }
        }
        if let rap = combined.rap { #expect(combined.ddp == 3 * rap) }
    }
}

@Test func jitterNativeKernelPreservesReliabilityAndRunBreaks() throws {
    let configuration = try JitterConfiguration(sampleRate: 16000)
    let durations = [2.0, 2.125, 2, 2.125, 2, 2.125, 2].map { $0 / 256 }
    let original = durations.enumerated().map {
        JitterKernelPeriod(durationSeconds: $1, selected: true, reliable: true, connectsToPrevious: $0 > 0)
    }
    for mode in 0..<3 {
        var periods = original
        switch mode {
        case 0: periods[3].reliable = false
        case 1: periods[3].connectsToPrevious = false
        default: periods[3].selected = false
        }
        let result = periods.withUnsafeBufferPointer {
            JitterKernel.evaluate($0, configuration: configuration)
        }
        #expect(result.pairCount == (mode == 1 ? 5 : 4))
        #expect(result.rapCount == (mode == 1 ? 3 : 2))
        #expect(result.ppq5Count == 0)
        #expect(result.meanPeriodCount == (mode == 1 ? 7 : 6))
        #expect(result.unreliablePeriodCount == (mode == 0 ? 1 : 0))
    }
}

@Test func jitterNativeKernelDistinguishesRawRatioContextFromHardExclusions() throws {
    let configuration = try JitterConfiguration(sampleRate: 16000)
    let original = [2.0, 1, 2].enumerated().map {
        JitterKernelPeriod(durationSeconds: $1 / 256, selected: $0 == 1, reliable: true, connectsToPrevious: $0 > 0)
    }
    let raw = original.withUnsafeBufferPointer { JitterKernel.evaluate($0, configuration: configuration) }
    #expect(raw.selectedPeriodCount == 1 && raw.boundedReliablePeriodCount == 1)
    #expect(raw.meanPeriodCount == 0 && raw.bothRatioRejectedPeriodCount == 1)
    var excluded = original
    excluded[0].reliable = false
    let result = excluded.withUnsafeBufferPointer { JitterKernel.evaluate($0, configuration: configuration) }
    #expect(result.meanPeriodCount == 1 && result.meanPeriodSeconds == 1 / 256)
    #expect(result.local == nil && result.absolute == nil)
}
