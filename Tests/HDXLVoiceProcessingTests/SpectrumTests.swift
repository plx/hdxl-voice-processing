import Foundation
import HDXLVoiceProcessing
import Testing

private func spectrum<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, n: Int, m: Int, window: WindowDefinition = .rectangular,
    precision: AnalysisPrecision = .float64
) throws -> PreparedSpectrum<S> {
    try PreparedSpectrum(
        SpectrumConfiguration(
            transform: FourierConfiguration(length: n, sampleRate: 48_000, precision: precision),
            window: WindowSpecification(
                definition: window, sampleCount: m, sampleRate: 48_000, precision: precision)))
}

@Test func spectrumEndpointWeightsAndUnitsMatchHandCalculations() throws {
    let converter = try spectrum(Double.self, n: 8, m: 8)
    // Spectrum of 0.5 + 0.25*cos(2*pi*n/8) + 0.125*(-1)^n.
    let bins = [
        FourierBin<Double>(real: 4), FourierBin(real: 1), FourierBin(real: 0), FourierBin(real: 0),
        FourierBin(real: 1),
    ]
    var output = [Double](repeating: -1, count: 5)
    let operations = [
        converter.writeMagnitude, converter.writeAmplitude, converter.writePower,
        converter.writePowerDensity,
    ]
    let expected: [[Double]] = [
        [4.0, 1, 0, 0, 1], [0.5, 0.25, 0, 0, 0.125], [0.25, 0.03125, 0, 0, 0.015625],
        [0.25 / 6000, 0.03125 / 6000, 0, 0, 0.015625 / 6000],
    ]
    for (operation, wanted) in zip(operations, expected) {
        try bins.withUnsafeBufferPointer { x in
            try output.withUnsafeMutableBufferPointer { try operation(x, $0) }
        }
        for k in 0..<5 { #expect(abs(output[k] - wanted[k]) <= max(1e-20, abs(wanted[k]) * 1e-14)) }
    }
    #expect(converter.coherentGain == 1 && converter.energyGain == 1)
    #expect(converter.scalarWorkspaceBytes == 5 * 8)
}

private func checkWindowSpectrum<S: BinaryFloatingPoint & Sendable>(
    _ type: S.Type, precision: AnalysisPrecision
) throws {
    for shape in WindowDefinition.allCases {
        for m in [1, 17, 32] {
            let converter = try spectrum(type, n: 32, m: m, window: shape, precision: precision)
            let window = try PreparedWindow<S>(converter.configuration.window)
            let plan = try PreparedFourierTransform<S>(converter.configuration.transform)
            let input = [S](repeating: 0.25, count: m)
            var padded = [S](repeating: -99, count: 32)
            let application = try input.withUnsafeBufferPointer { x in
                try padded.withUnsafeMutableBufferPointer { try window.write(x, into: $0) }
            }
            #expect(
                application.missingWindowSampleCount == 0
                    && application.transformPaddingSampleCount == 32 - m)
            var bins = [FourierBin<S>](repeating: FourierBin(real: 0), count: 17)
            try padded.withUnsafeBufferPointer { x in
                try bins.withUnsafeMutableBufferPointer { _ = try plan.forwardReal(x, into: $0) }
            }
            var output = [S](repeating: 0, count: 17)
            try bins.withUnsafeBufferPointer { x in
                try output.withUnsafeMutableBufferPointer {
                    try converter.writeAmplitude(x, into: $0)
                }
            }
            let tolerance = precision == .float32 ? 3e-7 : 3e-15
            #expect(abs(Double(output[0]) - 0.25) < tolerance)
            try bins.withUnsafeBufferPointer { x in
                try output.withUnsafeMutableBufferPointer { try converter.writePower(x, into: $0) }
            }
            #expect(abs(output.reduce(0) { $0 + Double($1) } - 0.0625) < tolerance)
            try bins.withUnsafeBufferPointer { x in
                try output.withUnsafeMutableBufferPointer {
                    try converter.writePowerDensity(x, into: $0)
                }
            }
            #expect(abs(output.reduce(0) { $0 + Double($1) } * 1500 - 0.0625) < tolerance)
            #expect(converter.windowIdentity == window.identity)
            #expect(
                converter.coherentGain == window.coherentGain
                    && converter.energyGain == window.energyGain)
        }
    }
}

@Test func spectrumWindowGainsAndPaddingPreserveIntegratedPower() throws {
    try checkWindowSpectrum(Float.self, precision: .float32)
    try checkWindowSpectrum(Double.self, precision: .float64)
}

@Test func spectrumHasNoFloorAndAvoidsSquaringOverflowBeforeNormalization() throws {
    let converter = try spectrum(Double.self, n: 8, m: 8)
    var bins = [FourierBin<Double>](repeating: FourierBin(real: 0), count: 5)
    bins[0].real = 1e-150
    var output = [Double](repeating: -99, count: 5)
    try bins.withUnsafeBufferPointer { x in
        try output.withUnsafeMutableBufferPointer { try converter.writeMagnitude(x, into: $0) }
    }
    #expect(output[0] == 1e-150 && output[1] == 0)
    try bins.withUnsafeBufferPointer { x in
        try output.withUnsafeMutableBufferPointer { try converter.writePower(x, into: $0) }
    }
    #expect(abs(output[0] / 1.5625e-302 - 1) < 1e-14 && output[1] == 0)
    // Raw squared value overflows; normalized result is finite and must still be produced.
    bins[0].real = 2e154
    try bins.withUnsafeBufferPointer { x in
        try output.withUnsafeMutableBufferPointer { try converter.writePower(x, into: $0) }
    }
    #expect(abs(output[0] / 6.25e306 - 1) < 1e-14)
    bins[0].real = 0
    bins[1] = FourierBin(real: 3, imaginary: 4)
    try bins.withUnsafeBufferPointer { x in
        try output.withUnsafeMutableBufferPointer { try converter.writeMagnitude(x, into: $0) }
    }
    #expect(output[1] == 5)
}

@Test func spectrumRejectsInvalidNormalizationAndPreservesOutputOnFailure() throws {
    let converter = try spectrum(Double.self, n: 8, m: 8)
    for bad in [
        FourierBin<Double>(real: .nan), FourierBin(real: .infinity),
        FourierBin(real: 0, imaginary: .nan),
    ] {
        var bins = [FourierBin<Double>](repeating: FourierBin(real: 1), count: 5)
        bins[2] = bad
        var output = [Double](repeating: -99, count: 5)
        #expect(throws: FourierError.nonfiniteInput) {
            try bins.withUnsafeBufferPointer { x in
                try output.withUnsafeMutableBufferPointer { try converter.writePower(x, into: $0) }
            }
        }
        #expect(output == Array(repeating: -99, count: 5))
    }
    var bins = [FourierBin<Double>](repeating: FourierBin(real: 1), count: 5)
    bins[3].real = .greatestFiniteMagnitude
    var output = [Double](repeating: -99, count: 5)
    #expect(throws: FourierError.nonfiniteResult) {
        try bins.withUnsafeBufferPointer { x in
            try output.withUnsafeMutableBufferPointer { try converter.writePower(x, into: $0) }
        }
    }
    #expect(output == Array(repeating: -99, count: 5))
    let degenerate = try spectrum(Double.self, n: 2, m: 2, window: .hannSymmetric)
    let zeros = [FourierBin<Double>](repeating: FourierBin(real: 0), count: 2)
    var zeroOutput = [Double](repeating: -99, count: 2)
    for operation in [
        degenerate.writeAmplitude, degenerate.writePower, degenerate.writePowerDensity,
    ] {
        #expect(throws: FourierError.invalidNormalization) {
            try zeros.withUnsafeBufferPointer { x in
                try zeroOutput.withUnsafeMutableBufferPointer { try operation(x, $0) }
            }
        }
        #expect(zeroOutput == [-99, -99])
    }
    try zeros.withUnsafeBufferPointer { x in
        try zeroOutput.withUnsafeMutableBufferPointer { try degenerate.writeMagnitude(x, into: $0) }
    }
    #expect(zeroOutput == [0, 0])
    let transform = try FourierConfiguration(length: 8, sampleRate: 48_000)
    for window in [
        try WindowSpecification(definition: .rectangular, sampleCount: 9, sampleRate: 48_000),
        try WindowSpecification(definition: .rectangular, sampleCount: 8, sampleRate: 44_100),
        try WindowSpecification(
            definition: .rectangular, sampleCount: 8, sampleRate: 48_000, precision: .float32),
    ] {
        #expect(throws: FourierError.invalidNormalization) {
            try SpectrumConfiguration(transform: transform, window: window)
        }
    }
    let decoded = try JSONDecoder().decode(
        SpectrumConfiguration.self, from: JSONEncoder().encode(converter.configuration))
    #expect(decoded == converter.configuration)
    #expect(try decoded.identity() == converter.identity)
}
