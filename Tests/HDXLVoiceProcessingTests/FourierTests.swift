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
    _ type: S.Type, precision: AnalysisPrecision
) throws {
    let oracle = try loadFourierOracle()
    #expect(oracle.supportedLengths == (1...16).map { 1 << $0 })
    var worstRatios: [Int: Double] = [:]
    for item in oracle.cases where item.precision == precision {
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
        var bytes = Data()
        for z in values {
            for x in [z.real, z.imaginary] {
                if precision == .float32 {
                    var bits = Float(x).bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                } else {
                    var bits = Double(x).bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
                }
            }
        }
        #expect(
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == item.inputSHA256
        )
        var actual = [FourierBin<S>](repeating: FourierBin(real: 0), count: item.length)
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
            for k in 0..<item.length {
                actual[k] =
                    k <= item.length / 2
                    ? half[k]
                    : FourierBin(
                        real: half[item.length - k].real,
                        imaginary: -half[item.length - k].imaginary)
            }
        case "complexForward":
            try values.withUnsafeBufferPointer { input in
                try actual.withUnsafeMutableBufferPointer {
                    _ = try plan.forwardComplex(input, into: $0)
                }
            }
        case "realInverse":
            var real = [S](repeating: 0, count: item.length)
            try values.withUnsafeBufferPointer { input in
                try real.withUnsafeMutableBufferPointer { try plan.inverseReal(input, into: $0) }
            }
            actual = real.map { FourierBin(real: $0) }
        case "complexInverse":
            try values.withUnsafeBufferPointer { input in
                try actual.withUnsafeMutableBufferPointer {
                    try plan.inverseComplex(input, into: $0)
                }
            }
        default: Issue.record("Unknown oracle operation \(item.kind)")
        }
        #expect(item.indices.count == item.expected.count)
        for (position, k) in item.indices.enumerated() {
            let error = max(
                abs(Double(actual[k].real) - item.expected[position][0]),
                abs(Double(actual[k].imaginary) - item.expected[position][1]))
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

private func checkRoundTrips<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, precision: AnalysisPrecision
) throws {
    for exponent in 1...16 {
        let n = 1 << exponent
        let plan = try PreparedFourierTransform<S>(
            FourierConfiguration(length: n, sampleRate: 44_100, precision: precision))
        let input = noiseSamples(n, complex: true, type: type)
        var spectrum = [FourierBin<S>](repeating: FourierBin(real: 0), count: n)
        try input.withUnsafeBufferPointer { x in
            try spectrum.withUnsafeMutableBufferPointer { _ = try plan.forwardComplex(x, into: $0) }
        }
        let inputEnergy = input.reduce(0.0) {
            $0 + Double($1.real) * Double($1.real) + Double($1.imaginary) * Double($1.imaginary)
        }
        let spectrumEnergy =
            spectrum.reduce(0.0) {
                $0 + Double($1.real) * Double($1.real) + Double($1.imaginary) * Double($1.imaginary)
            } / Double(n)
        let tolerance = 8 * Double(S.ulpOfOne) * Double(exponent)
        #expect(abs(inputEnergy - spectrumEnergy) <= inputEnergy * tolerance)
        // Same-buffer inverse verifies all input is staged before any caller output is written.
        try spectrum.withUnsafeMutableBufferPointer {
            try plan.inverseComplex(UnsafeBufferPointer($0), into: $0)
        }
        for k in 0..<n {
            #expect(abs(Double(input[k].real - spectrum[k].real)) < tolerance)
            #expect(abs(Double(input[k].imaginary - spectrum[k].imaginary)) < tolerance)
        }
        let real = input.map(\.real)
        var bins = [FourierBin<S>](repeating: FourierBin(real: 0), count: n / 2 + 1)
        var restored = [S](repeating: 0, count: n)
        try real.withUnsafeBufferPointer { x in
            try bins.withUnsafeMutableBufferPointer { _ = try plan.forwardReal(x, into: $0) }
        }
        let weightedEnergy = bins.enumerated().reduce(0.0) { total, pair in
            let z = pair.element
            let c = pair.offset == 0 || pair.offset == n / 2 ? 1.0 : 2.0
            return total + c
                * (Double(z.real) * Double(z.real) + Double(z.imaginary) * Double(z.imaginary))
                / Double(n)
        }
        let realEnergy = real.reduce(0.0) { $0 + Double($1) * Double($1) }
        #expect(abs(weightedEnergy - realEnergy) <= realEnergy * tolerance)
        try bins.withUnsafeBufferPointer { x in
            try restored.withUnsafeMutableBufferPointer { try plan.inverseReal(x, into: $0) }
        }
        for k in 0..<n { #expect(abs(Double(real[k] - restored[k])) < tolerance) }
    }
}

@Test func fourierRoundTripsAndParsevalAtEverySupportedLength() throws {
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
    for length in [Int.min, -1, 0, 1, 3, 6, 12, 65535, 65537, 131072, Int.max] {
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
