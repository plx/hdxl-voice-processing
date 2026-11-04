import CryptoKit
import Foundation
import HDXLVoiceProcessing
import Testing

private struct FourierOracle: Decodable {
    struct Recipe: Decodable {
        let name: String
        let seed: UInt32
        let complex: Bool
    }
    struct Case: Decodable {
        let name: String
        let kind: String
        let length: Int
        let precision: AnalysisPrecision
        let input: [[Double]]?
        let recipe: Recipe?
        let inputSHA256: String
        let indices: [Int]
        let expected: [[Double]]
        let maximumAbsoluteError: Double
    }
    let supportedLengths: [Int]
    let cases: [Case]
}

private func loadFourierOracle() throws -> FourierOracle {
    let url = try #require(
        Bundle.module.url(
            forResource: "oracles", withExtension: "json", subdirectory: "Fixtures/Fourier"))
    return try JSONDecoder().decode(FourierOracle.self, from: Data(contentsOf: url))
}

private func noiseSamples<S: BinaryFloatingPoint & Sendable>(
    _ count: Int, complex: Bool, seed: UInt32 = 30, type: S.Type
) -> [FourierBin<S>] {
    var state = seed
    func sample() -> S {
        state = 1_664_525 &* state &+ 1_013_904_223
        return S((Double(state) - 2_147_483_648) / 2_147_483_648)
    }
    return (0..<count).map { _ in FourierBin(real: sample(), imaginary: complex ? sample() : 0) }
}

private func checkFourierOracle<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, precision: AnalysisPrecision, lengths: ClosedRange<Int> = 2...65_536
) throws {
    let oracle = try loadFourierOracle()
    #expect(oracle.supportedLengths == (1...22).map { 1 << $0 })
    var worstRatios: [Int: Double] = [:]
    for item in oracle.cases where item.precision == precision && lengths.contains(item.length) {
        let configuration = try FourierConfiguration(
            length: item.length, sampleRate: 48_000, precision: precision)
        let plan = try PreparedFourierTransform<S>(configuration)
        let values: [FourierBin<S>]
        if let recipe = item.recipe {
            #expect(recipe.name == "lcg-v1")
            values = noiseSamples(
                item.length, complex: recipe.complex, seed: recipe.seed, type: type)
        } else {
            values = try #require(item.input).map {
                FourierBin(real: S($0[0]), imaginary: S($0[1]))
            }
        }
        // Hash in fixed-size blocks instead of retaining another full large input copy.
        var hash = SHA256()
        var bytes = Data()
        bytes.reserveCapacity(65_536)
        func append(_ x: S) {
            if precision == .float32 {
                var bits = Float(x).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            } else {
                var bits = Double(x).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            if bytes.count >= 65_536 {
                hash.update(data: bytes)
                bytes.removeAll(keepingCapacity: true)
            }
        }
        for z in values {
            append(z.real)
            append(z.imaginary)
        }
        hash.update(data: bytes)
        #expect(hash.finalize().map { String(format: "%02x", $0) }.joined() == item.inputSHA256)
        // Retain only the requested bins, including the independent negative-frequency checks.
        var actual: [FourierBin<S>] = []
        switch item.kind {
        case "realForward":
            let real = values.map(\.real)
            var half = [FourierBin<S>](
                repeating: FourierBin(real: 0), count: configuration.realBinCount)
            try real.withUnsafeBufferPointer { input in
                try half.withUnsafeMutableBufferPointer {
                    _ = try plan.forwardReal(input, into: $0)
                }
            }
            #expect(half[0].imaginary == 0 && half[item.length / 2].imaginary == 0)
            actual = item.indices.map { k in
                k <= item.length / 2
                    ? half[k]
                    : FourierBin(
                        real: half[item.length - k].real,
                        imaginary: -half[item.length - k].imaginary)
            }
        case "complexForward":
            var full = [FourierBin<S>](repeating: FourierBin(real: 0), count: item.length)
            try values.withUnsafeBufferPointer { input in
                try full.withUnsafeMutableBufferPointer {
                    _ = try plan.forwardComplex(input, into: $0)
                }
            }
            actual = item.indices.map { full[$0] }
        case "realInverse":
            var real = [S](repeating: 0, count: item.length)
            try values.withUnsafeBufferPointer { input in
                try real.withUnsafeMutableBufferPointer { try plan.inverseReal(input, into: $0) }
            }
            actual = item.indices.map { FourierBin(real: real[$0]) }
        case "complexInverse":
            var full = [FourierBin<S>](repeating: FourierBin(real: 0), count: item.length)
            try values.withUnsafeBufferPointer { input in
                try full.withUnsafeMutableBufferPointer {
                    try plan.inverseComplex(input, into: $0)
                }
            }
            actual = item.indices.map { full[$0] }
        default: Issue.record("Unknown oracle operation \(item.kind)")
        }
        #expect(item.indices.count == item.expected.count)
        for (position, k) in item.indices.enumerated() {
            let error = max(
                abs(Double(actual[position].real) - item.expected[position][0]),
                abs(Double(actual[position].imaginary) - item.expected[position][1]))
            #expect(
                error <= item.maximumAbsoluteError,
                "\(precision) \(item.name) \(item.kind) N=\(item.length) k=\(k), error \(error), bound \(item.maximumAbsoluteError)"
            )
            let ratio = item.maximumAbsoluteError > 0 ? error / item.maximumAbsoluteError : 0
            worstRatios[item.length] = max(worstRatios[item.length] ?? 0, ratio)
        }
    }
    for length in worstRatios.keys.sorted() {
        print(
            "FOURIER_ACCURACY precision=\(precision.rawValue) length=\(length) maximumBudgetFraction=\(worstRatios[length]!)"
        )
    }
}

@Test func fourierFloatMatchesIndependentScalarForwardAndInverse() throws {
    try checkFourierOracle(Float.self, precision: .float32)
}
@Test func fourierDoubleMatchesIndependentScalarForwardAndInverse() throws {
    try checkFourierOracle(Double.self, precision: .float64)
}

// Neumaier accumulation keeps the energy reference accurate when summing millions
// of nonnegative terms. The transform tolerance itself is unchanged.
private func compensatedSum<T: Sequence>(_ values: T) -> Double where T.Element == Double {
    var sum = 0.0
    var correction = 0.0
    for value in values {
        let next = sum + value
        correction += abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
        sum = next
    }
    return sum + correction
}

private func checkRoundTrips<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, precision: AnalysisPrecision, exponents: ClosedRange<Int> = 1...16
) throws {
    for exponent in exponents {
        let n = 1 << exponent
        let plan = try PreparedFourierTransform<S>(
            FourierConfiguration(length: n, sampleRate: 44_100, precision: precision))
        let input = noiseSamples(n, complex: true, type: type)
        var spectrum = [FourierBin<S>](repeating: FourierBin(real: 0), count: n)
        try input.withUnsafeBufferPointer { x in
            try spectrum.withUnsafeMutableBufferPointer { _ = try plan.forwardComplex(x, into: $0) }
        }
        let inputEnergy = compensatedSum(
            input.lazy.map {
                Double($0.real) * Double($0.real) + Double($0.imaginary) * Double($0.imaginary)
            })
        let spectrumEnergy =
            compensatedSum(
                spectrum.lazy.map {
                    Double($0.real) * Double($0.real) + Double($0.imaginary) * Double($0.imaginary)
                }) / Double(n)
        let tolerance = 8 * Double(S.ulpOfOne) * Double(exponent)
        #expect(abs(inputEnergy - spectrumEnergy) <= inputEnergy * tolerance)
        // Same-buffer inverse verifies all input is staged before any caller output is written.
        try spectrum.withUnsafeMutableBufferPointer {
            try plan.inverseComplex(UnsafeBufferPointer($0), into: $0)
        }
        var maximumComplexError = 0.0
        for k in 0..<n {
            maximumComplexError = max(
                maximumComplexError, abs(Double(input[k].real - spectrum[k].real)),
                abs(Double(input[k].imaginary - spectrum[k].imaginary)))
        }
        #expect(maximumComplexError < tolerance)
        let real = input.map(\.real)
        var bins = [FourierBin<S>](repeating: FourierBin(real: 0), count: n / 2 + 1)
        var restored = [S](repeating: 0, count: n)
        try real.withUnsafeBufferPointer { x in
            try bins.withUnsafeMutableBufferPointer { _ = try plan.forwardReal(x, into: $0) }
        }
        let weightedEnergy = compensatedSum(
            bins.lazy.enumerated().map { pair in
                let z = pair.element
                let c = pair.offset == 0 || pair.offset == n / 2 ? 1.0 : 2.0
                return c
                    * (Double(z.real) * Double(z.real) + Double(z.imaginary) * Double(z.imaginary))
                    / Double(n)
            })
        let realEnergy = compensatedSum(real.lazy.map { Double($0) * Double($0) })
        #expect(abs(weightedEnergy - realEnergy) <= realEnergy * tolerance)
        try bins.withUnsafeBufferPointer { x in
            try restored.withUnsafeMutableBufferPointer { try plan.inverseReal(x, into: $0) }
        }
        var maximumRealError = 0.0
        for k in 0..<n {
            maximumRealError = max(maximumRealError, abs(Double(real[k] - restored[k])))
        }
        #expect(maximumRealError < tolerance)
    }
}

@Test func fourierRoundTripsAndParsevalAtOrdinaryFrameLengths() throws {
    try checkRoundTrips(Float.self, precision: .float32)
    try checkRoundTrips(Double.self, precision: .float64)
}

@Test func fourierPaddingAndFrequencyAxesAreExplicit() throws {
    for rate in [16_000.0, 44_100, 48_000] {
        let configuration = try FourierConfiguration(length: 8, sampleRate: rate)
        #expect(configuration.frequencySpacingHz == rate / 8)
        #expect(
            try (0...4).map { try configuration.realFrequencyHz(at: $0) } == [
                0, rate / 8, rate / 4, 3 * rate / 8, rate / 2,
            ])
        #expect(try configuration.complexFrequencyHz(at: 4) == -rate / 2)
        #expect(try configuration.complexFrequencyHz(at: 7) == -rate / 8)
        #expect(throws: ContractError.invalidValue) { try configuration.realFrequencyHz(at: 5) }
        #expect(throws: ContractError.invalidValue) { try configuration.complexFrequencyHz(at: -1) }
        let plan = try PreparedFourierTransform<Double>(configuration)
        for count in 1...8 {
            let source = Array(repeating: 0.25, count: count)
            var bins = [FourierBin<Double>](repeating: FourierBin(real: 0), count: 5)
            let result = try source.withUnsafeBufferPointer { x in
                try bins.withUnsafeMutableBufferPointer { try plan.forwardReal(x, into: $0) }
            }
            #expect(
                result.suppliedSampleCount == count && result.zeroPaddingSampleCount == 8 - count)
            var restored = [Double](repeating: -1, count: 8)
            try bins.withUnsafeBufferPointer { x in
                try restored.withUnsafeMutableBufferPointer { try plan.inverseReal(x, into: $0) }
            }
            for k in 0..<8 { #expect(abs(restored[k] - (k < count ? 0.25 : 0)) < 1e-15) }
        }
    }
    for (count, expected) in [(1, 2), (2, 2), (3, 4), (1000, 1024), (65_536, 65_536)] {
        #expect(try FourierConfiguration.lengthPadding(count) == expected)
    }
}

@Test func fourierInvalidInputsDoNotOverwriteOutputAndPlanRecovers() throws {
    let plan = try PreparedFourierTransform<Double>(
        FourierConfiguration(length: 8, sampleRate: 48_000))
    let sentinel = FourierBin<Double>(real: -99, imaginary: 37)
    for input in [
        [], [Double.nan], [Double.infinity], Array(repeating: 1.0, count: 9),
        Array(repeating: Double.greatestFiniteMagnitude / 4, count: 8),
    ] {
        var output = Array(repeating: sentinel, count: 5)
        #expect(throws: FourierError.self) {
            try input.withUnsafeBufferPointer { x in
                try output.withUnsafeMutableBufferPointer { _ = try plan.forwardReal(x, into: $0) }
            }
        }
        #expect(output == Array(repeating: sentinel, count: 5))
    }
    for index in [0, 4] {
        var bins = Array(repeating: FourierBin<Double>(real: 1), count: 5)
        bins[index].imaginary = 1e-300
        var output = Array(repeating: -99.0, count: 8)
        #expect(throws: FourierError.nonrealEndpoint) {
            try bins.withUnsafeBufferPointer { x in
                try output.withUnsafeMutableBufferPointer { try plan.inverseReal(x, into: $0) }
            }
        }
        #expect(output == Array(repeating: -99.0, count: 8))
    }
    var output = Array(repeating: sentinel, count: 5)
    try [1.0].withUnsafeBufferPointer { x in
        try output.withUnsafeMutableBufferPointer { _ = try plan.forwardReal(x, into: $0) }
    }
    #expect(output == Array(repeating: FourierBin(real: 1), count: 5))
    #expect(plan.scalarWorkspaceBytes == 8 * 2 * MemoryLayout<Double>.stride)
}

@Test func fourierConfigurationCodingAndPrecisionFailClosed() throws {
    for length in [
        Int.min, -1, 0, 1, 3, 6, 12, 65535, 65537, 4_194_303, 4_194_305, 8_388_608, Int.max,
    ] {
        #expect(throws: FourierError.unsupportedLength) {
            try FourierConfiguration(length: length, sampleRate: 48_000)
        }
    }
    for rate in [0.0, -1, Double.nan, .infinity, .leastNonzeroMagnitude] {
        #expect(throws: ContractError.invalidConfiguration) {
            try FourierConfiguration(length: 8, sampleRate: rate)
        }
    }
    let configuration = try FourierConfiguration(
        length: 1024, sampleRate: 48_000, precision: .float32)
    #expect(throws: FourierError.precisionMismatch) {
        try PreparedFourierTransform<Double>(configuration)
    }
    let bytes = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(FourierConfiguration.self, from: bytes)
    #expect(decoded == configuration)
    #expect(try decoded.identity() == configuration.identity())
    let extra = Data(#"{"length":8,"sampleRate":48000,"precision":"float64","scale":2}"#.utf8)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(FourierConfiguration.self, from: extra)
    }
}

@Test func fourierIndependentWorkspacesRunConcurrently() async throws {
    let results = try await withThrowingTaskGroup(of: Double.self) { group in
        for worker in 0..<8 {
            group.addTask {
                let plan = try PreparedFourierTransform<Double>(
                    FourierConfiguration(length: 512, sampleRate: 48_000))
                let source = noiseSamples(
                    512, complex: true, seed: UInt32(worker + 1), type: Double.self)
                var output = [FourierBin<Double>](repeating: FourierBin(real: 0), count: 512)
                var checksum = 0.0
                for _ in 0..<100 {
                    try source.withUnsafeBufferPointer { x in
                        try output.withUnsafeMutableBufferPointer {
                            _ = try plan.forwardComplex(x, into: $0)
                        }
                    }
                    try output.withUnsafeMutableBufferPointer {
                        try plan.inverseComplex(UnsafeBufferPointer($0), into: $0)
                    }
                    for k in 0..<512 {
                        #expect(abs(output[k].real - source[k].real) < 2e-15)
                        #expect(abs(output[k].imaginary - source[k].imaginary) < 2e-15)
                    }
                    checksum += output[worker].real
                }
                return checksum
            }
        }
        var results: [Double] = []
        for try await result in group { results.append(result) }
        return results
    }
    #expect(results.count == 8 && results.allSatisfy(\.isFinite))
}

@Test func fourierComplexPaddingSupportsOverlappingBuffersAndFailureAtomicity() throws {
    let plan = try PreparedFourierTransform<Double>(
        FourierConfiguration(length: 8, sampleRate: 48_000))
    var buffer = [FourierBin<Double>](repeating: FourierBin(real: -99), count: 10)
    buffer[0] = FourierBin(real: 1, imaginary: 2)
    buffer[1] = FourierBin(real: 3, imaginary: -4)
    buffer[2] = FourierBin(real: -5, imaginary: 6)
    let expected = Array(buffer.prefix(3)) + Array(repeating: FourierBin(real: 0), count: 5)
    try buffer.withUnsafeMutableBufferPointer { whole in
        let input = UnsafeBufferPointer(start: whole.baseAddress, count: 3)
        let output = UnsafeMutableBufferPointer(start: whole.baseAddress!.advanced(by: 2), count: 8)
        let report = try plan.forwardComplex(input, into: output)
        #expect(report.suppliedSampleCount == 3 && report.zeroPaddingSampleCount == 5)
        try plan.inverseComplex(UnsafeBufferPointer(output), into: output)
    }
    for k in 0..<8 {
        #expect(abs(buffer[k + 2].real - expected[k].real) < 1e-15)
        #expect(abs(buffer[k + 2].imaginary - expected[k].imaginary) < 1e-15)
    }
    let sentinel = FourierBin<Double>(real: -99, imaginary: 37)
    for source in [
        [], Array(repeating: FourierBin<Double>(real: 1), count: 7),
        Array(repeating: FourierBin<Double>(real: .nan), count: 8),
        Array(repeating: FourierBin<Double>(real: .greatestFiniteMagnitude), count: 8),
    ] {
        var output = Array(repeating: sentinel, count: 8)
        #expect(throws: FourierError.self) {
            try source.withUnsafeBufferPointer { x in
                try output.withUnsafeMutableBufferPointer { try plan.inverseComplex(x, into: $0) }
            }
        }
        #expect(output == Array(repeating: sentinel, count: 8))
    }
}

/// One test runs all large cases sequentially so Float/Double and inverse paths do not
/// retain multiple maximum-size plans at once. Ordinary small tests may run concurrently.
@Suite(.serialized) struct LargeFourierCorrectness {
    @Test func largeFourierOraclesRoundTripsAndEnergy() throws {
        try checkFourierOracle(Float.self, precision: .float32, lengths: 131_072...4_194_304)
        try checkFourierOracle(Double.self, precision: .float64, lengths: 131_072...4_194_304)
        try checkRoundTrips(Float.self, precision: .float32, exponents: 17...22)
        try checkRoundTrips(Double.self, precision: .float64, exponents: 17...22)
    }
}

@Test func largeFourierPaddingPreservesWholeUtteranceCapacity() throws {
    for rate in [16_000, 44_100, 48_000] {
        let required = 60 * rate + 2000
        let length = try FourierConfiguration.lengthPadding(required)
        #expect(length >= required && length <= 4_194_304)
        #expect(length / 2 < required)
        let config = try FourierConfiguration(length: length, sampleRate: Double(rate))
        #expect(
            try JSONDecoder().decode(FourierConfiguration.self, from: JSONEncoder().encode(config))
                == config)
    }
    #expect(FourierConfiguration.maximumLength == 4_194_304)
    #expect(WindowSpecification.maximumSampleCount == 65_536)
    #expect(try FourierConfiguration.lengthPadding(65_537) == 131_072)
    #expect(try FourierConfiguration.lengthPadding(4_194_304) == 4_194_304)
    #expect(throws: FourierError.unsupportedLength) {
        try FourierConfiguration.lengthPadding(4_194_305)
    }
}
