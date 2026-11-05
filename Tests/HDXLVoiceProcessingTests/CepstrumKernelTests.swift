import Foundation
import Testing

@testable import HDXLVoiceProcessing

func cepstrumContext(count: Int, rate: Int = 4000) throws -> CepstralFrameContext {
    let epoch = StreamEpoch(streamID: UUID())
    let source = try SourceInterval(
        epoch: epoch, startSample: 0, sampleCount: Int64(count), sampleRate: Double(rate))
    return try CepstralFrameContext(
        origin: SourceInterval(
            epoch: epoch, startSample: 0, sampleCount: 0,
            sampleRate: Double(rate)),
        timing: AnalysisTiming(source: source, includedSampleCount: source.sampleCount),
        frameIndex: 0, firstAnalysisSampleIndex: 0,
        suppliedAnalysisSampleCount: count,
        centerSecondsFromOrigin: source.durationSeconds / 2)
}

@Test func cepstralConfigurationRejectsContradictoryDefinitions() throws {
    let reference = try CepstrogramConfiguration(
        sourceSampleRate: 48_000, declaredInputBandwidthHz: 24_000)
    #expect(reference.frame.frameLength == 1000 && reference.frame.transformLength == 1024)
    #expect(reference.frame.quefrencyStepSeconds == 0.0001)
    #expect(reference.previewHopLength == nil && reference.conditioning.preEmphasisFromHz == nil)
    #expect(reference.conditioning.requiredInputBandwidthHz == 5000)
    let preview = try CepstrogramConfiguration(
        sourceSampleRate: 48_000, hopSeconds: 0.005,
        declaredInputBandwidthHz: 24_000,
        conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
    #expect(preview.previewHopLength == 50)
    #expect(try reference.identity() != preview.identity())
    for c in [reference, preview] {
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(CepstrogramConfiguration.self, from: data) == c)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, replacement) in [
            ("schemaVersion", 2 as Any), ("future", true as Any),
            ("previewHopLength", -1 as Any), ("hopSeconds", 0 as Any),
        ] {
            var changed = object
            changed[key] = replacement
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(
                    CepstrogramConfiguration.self,
                    from: JSONSerialization.data(withJSONObject: changed))
            }
        }
    }
    #expect(throws: ConditioningError.insufficientInputBandwidth) {
        try CepstrogramConfiguration(sourceSampleRate: 8000, declaredInputBandwidthHz: 4000)
    }
    #expect(throws: CepstrumError.invalidConfiguration) {
        try CepstrogramConfiguration(
            sourceSampleRate: 48_000, hopSeconds: 0.00505,
            declaredInputBandwidthHz: 24_000,
            conditioningMethod: .streamingPreview(lobes: 16, cutoffFraction: 0.9))
    }
    #expect(throws: CepstrumError.precisionMismatch) {
        try PreparedPreviewCepstrogram<Float>(
            configuration: preview, epoch: StreamEpoch(streamID: UUID()))
    }
    for bad in [0, -1, Double.nan, .infinity] {
        #expect(throws: CepstrumError.invalidConfiguration) {
            try PowerCepstrumConfiguration(pitchFloorHz: bad)
        }
    }
}

@Test func cepstrumMatchesIndependentCosineSumTransformAtEveryStage() throws {
    let c = try PowerCepstrumConfiguration(sampleRate: 4000, pitchFloorHz: 1000)
    let worker = try PreparedPowerCepstrum(c)
    let input = (0..<c.frameLength).map { i in
        sin(0.73 * Double(i)) * 0.3 + cos(1.91 * Double(i)) * 0.12
    }
    let mean = input.reduce(0, +) / Double(input.count)
    let edge = exp(-12.0)
    let windowed = (0..<c.transformLength).map { i -> Double in
        guard i < input.count else { return 0 }
        let u = Double(2 * i + 1 - input.count) / Double(input.count)
        return (input[i] - mean) * (exp(-12 * u * u) - edge) / (1 - edge)
    }
    var real: [Double] = []
    var imag: [Double] = []
    var power: [Double] = []
    var logarithm: [Double] = []
    for k in 0..<c.binCount {
        var re = 0.0
        var im = 0.0
        for j in windowed.indices {
            let angle = 2 * Double.pi * Double(j * k) / Double(c.transformLength)
            re += windowed[j] * cos(angle)
            im -= windowed[j] * sin(angle)
        }
        if k == 0 || k == c.binCount - 1 { im = 0 }
        re /= Double(c.sampleRate)
        im /= Double(c.sampleRate)
        real.append(re)
        imag.append(im)
        let p = 2 * (re * re + im * im)
        power.append(p)
        logarithm.append(log(p + (k == c.binCount - 1 ? 0 : 1e-300)))
    }
    let signed = (0..<c.binCount).map { j -> Double in
        var value = logarithm[0] + logarithm[c.binCount - 1] * (j % 2 == 0 ? 1 : -1)
        for k in 1..<c.binCount - 1 {
            value += 2 * logarithm[k] * cos(2 * .pi * Double(j * k) / Double(c.transformLength))
        }
        return value * Double(c.sampleRate) / Double(c.transformLength)
    }
    let expectations: [(CepstralStage, [Double], Double)] = [
        (.windowed, windowed, 1e-15),
        (.spectrumReal, real, 1e-17), (.spectrumImaginary, imag, 1e-17),
        (.powerSpectrum, power, 1e-20), (.logPowerSpectrum, logarithm, 1e-10),
        (.signedCepstrum, signed, 1e-6), (.powerCepstrum, signed.map { $0 * $0 }, 0.01),
    ]
    try input.withUnsafeBufferPointer { input in
        try worker.analyze(input, context: cepstrumContext(count: input.count)) { output in
            #expect(output.unavailability == nil)
            for (stage, expected, tolerance) in expectations {
                let actual = output.stage(stage)
                #expect(actual.isComplete && actual.values.count == expected.count)
                for (a, b) in zip(actual.values, expected) { #expect(abs(a - b) <= tolerance) }
            }
        }
    }
}

@Test func cepstrumUnavailableStagesRemainFiniteAndWorkerIsReusable() throws {
    let c = try PowerCepstrumConfiguration(sampleRate: 4000, pitchFloorHz: 1000)
    let worker = try PreparedPowerCepstrum(c)
    let context = try cepstrumContext(count: c.frameLength)
    let zero = [Double](repeating: 0, count: c.frameLength)
    var saved: [CepstralStageSnapshot] = []
    try zero.withUnsafeBufferPointer { input in
        try worker.analyze(input, context: context) { output in
            #expect(output.unavailability == .silence)
            #expect(output.stage(.powerSpectrum).values.allSatisfy { $0 == 0 })
            let logarithm = output.stage(.logPowerSpectrum)
            #expect(
                logarithm.values.count == c.binCount - 1 && logarithm.unavailability == .silence)
            #expect(logarithm.values.allSatisfy { $0 == log(1e-300) })
            #expect(output.stage(.powerCepstrum).values.isEmpty)
            #expect(throws: CepstrumError.reentrantCall) {
                try worker.analyze(input, context: context) { _ in }
            }
            do {
                saved = try output.export(
                    stages: Set(CepstralStage.allCases),
                    policy: IntermediateOutputPolicy(maximumScalarCount: 1000))
            } catch { Issue.record(error) }
            #expect(throws: ContractError.intermediateBudgetExceeded) {
                try output.export(stages: [.windowed], policy: .disabled)
            }
        }
    }
    let short = Array(zero.dropLast())
    try short.withUnsafeBufferPointer {
        try worker.analyze($0, context: cepstrumContext(count: short.count)) { output in
            #expect(output.unavailability == .insufficientData)
            for stage in CepstralStage.allCases { #expect(output.stage(stage).values.isEmpty) }
        }
    }
    var invalid = zero
    invalid[0] = .nan
    #expect(throws: CepstrumError.nonfiniteInput) {
        try invalid.withUnsafeBufferPointer {
            try worker.analyze($0, context: context) { _ in Issue.record("Invalid PCM emitted") }
        }
    }
    let signal = (0..<c.frameLength).map { sin(0.73 * Double($0)) }
    try signal.withUnsafeBufferPointer {
        try worker.analyze($0, context: context) { output in
            #expect(output.unavailability == nil)
            #expect(output.stage(.powerCepstrum).values.allSatisfy { $0.isFinite && $0 >= 0 })
        }
    }
    #expect(saved.first?.snapshot?.values.allSatisfy { $0 == 0 } == true)
}
