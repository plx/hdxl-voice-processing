import Foundation
import HDXLVoiceProcessing
import Testing

private struct GaussianOracle: Decodable {
    struct Case: Decodable {
        let sampleCount: Int
        let sampleRate: Double
        let values: [Double]
        let decimalOracle: [Double]
    }
    let absoluteTolerance: Double
    let cases: [Case]
}

@Test func windowsMatchPinnedPraatGaussianAndIndependentDecimalOracle() throws {
    let url = try #require(
        Bundle.module.url(
            forResource: "gaussian2", withExtension: "json", subdirectory: "Fixtures/Framing"))
    let oracle = try JSONDecoder().decode(GaussianOracle.self, from: Data(contentsOf: url))
    #expect(oracle.cases.map(\.sampleCount) == [1, 2, 3, 4, 5, 17, 1000])
    for item in oracle.cases {
        let window = try preparedWindow(
            .praatGaussian2, count: item.sampleCount, rate: item.sampleRate)
        let values = window.coefficientSnapshot()
        #expect(item.values.count == item.sampleCount)
        #expect(item.decimalOracle.count == item.sampleCount)
        for index in values.indices {
            #expect(abs(values[index] - item.values[index]) <= oracle.absoluteTolerance)
            #expect(abs(values[index] - item.decimalOracle[index]) <= oracle.absoluteTolerance)
            #expect(values[index] == values[item.sampleCount - index - 1])
        }
    }
}

private func preparedWindow(_ shape: WindowDefinition, count: Int, rate: Double = 48_000) throws
    -> PreparedWindow<Double>
{
    try PreparedWindow(WindowSpecification(definition: shape, sampleCount: count, sampleRate: rate))
}

@Test func windowsMatchHandComputedDefinitionsAndGains() throws {
    let anchors: [(WindowDefinition, Int, [Double])] = [
        (.rectangular, 4, [1, 1, 1, 1]),
        (.hannPeriodic, 4, [0, 0.5, 1, 0.5]),
        (.hannSymmetric, 5, [0, 0.5, 1, 0.5, 0]),
        (.hammingPeriodic, 4, [0.08, 0.54, 1, 0.54]),
        (.hammingSymmetric, 5, [0.08, 0.54, 1, 0.54, 0.08]),
    ]
    for (shape, count, expected) in anchors {
        let window = try preparedWindow(shape, count: count)
        for (value, wanted) in zip(window.coefficientSnapshot(), expected) {
            #expect(abs(value - wanted) < 3e-16)
        }
        #expect(abs(window.coherentGain - expected.reduce(0, +) / Double(count)) < 3e-16)
        #expect(
            abs(window.energyGain - expected.reduce(0) { $0 + $1 * $1 } / Double(count)) < 3e-16)
    }
    for shape in WindowDefinition.allCases {
        let singleton = try preparedWindow(shape, count: 1)
        #expect(singleton.coefficientSnapshot() == [1])
        #expect(singleton.coherentGain == 1)
        #expect(singleton.energyGain == 1)
    }
    #expect(try preparedWindow(.hannSymmetric, count: 2).coefficientSnapshot() == [0, 0])
    let gaussian = try preparedWindow(.praatGaussian2, count: 2400)
    #expect(gaussian.specification.fullDurationSeconds == 0.05)
    #expect(gaussian.specification.effectiveDurationSeconds == 0.025)
    #expect(gaussian.coefficientSnapshot().first! > 0)
    #expect(gaussian.coefficientSnapshot().last! > 0)
}

@Test func windowPaddingIsNeverObservedSupport() throws {
    let window = try preparedWindow(.hannPeriodic, count: 4)
    var output = [Double](repeating: -99, count: 8)
    for input in [[], [2], [2, 2, 2], [2, 2, 2, 2]] as [[Double]] {
        let report = try input.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { try window.write(source, into: $0) }
        }
        #expect(report.observedSampleCount == input.count)
        #expect(report.missingWindowSampleCount == 4 - input.count)
        #expect(report.transformPaddingSampleCount == 4)
        #expect(report.unavailability == (input.count == 4 ? nil : .insufficientData))
        for index in output.indices {
            let expected = index < input.count ? 2 * window.coefficientSnapshot()[index] : 0
            #expect(output[index] == expected)
        }
    }
}

@Test func windowValidationDoesNotMutateOutputAndExactInPlaceIsSupported() throws {
    let window = try preparedWindow(.hannPeriodic, count: 4)
    var destination = [Double](repeating: -99, count: 5)
    for input in [[1.0, .nan], [.infinity], [1, 2, 3, 4, 5]] {
        #expect(throws: FramingError.self) {
            try input.withUnsafeBufferPointer { source in
                try destination.withUnsafeMutableBufferPointer {
                    try window.write(source, into: $0)
                }
            }
        }
        #expect(destination == Array(repeating: -99, count: 5))
    }
    var inplace = [2.0, 2, 2, 2, 5, 5]
    try inplace.withUnsafeMutableBufferPointer { buffer in
        let source = UnsafeBufferPointer(start: buffer.baseAddress, count: 4)
        try window.write(source, into: buffer)
    }
    #expect(zip(inplace, [0, 1, 2, 1, 0, 0]).allSatisfy { abs($0 - $1) < 1e-15 })
    var overlapping = [Double](repeating: 1, count: 8)
    for sourceOffset in [0, 1] {
        #expect(throws: FramingError.overlappingBuffers) {
            try overlapping.withUnsafeMutableBufferPointer { buffer in
                let source = UnsafeBufferPointer(
                    start: buffer.baseAddress!.advanced(by: sourceOffset), count: 4)
                let output = UnsafeMutableBufferPointer(
                    start: buffer.baseAddress!.advanced(by: 1 - sourceOffset), count: 4)
                try window.write(source, into: output)
            }
        }
        #expect(overlapping == Array(repeating: 1, count: 8))
    }
}

@Test func windowFloatPrecisionAndIdentityAreExplicit() throws {
    for shape in WindowDefinition.allCases {
        let specification = try WindowSpecification(
            definition: shape, sampleCount: 17, sampleRate: 16_000, precision: .float32)
        let window = try PreparedWindow<Float>(specification)
        let doubles = try preparedWindow(shape, count: 17, rate: 16_000)
        #expect(window.coefficientSnapshot() == doubles.coefficientSnapshot().map(Float.init))
        #expect(
            window.coherentGain == window.coefficientSnapshot().reduce(0) { $0 + Double($1) } / 17)
        #expect(window.identity != doubles.identity)
        #expect(throws: FramingError.precisionMismatch) {
            try PreparedWindow<Double>(specification)
        }
        let decoded = try JSONDecoder().decode(
            WindowSpecification.self, from: JSONEncoder().encode(specification))
        #expect(decoded == specification)
        #expect(try decoded.identity() == window.identity)
    }
}

@Test func windowImpulsesExposeEveryCachedCoefficient() throws {
    for shape in WindowDefinition.allCases {
        let window = try preparedWindow(shape, count: 17)
        for position in 0..<17 {
            var input = [Double](repeating: 0, count: 17)
            input[position] = 1
            var output = [Double](repeating: -1, count: 32)
            _ = try input.withUnsafeBufferPointer { source in
                try output.withUnsafeMutableBufferPointer { try window.write(source, into: $0) }
            }
            #expect(output[position] == window.coefficientSnapshot()[position])
            #expect(output.enumerated().allSatisfy { $0.offset == position || $0.element == 0 })
        }
    }
}
