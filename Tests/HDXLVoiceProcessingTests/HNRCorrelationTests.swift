import Foundation
import Testing

@testable import HDXLVoiceProcessing

@Test func hnrFFTCorrelationsMatchIndependentDirectSumStages() throws {
    struct Stages: Decodable {
        struct Equations: Decodable {
            let localMean: Double
            let windowed: [Double]
            let signalCorrelation, windowCorrelation: [Double]?
            let correlation: [Double?]
            let correlationStartSample, correlationSampleCount: Int
            let computedMaximumLag: Int?
        }
        let `case`: HNRReferenceCase
        let equations: Equations
    }
    let directory = try hnrFixtureDirectory("HNRStages")
    let references = try hnrFixtureDirectory("HNR")
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
    var cells = 0
    for file in files {
        let stage = try JSONDecoder().decode(Stages.self, from: Data(contentsOf: file))
        let c = try stage.case.profile.native()
        let e = stage.equations
        let worker = try PreparedHNRCorrelation(c, diagnostics: WorkerDiagnostics())
        let input: [Double]
        if c.method == .autocorrelation {
            input = e.windowed
        } else {
            let external = try JSONDecoder().decode(
                HNRReferenceRecord.self,
                from: Data(contentsOf: references.appending(path: stage.case.name + ".json")))
            let samples = try hnrReferenceSamples(external, directory: references)
            input = samples[
                e.correlationStartSample..<e.correlationStartSample + e.correlationSampleCount
            ]
            .map { $0 - e.localMean }
        }
        try input.withUnsafeBufferPointer {
            try worker.compute($0, maximumLag: e.computedMaximumLag ?? c.maximumCorrelationLag)
        }
        #expect(worker.curve.count == e.correlation.count)
        for (i, expected) in e.correlation.enumerated() {
            #expect(worker.valid[i] == (expected != nil))
            if let expected {
                #expect(
                    abs(worker.curve[i] - expected) <= 2e-14,
                    "\(stage.case.name) correlation lag \(i), error \(worker.curve[i] - expected)")
            }
            cells += 1
        }
        for (actual, expected) in [
            (worker.signalCorrelation, e.signalCorrelation),
            (worker.windowCorrelation, e.windowCorrelation),
        ] {
            if let expected {
                #expect(actual.count == expected.count)
                for (i, value) in expected.enumerated() {
                    #expect(
                        abs(actual[i] - value) <= 2e-12,
                        "\(stage.case.name) unnormalized correlation lag \(i)")
                }
            } else {
                #expect(actual.isEmpty)
            }
        }
    }
    #expect(files.count == 16 && cells > 20_000)
}

@Test func hnrCorrelationClosedFormsAndUndefinedEnergySurviveWorkspaceReuse() throws {
    for method in HNRMethod.allCases {
        let c = try HNRConfiguration(
            method: method, sampleRate: 4000, pitchFloorHz: 500, periodsPerWindow: 2)
        let worker = try PreparedHNRCorrelation(c, diagnostics: WorkerDiagnostics())
        let lag = method == .autocorrelation ? c.maximumCorrelationLag : c.maximumCandidateLag
        let count = c.windowSampleCount + (method == .forwardCrossCorrelation ? lag : 0)
        var samples = Array(repeating: 0.0, count: count)
        samples[0] = 1
        try samples.withUnsafeBufferPointer { try worker.compute($0, maximumLag: lag) }
        #expect(worker.curve[0] == 1)
        if method == .autocorrelation {
            #expect(abs(worker.signalCorrelation[0] - 1) < 1e-15)
            for k in 1...lag { #expect(abs(worker.signalCorrelation[k]) < 1e-15) }
        } else {
            for k in 1...lag { #expect(!worker.valid[k]) }
            #expect(worker.directEnergyLagCount > 0)
            for k in (lag + 1)...c.maximumCorrelationLag {
                #expect(worker.curve[k] == 0 && worker.valid[k])
            }
        }
        samples = Array(repeating: 1.0, count: count)
        try samples.withUnsafeBufferPointer { try worker.compute($0, maximumLag: lag) }
        if method == .forwardCrossCorrelation {
            for k in 0...lag {
                #expect(worker.valid[k] && abs(worker.curve[k] - 1) < 2e-15)
            }
        } else {
            for k in 0...lag {
                #expect(abs(worker.signalCorrelation[k] - Double(c.windowSampleCount - k)) < 1e-13)
            }
        }
        samples[0] = .nan
        #expect(throws: HNRError.invalidInput) {
            try samples.withUnsafeBufferPointer { try worker.compute($0, maximumLag: lag) }
        }
        #expect(throws: HNRError.invalidBufferSize) {
            try samples.dropLast().withUnsafeBufferPointer {
                try worker.compute($0, maximumLag: lag)
            }
        }
    }
}

private func hnrIndependentScaledDot(_ first: ArraySlice<Double>, _ second: ArraySlice<Double>)
    -> Double?
{
    let aScale = first.map(abs).max() ?? 0
    let bScale = second.map(abs).max() ?? 0
    guard aScale > 0, bScale > 0 else { return nil }
    let a = first.map { $0 / aScale }
    let b = second.map { $0 / bScale }
    let aEnergy = a.map { $0 * $0 }.reduce(0, +)
    let bEnergy = b.map { $0 * $0 }.reduce(0, +)
    let product = zip(a, b).map { $0 * $1 }.reduce(0, +)
    return product / (sqrt(aEnergy) * sqrt(bEnergy))
}

@Test func hnrCCQuietOverlapsRejectGlobalConvolutionContaminationAndSquareUnderflow() throws {
    let c = try HNRConfiguration(method: .forwardCrossCorrelation, sampleRate: 16000)
    let n = c.windowSampleCount
    let lagCount = c.maximumCandidateLag
    let worker = try PreparedHNRCorrelation(c, diagnostics: WorkerDiagnostics())
    for amplitude in [1.0, 1e-6, 1e-10, 1e-20, 1e-150, 1e-200, Double.leastNormalMagnitude] {
        for impulseAtEnd in [true, false] {
            var input = (0..<(n + lagCount)).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
            input[impulseAtEnd ? input.count - 1 : 0] = 1
            let before = worker.directEnergyLagCount
            try input.withUnsafeBufferPointer { try worker.compute($0, maximumLag: lagCount) }
            for lag in 1...lagCount {
                let expected = try #require(
                    hnrIndependentScaledDot(input[0..<n], input[lag..<lag + n]))
                #expect(worker.valid[lag])
                #expect(
                    abs(worker.curve[lag] - expected) <= 2e-14,
                    "amplitude \(amplitude), impulseAtEnd \(impulseAtEnd), lag \(lag)")
                #expect(abs(worker.curve[lag]) <= 1 + 2e-14)
            }
            if amplitude <= 1e-6 { #expect(worker.directEnergyLagCount > before) }
        }
    }
    // Truly zero first or shifted support stays undefined. A distant impulse
    // must not manufacture a finite cross-correlation for an empty pair.
    for atEnd in [true, false] {
        var input = [Double](repeating: 0, count: n + lagCount)
        input[atEnd ? input.count - 1 : 0] = 1
        try input.withUnsafeBufferPointer { try worker.compute($0, maximumLag: lagCount) }
        for lag in 1...lagCount { #expect(!worker.valid[lag]) }
    }
}

@Test func hnrCCFrameKeepsQuietPeriodicCandidateBesideMuchLouderForwardSample() throws {
    func check<S: BinaryFloatingPoint & Sendable>(_ type: S.Type, amplitudes: [Double]) throws {
        let c = try HNRConfiguration(
            method: .forwardCrossCorrelation, sampleRate: 16000,
            inputPrecision: S.self == Float.self ? .float32 : .float64,
            silenceThreshold: 0, normalization: .causalWindow)
        let layout = try c.causalFrameLayout(frameIndex: 0)
        let worker = try PreparedHNR<S>(c)
        let source = try SourceInterval(
            epoch: StreamEpoch(streamID: UUID()), startSample: 0,
            sampleCount: Int64(c.causalWindowSampleCount), sampleRate: 16000)
        let timing = try AnalysisTiming(source: source, includedSampleCount: source.sampleCount)
        var baseline: Double?
        for amplitude in amplitudes {
            var samples = (0..<c.causalWindowSampleCount).map {
                S(amplitude * sin(2 * Double.pi * 120 * Double($0) / 16000))
            }
            samples[layout.support.upperBound - 1] = 1
            let mean =
                samples[
                    layout.localMeanStartSample..<layout.localMeanStartSample
                        + c.localMeanSampleCount
                ]
                .map(Double.init).reduce(0, +) / Double(c.localMeanSampleCount)
            let centered = samples.map { Double($0) - mean }
            try samples.withUnsafeBufferPointer { input in
                let reference = try HNRNormalization(
                    input, timing: timing, definition: .causalWindow)
                try worker.analyze(
                    UnsafeBufferPointer(rebasing: input[layout.support]), layout: layout,
                    normalization: reference
                ) { output in
                    for lag in 1...layout.computedMaximumLag {
                        let start = layout.correlationStartSample
                        let expected = hnrIndependentScaledDot(
                            centered[start..<start + c.windowSampleCount],
                            centered[start + lag..<start + lag + c.windowSampleCount])!
                        #expect(abs(output.correlation[lag] - expected) <= 2e-14)
                    }
                    let db = output.result.selectedObservation?.finiteDecibels
                    #expect(db != nil)
                    if let db {
                        // Input Float32 rounding may move HNR slightly; this is
                        // an invariant of the quiet-window scale, not a new
                        // tolerance for the frozen reference comparisons.
                        if let baseline {
                            #expect(abs(db - baseline) < (S.self == Float.self ? 1e-5 : 1e-8))
                        } else {
                            baseline = db
                        }
                    }
                }
            }
            #expect(worker.executionStatistics.directlyRecomputedEnergyLagCount > 0)
        }
    }
    try check(Double.self, amplitudes: [1e-20, 1e-50, 1e-150, 1e-200])
    try check(Float.self, amplitudes: [1e-10, 1e-20, 1e-30])
}
