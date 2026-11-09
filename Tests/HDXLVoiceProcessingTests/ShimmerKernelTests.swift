import Foundation
import Testing

@testable import HDXLVoiceProcessing

struct ShimmerFixtureInput: Decodable {
    let name: String
    let timesSeconds: [Double]
    let amplitudes: [Double]
    let domainEndSeconds: Double
    let queryStartSeconds: Double
    let queryEndSeconds: Double
    let minimumPeriodSeconds: Double
    let maximumPeriodSeconds: Double
    let maximumAmplitudeFactor: Double
}

struct ShimmerFixture: Decodable {
    struct Oracle: Decodable {
        let selectedAmplitudeCount: Int
        let normalizationCount: Int
        let meanAmplitude: Double?
        let zeroAmplitudeCount: Int
        let pairStartIndices: [Int]
        let apq3WindowStartIndices: [Int]
        let apq5WindowStartIndices: [Int]
        let apq11WindowStartIndices: [Int]
    }
    struct Reference: Decodable { let data: [String: Double?] }
    struct Comparison: Decodable { let bounds: [String: Double] }
    let input: ShimmerFixtureInput
    let oracle: Oracle
    let reference: Reference
    let comparison: Comparison
}

func shimmerFixtures() throws -> [ShimmerFixture] {
    struct Manifest: Decodable { let catalog: [ShimmerFixtureInput] }
    let root = try #require(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Shimmer")
    let manifest = try JSONDecoder().decode(
        Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    return try manifest.catalog.map {
        try JSONDecoder().decode(
            ShimmerFixture.self,
            from: Data(contentsOf: root.appendingPathComponent($0.name + ".json")))
    }
}

@Test func shimmerKernelMatchesEveryIndependentReferenceCase() throws {
    let fixtures = try shimmerFixtures()
    #expect(fixtures.count == 94)
    for fixture in fixtures {
        let input = fixture.input
        let configuration = try ShimmerConfiguration(
            sampleRate: 16000,
            minimumPeriodSeconds: input.minimumPeriodSeconds,
            maximumPeriodSeconds: input.maximumPeriodSeconds,
            maximumAmplitudeFactor: input.maximumAmplitudeFactor)
        let records = input.timesSeconds.indices.map { i in
            ShimmerKernelAmplitude(
                timeSeconds: input.timesSeconds[i], amplitude: input.amplitudes[i],
                selected: (input.queryStartSeconds...input.queryEndSeconds).contains(
                    input.timesSeconds[i]),
                reliable: true, connectsToPrevious: i > 0)
        }
        let combined = records.withUnsafeBufferPointer {
            ShimmerKernel.evaluate($0, configuration: configuration)
        }
        #expect(
            combined.selectedAmplitudeCount == fixture.oracle.selectedAmplitudeCount,
            "\(input.name)")
        #expect(
            combined.acceptedAmplitudeCount == fixture.oracle.selectedAmplitudeCount,
            "\(input.name)")
        #expect(combined.normalizationCount == fixture.oracle.normalizationCount, "\(input.name)")
        #expect(combined.zeroAmplitudeCount == fixture.oracle.zeroAmplitudeCount, "\(input.name)")
        #expect(combined.pairCount == fixture.oracle.pairStartIndices.count, "\(input.name)")
        #expect(combined.apq3Count == fixture.oracle.apq3WindowStartIndices.count, "\(input.name)")
        #expect(combined.apq5Count == fixture.oracle.apq5WindowStartIndices.count, "\(input.name)")
        #expect(
            combined.apq11Count == fixture.oracle.apq11WindowStartIndices.count, "\(input.name)")
        #expect(
            (combined.meanAmplitude == nil) == (fixture.oracle.meanAmplitude == nil),
            "\(input.name)")
        if let a = combined.meanAmplitude, let b = fixture.oracle.meanAmplitude {
            #expect(abs(a - b) <= 4 * b.ulp, "\(input.name)")
        }
        for variant in ShimmerVariant.allCases {
            let actual = combined.value(variant)
            let expected = fixture.reference.data[variant.rawValue] ?? nil
            #expect((actual == nil) == (expected == nil), "\(input.name) \(variant)")
            if let actual, let expected {
                let bound = try #require(fixture.comparison.bounds[variant.rawValue])
                #expect(
                    abs(actual - expected) <= bound,
                    "\(input.name) \(variant): \(actual) vs \(expected)")
            }
            let separate = records.withUnsafeBufferPointer {
                ShimmerKernel.evaluate($0, configuration: configuration, requested: .init(variant))
            }
            #expect(separate.value(variant) == actual, "\(input.name) \(variant)")
            for other in ShimmerVariant.allCases where other != variant {
                #expect(separate.value(other) == nil)
            }
        }
        if let apq3 = combined.apq3 { #expect(combined.dda == 3 * apq3) }
    }
}

@Test func shimmerKernelPreservesMissingRecordsAndRunBreaks() throws {
    let configuration = try ShimmerConfiguration(sampleRate: 16000)
    let original = (0..<13).map {
        ShimmerKernelAmplitude(
            timeSeconds: Double($0) / 128, amplitude: 1 + Double($0 % 2) / 4,
            selected: true, reliable: true, connectsToPrevious: $0 > 0)
    }
    for mode in 0..<3 {
        var records = original
        switch mode {
        case 0: records[6].reliable = false
        case 1: records[6].connectsToPrevious = false
        default: records[6].selected = false
        }
        let result = records.withUnsafeBufferPointer {
            ShimmerKernel.evaluate($0, configuration: configuration)
        }
        #expect(result.pairCount == (mode == 1 ? 11 : 10))
        #expect(result.apq3Count == (mode == 1 ? 9 : 8))
        #expect(result.apq5Count == (mode == 1 ? 5 : 4))
        #expect(result.apq11Count == 0)
        #expect(result.normalizationCount == (mode == 1 ? 12 : 11))
    }
}

@Test func shimmerScalingAvoidsOverflowAndDoesNotFabricateZeroEnergy() throws {
    let configuration = try ShimmerConfiguration(sampleRate: 16000, maximumAmplitudeFactor: 2)
    for scale in [
        Double.leastNonzeroMagnitude, 1e-300, 1.0, 1e300, Double.greatestFiniteMagnitude / 2,
    ] {
        let records = [1.0, 2.0, 1.0].enumerated().map {
            ShimmerKernelAmplitude(
                timeSeconds: Double($0.offset) / 128, amplitude: $0.element * scale,
                selected: true, reliable: true, connectsToPrevious: $0.offset > 0)
        }
        let result = records.withUnsafeBufferPointer {
            ShimmerKernel.evaluate($0, configuration: configuration)
        }
        #expect(abs(try #require(result.local) - 2 / 3) < 2e-15)
        #expect(abs(try #require(result.apq3) - 4 / 9) < 2e-15)
        #expect(abs(try #require(result.db) - 20 * log10(2)) < 2e-14)
    }
    let tiny = [Double.leastNonzeroMagnitude, Double.leastNonzeroMagnitude, 0, 0, 0, 0]
    let records = tiny.enumerated().map {
        ShimmerKernelAmplitude(
            timeSeconds: Double($0.offset) / 128, amplitude: $0.element,
            selected: true, reliable: true, connectsToPrevious: $0.offset > 0)
    }
    let result = records.withUnsafeBufferPointer {
        ShimmerKernel.evaluate($0, configuration: configuration)
    }
    #expect(result.meanAmplitude == nil)
    #expect(result.normalizationScale > 0 && result.scaledMeanAmplitude == 0.4)
    #expect(result.local == 0 && result.db == 0)
}
