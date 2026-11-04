import Foundation
import Testing

@testable import HDXLVoiceProcessing

let conditioningEpoch = StreamEpoch(
    streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!)
func testConditioningConfiguration(
    source: Int = 16_000, target: Int = 10_000,
    precision: AnalysisPrecision = .float64, emphasis: Double? = 50,
    method: ConditioningMethod = .praat7WholeInterval(interpolationDepth: 50)
) throws -> ConditioningConfiguration {
    try ConditioningConfiguration(
        sourceSampleRate: source, targetSampleRate: target,
        precision: precision, method: method, preEmphasisFromHz: emphasis,
        declaredInputBandwidthHz: Double(source) / 2,
        requiredInputBandwidthHz: Double(min(source, target)) / 2)
}
func conditioningInterval(
    _ count: Int, start: Int64 = 0, rate: Int = 16_000,
    epoch: StreamEpoch = conditioningEpoch
) throws -> SourceInterval {
    try SourceInterval(
        epoch: epoch, startSample: start, sampleCount: Int64(count), sampleRate: Double(rate))
}
private func wholeConditioned(
    _ samples: [Double], config: ConditioningConfiguration,
    partitions: [Int]
) throws -> [Double] {
    let plan = try PreparedIntervalConditioner<Double>(
        configuration: config,
        source: conditioningInterval(samples.count, rate: config.sourceSampleRate))
    var result: [Double] = []
    try samples.withUnsafeBufferPointer { buffer in
        var offset = 0
        var part = 0
        while offset < samples.count {
            let count = min(partitions[part % partitions.count], samples.count - offset)
            try plan.append(
                UnsafeBufferPointer(rebasing: buffer[offset..<(offset + count)]),
                interval: conditioningInterval(
                    count, start: Int64(offset), rate: config.sourceSampleRate))
            offset += count
            part += 1
        }
    }
    try plan.finish { output, _ in result = Array(output) }
    return result
}

@Test func conditioningStrictConfigurationAndCapacityContracts() throws {
    #expect(
        try ResamplingRatio(numerator: 10_000, denominator: 44_100)
            == ResamplingRatio(numerator: 100, denominator: 441))
    let config = try testConditioningConfiguration()
    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(ConditioningConfiguration.self, from: data) == config)
    #expect(config.preEmphasisCoefficient == exp(-2 * .pi * 50 / 10_000))
    #expect(try testConditioningConfiguration(emphasis: nil).preEmphasisCoefficient == nil)
    #expect(try testConditioningConfiguration(emphasis: 0).preEmphasisCoefficient == 1)
    #expect(
        try testConditioningConfiguration(emphasis: -0.0).identity()
            == testConditioningConfiguration(emphasis: 0).identity())
    #expect(try config.identity() != testConditioningConfiguration(emphasis: nil).identity())
    #expect(throws: ConditioningError.unsupportedRate) {
        try testConditioningConfiguration(source: 3999)
    }
    #expect(throws: ConditioningError.invalidFrequency) {
        try testConditioningConfiguration(emphasis: .nan)
    }
    #expect(throws: ConditioningError.invalidQuality) {
        try testConditioningConfiguration(method: .praat7WholeInterval(interpolationDepth: 129))
    }
    #expect(throws: ConditioningError.invalidQuality) {
        try testConditioningConfiguration(method: .streamingPreview(lobes: 8, cutoffFraction: 1))
    }
    #expect(throws: ConditioningError.insufficientInputBandwidth) {
        try ConditioningConfiguration(
            sourceSampleRate: 16_000, targetSampleRate: 32_000,
            precision: .float64, method: .praat7WholeInterval(interpolationDepth: 50),
            preEmphasisFromHz: nil, declaredInputBandwidthHz: 6000, requiredInputBandwidthHz: 7000)
    }
    #expect(throws: ConditioningError.capacityExceeded) {
        try IntervalConditioningLayout(configuration: config, inputSampleCount: 2_880_001)
    }
    #expect(throws: ConditioningError.insufficientData) {
        try IntervalConditioningLayout(
            configuration: testConditioningConfiguration(source: 48_000), inputSampleCount: 1)
    }
    #expect(throws: ConditioningError.capacityExceeded) {
        try IntervalConditioningLayout(
            configuration: testConditioningConfiguration(source: 48_000, target: 96_000),
            inputSampleCount: 2_096_000)
    }
    #expect(throws: ConditioningError.precisionMismatch) {
        try PreparedIntervalConditioner<Float>(
            configuration: config, source: conditioningInterval(100))
    }
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for (key, value) in [
        ("schemaVersion", 2 as Any), ("gainPolicy", "peak" as Any),
        ("ratio", ["numerator": 1, "denominator": 1] as Any),
        ("extra", true as Any),
    ] {
        var mutation = json
        mutation[key] = value
        let changed = try JSONSerialization.data(withJSONObject: mutation)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ConditioningConfiguration.self, from: changed)
        }
    }
    json.removeValue(forKey: "preEmphasisFromHz")
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            ConditioningConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@Test func wholeConditioningChunksGainAndSourceChangeAreDistinct() throws {
    let source = (0..<1024).map { j in
        0.3 * sin(2 * .pi * 200 * Double(j) / 16_000) + 0.1
            * sin(2 * .pi * 400 * Double(j) / 16_000)
    }
    let changedPhonation = (0..<1024).map { j in
        0.3 * sin(2 * .pi * 200 * Double(j) / 16_000) + 0.2
            * sin(2 * .pi * 400 * Double(j) / 16_000)
    }
    let config = try testConditioningConfiguration()
    let reference = try wholeConditioned(source, config: config, partitions: [source.count])
    for chunks in [[1], [64, 127, 17], [512, 512]] {
        #expect(try wholeConditioned(source, config: config, partitions: chunks) == reference)
    }
    let louder = try wholeConditioned(source.map { 2 * $0 }, config: config, partitions: [64])
    let changed = try wholeConditioned(changedPhonation, config: config, partitions: [64])
    #expect(zip(louder, reference).allSatisfy { abs($0 - 2 * $1) < 1e-13 })
    #expect(zip(changed, louder).map { abs($0 - $1) }.max()! > 0.01)
    #expect(zip(changed, reference).map { abs($0 - $1) }.max()! > 0.01)
}

@Test func wholeConditioningFailureAtomicityResetAndBorrowLifetime() throws {
    let config = try testConditioningConfiguration(target: 16_000)
    let plan = try PreparedIntervalConditioner<Double>(
        configuration: config, source: conditioningInterval(4))
    #expect(throws: ConditioningError.insufficientData) {
        try plan.finish { _, _ in Issue.record("Incomplete emission") }
    }
    #expect(throws: ConditioningError.nonfiniteInput) {
        try [1.0, .nan].withUnsafeBufferPointer {
            try plan.append($0, interval: conditioningInterval(2))
        }
    }
    #expect(plan.receivedSampleCount == 0)
    try [0.25, 0.5].withUnsafeBufferPointer {
        try plan.append($0, interval: conditioningInterval(2))
    }
    for interval in [
        try conditioningInterval(2, start: 3), try conditioningInterval(2, start: 2, rate: 48_000),
        try conditioningInterval(2, start: 2, epoch: conditioningEpoch.successor()),
    ] {
        #expect(throws: ConditioningError.unexpectedInterval) {
            try [0.75, 1.0].withUnsafeBufferPointer { try plan.append($0, interval: interval) }
        }
    }
    #expect(plan.receivedSampleCount == 2)
    try [0.75, 1.0].withUnsafeBufferPointer {
        try plan.append($0, interval: conditioningInterval(2, start: 2))
    }
    var first: [Double] = []
    try plan.finish { values, _ in first = Array(values) }
    #expect(first[0] == 0.25)
    #expect(abs(first[1] - (0.5 - exp(-2 * .pi * 50 / 16_000) * 0.25)) < 1e-15)
    #expect(throws: ConditioningError.invalidState) {
        try [Double]().withUnsafeBufferPointer {
            try plan.append($0, interval: conditioningInterval(0, start: 4))
        }
    }
    let newSource = try conditioningInterval(
        4, start: Int64.max - 4, epoch: conditioningEpoch.successor())
    try plan.reset(source: newSource)
    try [0.25, 0.5, 0.75, 1.0].withUnsafeBufferPointer { try plan.append($0, interval: newSource) }
    try plan.finish { values, record in
        #expect(record.timing.source == newSource)
        #expect(Array(values) == first)
        #expect(throws: ConditioningError.reentrantCall) { try plan.reset(source: newSource) }
        #expect(throws: ConditioningError.reentrantCall) { try plan.finish { _, _ in } }
        plan.cancel()
        #expect(Array(values) == first)
        #expect(plan.scalarWorkspaceBytes == 0)
    }
    #expect(plan.isCancelled)
    #expect(throws: ConditioningError.invalidState) { try plan.reset(source: newSource) }
    let overflow = try PreparedIntervalConditioner<Double>(
        configuration: testConditioningConfiguration(target: 16_000, emphasis: 0),
        source: conditioningInterval(2))
    try [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude].withUnsafeBufferPointer {
        try overflow.append($0, interval: conditioningInterval(2))
    }
    #expect(throws: ConditioningError.nonfiniteResult) {
        try overflow.finish { _, _ in Issue.record("Nonfinite emission") }
    }
    #expect(throws: ConditioningError.invalidState) { try overflow.finish { _, _ in } }
    try overflow.reset(source: conditioningInterval(2))
}
