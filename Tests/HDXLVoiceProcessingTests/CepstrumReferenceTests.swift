// External Praat values and frozen conditioning-aware budgets; no native-generated golden output.
import Foundation
import Testing

@testable import HDXLVoiceProcessing

private struct CepstralReferenceFixture: Decodable {
    struct Budget: Decodable {
        let windowed: Double
        let spectrum: Double
        let powerSpectrum: Double
        let ordinaryLog: Double
        let ordinarySigned: Double
        let deepLog: Double
        let deepSigned: Double
    }
    struct ComparisonPolicy: Decodable {
        let deepMinimumLogRange: Double
        let frame: Budget
        let interval: Budget
        let powerRoundingRelative: Double
    }
    struct Recipe: Decodable {
        struct Source: Decodable { let path: String? }
        let name: String
        let source: Source
        let pitchFloorHz: Double
        let hopSeconds: Double
        let maximumFrequencyHz: Double
        let preEmphasisFromHz: Double
    }
    struct Input: Decodable {
        let sampleRate: Int
        let sampleCount: Int
        let peakMagnitude: Double
        let samples: [Double]?
    }
    struct Axes: Decodable {
        let frameCount: Int
        let firstCenterSeconds: Double
        let quefrencyStepSeconds: Double
    }
    struct Frame: Decodable {
        let index: Int
        let centerSeconds: Double
        let firstResampledIndex: Int
        let referenceLogRange: Double
        let comparisonClass: String
        let conditioned: [Double]
        let windowed: [Double]
        let spectrumReal: [Double]
        let spectrumImaginary: [Double]
        let powerSpectrum: [Double]
        let logPowerSpectrum: [Double?]
        let signedCepstrum: [Double?]
        let powerCepstrum: [Double?]
        let intervalPowerCepstrum: [Double?]
        func values(_ stage: CepstralStage, whole: Bool) -> [Double?] {
            switch stage {
            case .windowed: windowed.map { $0 }
            case .spectrumReal: spectrumReal.map { $0 }
            case .spectrumImaginary: spectrumImaginary.map { $0 }
            case .powerSpectrum: powerSpectrum.map { $0 }
            case .logPowerSpectrum: logPowerSpectrum
            case .signedCepstrum: signedCepstrum
            case .powerCepstrum: whole ? intervalPowerCepstrum : powerCepstrum
            }
        }
    }
    let comparisonPolicy: ComparisonPolicy
    let recipe: Recipe
    let input: Input
    let axes: Axes
    let frames: [Frame]
    enum CodingKeys: String, CodingKey {
        case recipe = "case"
        case input, axes, frames, comparisonPolicy
    }
}

private func checkCepstrumReferences<S: BinaryFloatingPoint & Sendable>(
    _ sample: S.Type,
    precision: AnalysisPrecision, fixtures: [CepstralReferenceFixture], root: URL
) throws -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for fixture in fixtures
    where precision == .float64 || fixture.recipe.name.hasPrefix("float32-input-") {
        let recipe = fixture.recipe
        let config = try CepstrogramConfiguration(
            sourceSampleRate: fixture.input.sampleRate,
            analysisSampleRate: Int(2 * recipe.maximumFrequencyHz), inputPrecision: precision,
            pitchFloorHz: recipe.pitchFloorHz, hopSeconds: recipe.hopSeconds,
            preEmphasisFromHz: recipe.preEmphasisFromHz,
            declaredInputBandwidthHz: Double(fixture.input.sampleRate) / 2)
        let kernel = try PreparedPowerCepstrum(config.frame)
        func compare(
            _ output: BorrowedPowerCepstrum<Double>, frame: CepstralReferenceFixture.Frame,
            whole: Bool
        ) {
            let budget = whole ? fixture.comparisonPolicy.interval : fixture.comparisonPolicy.frame
            let deep = frame.referenceLogRange >= fixture.comparisonPolicy.deepMinimumLogRange
            #expect(frame.comparisonClass == (deep ? "deepMinimum" : "ordinary"))
            let framePeak = frame.conditioned.map { abs($0) }.max() ?? 0
            let peak = whole ? max(framePeak, fixture.input.peakMagnitude) : framePeak
            let scale: Double = peak == 0 ? 1 : peak
            let signedTolerance = deep ? budget.deepSigned : budget.ordinarySigned
            for stage in CepstralStage.allCases {
                let actual = output.stage(stage)
                let expected = frame.values(stage, whole: whole)
                var largest = 0.0
                var magnitude = 0.0
                var relative = 0.0
                var expectedScale = 0.0
                var squared = 0.0
                var compared = 0
                var disagreements = 0
                var maximumBudgetFraction = 0.0
                for k in expected.indices {
                    if let e = expected[k], k < actual.values.count {
                        let a = Double(actual.values[k])
                        let delta = abs(a - e)
                        let fraction: Double
                        switch stage {
                        case .windowed: fraction = delta / scale / budget.windowed
                        case .spectrumReal, .spectrumImaginary:
                            fraction = delta / scale / budget.spectrum
                        case .powerSpectrum: fraction = delta / scale / scale / budget.powerSpectrum
                        case .logPowerSpectrum:
                            fraction = delta / (deep ? budget.deepLog : budget.ordinaryLog)
                        case .signedCepstrum: fraction = delta / signedTolerance
                        case .powerCepstrum:
                            let tolerance =
                                signedTolerance * (2 * sqrt(e) + signedTolerance)
                                + fixture.comparisonPolicy.powerRoundingRelative * abs(e)
                            fraction = delta / tolerance
                        }
                        maximumBudgetFraction = max(maximumBudgetFraction, fraction)
                        largest = max(largest, delta)
                        expectedScale = max(expectedScale, abs(e))
                        relative = max(relative, delta / max(1, abs(e)))
                        if a >= 0 && e >= 0 { magnitude = max(magnitude, abs(sqrt(a) - sqrt(e))) }
                        squared += delta * delta
                        compared += 1
                    } else if (expected[k] != nil) != (k < actual.values.count) {
                        disagreements += 1
                    }
                }
                #expect(
                    disagreements == 0,
                    "Availability: \(recipe.name) frame \(frame.index) \(stage.rawValue)")
                #expect(
                    maximumBudgetFraction <= 1,
                    "Budget: \(recipe.name) frame \(frame.index) \(stage.rawValue) whole=\(whole) ratio=\(maximumBudgetFraction)"
                )
                rows.append([
                    "case": recipe.name, "precision": precision.rawValue, "whole": whole,
                    "frame": frame.index, "stage": stage.rawValue, "maximumAbsolute": largest,
                    "maximumMagnitudeError": magnitude, "maximumRelativeToOneOrReference": relative,
                    "referenceMaximum": expectedScale,
                    "rmsError": compared == 0 ? 0 : sqrt(squared / Double(compared)),
                    "maximumBudgetFraction": maximumBudgetFraction,
                    "comparisonClass": frame.comparisonClass,
                    "availabilityDisagreements": disagreements,
                    "unavailability": output.unavailability?.rawValue ?? "available",
                ])
            }
        }
        for frame in fixture.frames {
            let values = frame.conditioned
            try values.withUnsafeBufferPointer { buffer in
                try kernel.analyze(
                    buffer,
                    context: cepstrumContext(count: values.count, rate: config.frame.sampleRate)
                ) {
                    compare($0, frame: frame, whole: false)
                }
            }
        }
        let values: [Double]
        if let stored = fixture.input.samples {
            values = stored
        } else {
            let path = root.appending(path: try #require(recipe.source.path))
            let data = try Data(contentsOf: path)
            if recipe.source.path!.contains("/Synthetic/") {
                #expect(data.count == 56 + fixture.input.sampleCount * 8)
                values = (0..<fixture.input.sampleCount).map { i in
                    data.withUnsafeBytes {
                        Double(
                            bitPattern: UInt64(
                                littleEndian: $0.loadUnaligned(
                                    fromByteOffset: 56 + 8 * i, as: UInt64.self)))
                    }
                }
            } else {
                values = try CorpusPCM(data: data).samples
            }
        }
        let epoch = StreamEpoch(streamID: UUID())
        let source = try SourceInterval(
            epoch: epoch, startSample: 0, sampleCount: Int64(values.count),
            sampleRate: Double(fixture.input.sampleRate))
        let worker = try PreparedIntervalCepstrogram<S>(configuration: config, source: source)
        #expect(worker.layout.frameCount == fixture.axes.frameCount)
        #expect(worker.layout.firstCenterSeconds == fixture.axes.firstCenterSeconds)
        for frame in fixture.frames {
            #expect(try worker.layout.centerSeconds(frameIndex: frame.index) == frame.centerSeconds)
            #expect(
                try worker.layout.firstAnalysisSampleIndex(frameIndex: frame.index)
                    == frame.firstResampledIndex)
        }
        let converted = values.map(S.init)
        try converted.withUnsafeBufferPointer { try worker.append($0, interval: source) }
        try worker.finish { output in
            if let frame = fixture.frames.first(where: {
                UInt64($0.index) == output.context.frameIndex
            }) {
                compare(output, frame: frame, whole: true)
            }
        }
    }
    return rows
}

@Test func cepstrumExternalStageReferences() throws {
    let env = ProcessInfo.processInfo.environment
    let directory =
        try env["HDXL_CEPSTRUM_REFERENCE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        ?? #require(
            Bundle.module.url(forResource: "Cepstrum", withExtension: nil, subdirectory: "Fixtures")
        )
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let fixtures = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map { try JSONDecoder().decode(CepstralReferenceFixture.self, from: Data(contentsOf: $0)) }
    var rows = try checkCepstrumReferences(
        Double.self, precision: .float64, fixtures: fixtures, root: root)
    rows += try checkCepstrumReferences(
        Float.self, precision: .float32, fixtures: fixtures, root: root)
    #expect(fixtures.count == 41 && rows.count == 2898)
    if let path = env["HDXL_CEPSTRUM_REFERENCE_REPORT"] {
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
}
