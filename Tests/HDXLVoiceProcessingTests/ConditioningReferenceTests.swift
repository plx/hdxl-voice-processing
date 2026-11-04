import CryptoKit
import Foundation
import HDXLVoiceProcessing
import Testing

private struct ConditioningFixture: Decodable {
    struct Recipe: Decodable {
        let kind: String
        let count: Int
        let rate: Int
        let frequency: Double?
        let gain: Double?
        let seed: UInt32?
    }
    struct Expected: Decodable {
        let sampleCount: Int
        let sampleRate: Double
        let domainEndSeconds: Double
        let firstSampleCenterSeconds: Double
        let indices: [Int]
        let resampled: [Double]
        let conditioned: [Double]
    }
    struct Case: Decodable {
        let name: String
        let inputRecipe: Recipe
        let targetRate: Int
        let interpolationDepth: Int
        let preEmphasisFromHz: Double?
        let precision: AnalysisPrecision
        let input: [Double]?
        let inputSHA256: String
        let maximumAbsoluteError: Double
        let maximumAxisErrorSeconds: Double
        let expected: Expected
    }
    let cases: [Case]
}

private func conditioningSource<S: BinaryFloatingPoint & Sendable>(
    _ item: ConditioningFixture.Case, type: S.Type
) throws -> [S] {
    if let input = item.input { return input.map { S($0) } }
    let recipe = item.inputRecipe
    var state = recipe.seed ?? 31
    return try (0..<recipe.count).map { j in
        let value: Double
        switch recipe.kind {
        case "noise":
            state = 1_664_525 &* state &+ 1_013_904_223
            value = (Double(state) - 2_147_483_648) / 4_294_967_296
        case "tone":
            value =
                0.5
                * sin(
                    (2 * .pi) * (try #require(recipe.frequency)) * Double(j) / Double(recipe.rate)
                        + 0.23)
        default:
            Issue.record("Unknown large conditioning recipe")
            value = 0
        }
        return S(value * (recipe.gain ?? 1))
    }
}

private func conditioningInputHash<S: BinaryFloatingPoint & Sendable>(
    _ source: [S], precision: AnalysisPrecision
) -> String {
    var hash = SHA256()
    var block = Data()
    block.reserveCapacity(65_536)
    for value in source {
        if precision == .float32 {
            var bits = Float(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { block.append(contentsOf: $0) }
        } else {
            var bits = Double(value).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { block.append(contentsOf: $0) }
        }
        if block.count >= 65_536 {
            hash.update(data: block)
            block.removeAll(keepingCapacity: true)
        }
    }
    hash.update(data: block)
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func checkConditioningReferences<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, precision: AnalysisPrecision
) throws {
    let url = try #require(
        Bundle.module.url(
            forResource: "praat", withExtension: "json", subdirectory: "Fixtures/Conditioning"))
    let fixture = try JSONDecoder().decode(ConditioningFixture.self, from: Data(contentsOf: url))
    #expect(fixture.cases.count == 184)
    var largestRatio = 0.0
    for item in fixture.cases where item.precision == precision {
        let samples = try conditioningSource(item, type: type)
        #expect(
            conditioningInputHash(samples, precision: precision) == item.inputSHA256,
            "\(item.name) source identity")
        let epoch = StreamEpoch(streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!)
        let source = try SourceInterval(
            epoch: epoch, startSample: 9_007_199_254_741_000,
            sampleCount: Int64(samples.count), sampleRate: Double(item.inputRecipe.rate))
        func check(frequency: Double?, expected: [Double]) throws {
            let configuration = try ConditioningConfiguration(
                sourceSampleRate: item.inputRecipe.rate,
                targetSampleRate: item.targetRate, precision: precision,
                method: .praat7WholeInterval(interpolationDepth: item.interpolationDepth),
                preEmphasisFromHz: frequency, declaredInputBandwidthHz: source.sampleRate / 2,
                requiredInputBandwidthHz: min(source.sampleRate, Double(item.targetRate)) / 2)
            let plan = try PreparedIntervalConditioner<S>(
                configuration: configuration, source: source)
            #expect(
                plan.layout.outputSampleCount == item.expected.sampleCount, "\(item.name) count")
            #expect(
                abs(plan.layout.sourceDurationSeconds - item.expected.domainEndSeconds)
                    <= item.maximumAxisErrorSeconds)
            #expect(
                abs(plan.layout.firstOutputCenterSeconds - item.expected.firstSampleCenterSeconds)
                    <= item.maximumAxisErrorSeconds)
            let chunks = [1, 7, 64, 1024, 127, 512]
            var offset = 0
            var ordinal = 0
            try samples.withUnsafeBufferPointer { buffer in
                while offset < buffer.count {
                    let count = min(chunks[ordinal % chunks.count], buffer.count - offset)
                    let interval = try SourceInterval(
                        epoch: epoch, startSample: source.startSample + Int64(offset),
                        sampleCount: Int64(count), sampleRate: source.sampleRate)
                    try plan.append(
                        UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                        interval: interval)
                    offset += count
                    ordinal += 1
                }
            }
            var callbacks = 0
            var maximumError = 0.0
            let record = try plan.finish { output, record in
                callbacks += 1
                #expect(record.timing.source == source)
                #expect(record.timing.includedSampleCount == source.sampleCount)
                #expect(record.timing.effectiveDelaySeconds == source.durationSeconds / 2)
                #expect(output.count == item.expected.sampleCount)
                for (position, index) in item.expected.indices.enumerated() {
                    maximumError = max(
                        maximumError, abs(Double(output[index]) - expected[position]))
                }
            }
            #expect(callbacks == 1)
            #expect(
                maximumError <= item.maximumAbsoluteError,
                "\(precision) \(item.name) emphasis=\(String(describing: frequency)) error=\(maximumError) budget=\(item.maximumAbsoluteError)"
            )
            largestRatio = max(largestRatio, maximumError / item.maximumAbsoluteError)
            #expect(try plan.finish { _, _ in Issue.record("Duplicate finish emission") } == record)
            #expect(
                try JSONDecoder().decode(
                    ConditionedInterval.self, from: JSONEncoder().encode(record)) == record)
            print(
                "CONDITIONING_ACCURACY precision=\(precision.rawValue) case=\(item.name) emphasis=\(String(describing: frequency)) error=\(maximumError)"
            )
        }
        try check(frequency: item.preEmphasisFromHz, expected: item.expected.conditioned)
        if samples.count <= 48_000 && item.preEmphasisFromHz != nil {
            try check(frequency: nil, expected: item.expected.resampled)
        }
        #expect(
            conditioningInputHash(samples, precision: precision) == item.inputSHA256,
            "Original PCM changed")
    }
    print(
        "CONDITIONING_ACCURACY precision=\(precision.rawValue) maximumBudgetFraction=\(largestRatio)"
    )
}

@Suite(.serialized) struct IntervalConditioningReferenceTests {
    @Test func floatConditioningMatchesIndependentReference() throws {
        try checkConditioningReferences(Float.self, precision: .float32)
    }
    @Test func doubleConditioningMatchesIndependentReference() throws {
        try checkConditioningReferences(Double.self, precision: .float64)
    }
}
